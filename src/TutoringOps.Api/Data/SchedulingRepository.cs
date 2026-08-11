using Oracle.ManagedDataAccess.Client;
using TutoringOps.Api.Models;

namespace TutoringOps.Api.Data;

/// <summary>
/// Thin shell over PKG_SCHEDULING.
///
/// Every method here is: bind parameters, call the procedure, commit if the
/// database said OK and roll back if it did not. There is no branching on
/// business state, no recomputed balance, no second query to "check" something
/// the procedure already decided. If you find yourself wanting to add one, the
/// rule belongs in PL/SQL instead.
/// </summary>
public sealed class SchedulingRepository
{
    private readonly IOracleConnectionFactory _factory;
    private readonly ILogger<SchedulingRepository> _logger;

    public SchedulingRepository(
        IOracleConnectionFactory factory, ILogger<SchedulingRepository> logger)
    {
        _factory = factory;
        _logger = logger;
    }

    public async Task<(string Result, long? SessionId)> BookAsync(
        long studentId,
        DateTime startTime,
        int durationMinutes,
        string? notes,
        bool asRequest,
        CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();

        var procedure = asRequest
            ? "PKG_SCHEDULING.REQUEST_SESSION"
            : "PKG_SCHEDULING.BOOK_SESSION";

        using var command = connection.CreateProcedureCommand(
            procedure, _factory.CommandTimeoutSeconds);

        command.AddIn("p_student_id", OracleDbType.Int64, studentId);
        command.AddIn("p_start_time", OracleDbType.TimeStamp, startTime);
        command.AddIn("p_duration", OracleDbType.Int32, durationMinutes);
        command.AddIn("p_notes", OracleDbType.Varchar2, notes);
        command.AddIn("p_tutor_id", OracleDbType.Int64, 1);
        var sessionIdParam = command.AddOutNumber("p_session_id");
        var resultParam = command.AddOutVarchar("p_result", 40);

        await command.ExecuteNonQueryAsync(cancellationToken);

        var result = OracleValue.String(resultParam) ?? "ERR_UNKNOWN";
        var sessionId = OracleValue.Int64(sessionIdParam);

        if (ResultCode.IsOk(result))
        {
            // The SESSIONS row and its EVENT_OUTBOX row commit together, which
            // is the whole reason the outbox exists.
            transaction.Commit();
        }
        else
        {
            // book_session already rolled back to its savepoint; this discards
            // the empty transaction so the connection returns to the pool clean.
            transaction.Rollback();
            _logger.LogInformation(
                "Booking refused for student {StudentId} at {StartTime}: {Result}",
                studentId, startTime, result);
        }

        return (result, sessionId);
    }

    public Task<string> CancelAsync(long sessionId, CancellationToken cancellationToken) =>
        ExecuteSessionActionAsync("PKG_SCHEDULING.CANCEL_SESSION", sessionId, cancellationToken);

    public Task<string> CompleteAsync(long sessionId, CancellationToken cancellationToken) =>
        ExecuteSessionActionAsync("PKG_SCHEDULING.COMPLETE_SESSION", sessionId, cancellationToken);

    public Task<string> ConfirmAsync(long sessionId, CancellationToken cancellationToken) =>
        ExecuteSessionActionAsync("PKG_SCHEDULING.CONFIRM_SESSION", sessionId, cancellationToken);

    private async Task<string> ExecuteSessionActionAsync(
        string procedure, long sessionId, CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateProcedureCommand(
            procedure, _factory.CommandTimeoutSeconds);

        command.AddIn("p_session_id", OracleDbType.Int64, sessionId);
        var resultParam = command.AddOutVarchar("p_result", 40);

        await command.ExecuteNonQueryAsync(cancellationToken);

        var result = OracleValue.String(resultParam) ?? "ERR_UNKNOWN";

        if (ResultCode.IsOk(result))
        {
            transaction.Commit();
        }
        else
        {
            transaction.Rollback();
        }

        return result;
    }

    public async Task<(string Result, SessionResponse? Session)> GetAsync(
        long sessionId, CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var command = connection.CreateProcedureCommand(
            "PKG_SCHEDULING.GET_SESSION", _factory.CommandTimeoutSeconds);

        command.AddIn("p_session_id", OracleDbType.Int64, sessionId);
        var cursorParam = command.AddOutRefCursor("p_cursor");
        var resultParam = command.AddOutVarchar("p_result", 40);

        await command.ExecuteNonQueryAsync(cancellationToken);

        var result = OracleValue.String(resultParam) ?? "ERR_UNKNOWN";
        if (!ResultCode.IsOk(result))
        {
            return (result, null);
        }

        await using var reader = ReadCursor(cursorParam);
        return await reader.ReadAsync(cancellationToken)
            ? (result, MapSession(reader))
            : (ResultCode.SessionNotFound, null);
    }

    public async Task<IReadOnlyList<SessionResponse>> GetScheduleAsync(
        DateTime fromDate, DateTime toDate, CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var command = connection.CreateProcedureCommand(
            "PKG_STUDENTS.GET_SCHEDULE", _factory.CommandTimeoutSeconds);

        command.AddIn("p_from_date", OracleDbType.Date, fromDate.Date);
        command.AddIn("p_to_date", OracleDbType.Date, toDate.Date);
        command.AddIn("p_tutor_id", OracleDbType.Int64, 1);
        var cursorParam = command.AddOutRefCursor("p_cursor");

        await command.ExecuteNonQueryAsync(cancellationToken);

        var sessions = new List<SessionResponse>();
        await using var reader = ReadCursor(cursorParam);
        while (await reader.ReadAsync(cancellationToken))
        {
            sessions.Add(MapSession(reader));
        }

        return sessions;
    }

    /// <summary>
    /// Used by the nightly timer function. Returns how many reminders were
    /// queued, which is what the function logs.
    /// </summary>
    public async Task<long> QueueDueRemindersAsync(
        int hoursAhead, CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateProcedureCommand(
            "PKG_SCHEDULING.QUEUE_DUE_REMINDERS", _factory.CommandTimeoutSeconds);

        command.AddIn("p_hours_ahead", OracleDbType.Int32, hoursAhead);
        var countParam = command.AddOutNumber("p_queued_count");

        await command.ExecuteNonQueryAsync(cancellationToken);
        transaction.Commit();

        return OracleValue.Int64(countParam) ?? 0;
    }

    internal static OracleDataReader ReadCursor(OracleParameter parameter)
    {
        var cursor = (Oracle.ManagedDataAccess.Types.OracleRefCursor)parameter.Value!;
        return cursor.GetDataReader();
    }

    private static SessionResponse MapSession(OracleDataReader reader) => new()
    {
        SessionId = OracleValue.GetInt64(reader, "SESSION_ID"),
        StudentId = OracleValue.GetInt64(reader, "STUDENT_ID"),
        StudentName = OracleValue.GetNullableString(reader, "STUDENT_NAME"),
        StartTime = OracleValue.GetDateTime(reader, "START_TIME"),
        EndTime = OracleValue.GetDateTime(reader, "END_TIME"),
        DurationMinutes = OracleValue.GetInt32(reader, "DURATION_MINUTES"),
        Status = OracleValue.GetString(reader, "STATUS"),
        PackageId = OracleValue.GetNullableInt64(reader, "PACKAGE_ID"),
        Notes = OracleValue.GetNullableString(reader, "NOTES")
    };
}
