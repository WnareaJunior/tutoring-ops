using Oracle.ManagedDataAccess.Client;
using TutoringOps.Api.Models;

namespace TutoringOps.Api.Data;

/// <summary>Thin shell over PKG_STUDENTS.</summary>
public sealed class StudentRepository
{
    private readonly IOracleConnectionFactory _factory;

    public StudentRepository(IOracleConnectionFactory factory) => _factory = factory;

    public async Task<(string Result, long? StudentId, string? AccessCode)> CreateAsync(
        string fullName,
        string parentContact,
        string? parentPhone,
        string language,
        CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateProcedureCommand(
            "PKG_STUDENTS.CREATE_STUDENT", _factory.CommandTimeoutSeconds);

        command.AddIn("p_full_name", OracleDbType.Varchar2, fullName);
        command.AddIn("p_parent_contact", OracleDbType.Varchar2, parentContact);
        command.AddIn("p_parent_phone", OracleDbType.Varchar2, parentPhone);
        command.AddIn("p_language", OracleDbType.Varchar2, language.ToUpperInvariant());
        var studentIdParam = command.AddOutNumber("p_student_id");
        var accessCodeParam = command.AddOutVarchar("p_access_code", 12);
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

        return (result, OracleValue.Int64(studentIdParam), OracleValue.String(accessCodeParam));
    }

    public async Task<(string Result, StudentResponse? Student)> GetAsync(
        long studentId, CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var command = connection.CreateProcedureCommand(
            "PKG_STUDENTS.GET_STUDENT", _factory.CommandTimeoutSeconds);

        command.AddIn("p_student_id", OracleDbType.Int64, studentId);
        var cursorParam = command.AddOutRefCursor("p_cursor");
        var resultParam = command.AddOutVarchar("p_result", 40);

        await command.ExecuteNonQueryAsync(cancellationToken);

        var result = OracleValue.String(resultParam) ?? "ERR_UNKNOWN";
        if (!ResultCode.IsOk(result))
        {
            return (result, null);
        }

        await using var reader = SchedulingRepository.ReadCursor(cursorParam);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return (ResultCode.StudentNotFound, null);
        }

        return (result, new StudentResponse
        {
            StudentId = OracleValue.GetInt64(reader, "STUDENT_ID"),
            FullName = OracleValue.GetString(reader, "FULL_NAME"),
            ParentContact = OracleValue.GetString(reader, "PARENT_CONTACT"),
            ParentPhone = OracleValue.GetNullableString(reader, "PARENT_PHONE"),
            PreferredLanguage = OracleValue.GetString(reader, "PREFERRED_LANGUAGE"),
            IsActive = OracleValue.GetString(reader, "IS_ACTIVE") == "Y",
            AccessCode = OracleValue.GetNullableString(reader, "ACCESS_CODE"),
            HoursRemaining = OracleValue.GetDecimal(reader, "HOURS_REMAINING"),
            UnappliedCredit = OracleValue.GetDecimal(reader, "UNAPPLIED_CREDIT"),
            CreatedAt = OracleValue.GetDateTime(reader, "CREATED_AT")
        });
    }

    public async Task<IReadOnlyList<StudentSummaryResponse>> ListAsync(
        bool activeOnly, CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var command = connection.CreateProcedureCommand(
            "PKG_STUDENTS.LIST_STUDENTS", _factory.CommandTimeoutSeconds);

        command.AddIn("p_active_only", OracleDbType.Varchar2, activeOnly ? "Y" : "N");
        var cursorParam = command.AddOutRefCursor("p_cursor");

        await command.ExecuteNonQueryAsync(cancellationToken);

        var students = new List<StudentSummaryResponse>();
        await using var reader = SchedulingRepository.ReadCursor(cursorParam);
        while (await reader.ReadAsync(cancellationToken))
        {
            students.Add(new StudentSummaryResponse
            {
                StudentId = OracleValue.GetInt64(reader, "STUDENT_ID"),
                FullName = OracleValue.GetString(reader, "FULL_NAME"),
                ParentContact = OracleValue.GetString(reader, "PARENT_CONTACT"),
                PreferredLanguage = OracleValue.GetString(reader, "PREFERRED_LANGUAGE"),
                IsActive = OracleValue.GetString(reader, "IS_ACTIVE") == "Y",
                HoursRemaining = OracleValue.GetDecimal(reader, "HOURS_REMAINING")
            });
        }

        return students;
    }

    /// <summary>
    /// One call, three cursors: the summary, the upcoming sessions and the
    /// recent payments. The Function App projects this straight into Cosmos.
    /// </summary>
    public async Task<(string Result, StudentDashboardResponse? Dashboard)> GetDashboardAsync(
        long studentId, CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var command = connection.CreateProcedureCommand(
            "PKG_STUDENTS.GET_DASHBOARD", _factory.CommandTimeoutSeconds);

        command.AddIn("p_student_id", OracleDbType.Int64, studentId);
        var summaryParam = command.AddOutRefCursor("p_summary");
        var sessionsParam = command.AddOutRefCursor("p_sessions");
        var paymentsParam = command.AddOutRefCursor("p_payments");
        var resultParam = command.AddOutVarchar("p_result", 40);

        await command.ExecuteNonQueryAsync(cancellationToken);

        var result = OracleValue.String(resultParam) ?? "ERR_UNKNOWN";
        if (!ResultCode.IsOk(result))
        {
            return (result, null);
        }

        long id;
        string fullName, contact, language;
        decimal hours, credit;
        int completed;

        await using (var summary = SchedulingRepository.ReadCursor(summaryParam))
        {
            if (!await summary.ReadAsync(cancellationToken))
            {
                return (ResultCode.StudentNotFound, null);
            }

            id = OracleValue.GetInt64(summary, "STUDENT_ID");
            fullName = OracleValue.GetString(summary, "FULL_NAME");
            contact = OracleValue.GetString(summary, "PARENT_CONTACT");
            language = OracleValue.GetString(summary, "PREFERRED_LANGUAGE");
            hours = OracleValue.GetDecimal(summary, "HOURS_REMAINING");
            credit = OracleValue.GetDecimal(summary, "UNAPPLIED_CREDIT");
            completed = OracleValue.GetInt32(summary, "SESSIONS_COMPLETED");
        }

        var upcoming = new List<SessionResponse>();
        await using (var sessions = SchedulingRepository.ReadCursor(sessionsParam))
        {
            while (await sessions.ReadAsync(cancellationToken))
            {
                upcoming.Add(new SessionResponse
                {
                    SessionId = OracleValue.GetInt64(sessions, "SESSION_ID"),
                    StudentId = id,
                    StudentName = fullName,
                    StartTime = OracleValue.GetDateTime(sessions, "START_TIME"),
                    EndTime = OracleValue.GetDateTime(sessions, "END_TIME"),
                    DurationMinutes = OracleValue.GetInt32(sessions, "DURATION_MINUTES"),
                    Status = OracleValue.GetString(sessions, "STATUS"),
                    Notes = OracleValue.GetNullableString(sessions, "NOTES")
                });
            }
        }

        var payments = new List<PaymentResponse>();
        await using (var paymentReader = SchedulingRepository.ReadCursor(paymentsParam))
        {
            while (await paymentReader.ReadAsync(cancellationToken))
            {
                payments.Add(new PaymentResponse
                {
                    PaymentId = OracleValue.GetInt64(paymentReader, "PAYMENT_ID"),
                    Amount = OracleValue.GetDecimal(paymentReader, "AMOUNT"),
                    Method = OracleValue.GetString(paymentReader, "METHOD"),
                    PaidDate = OracleValue.GetDateTime(paymentReader, "PAID_DATE"),
                    PackageId = OracleValue.GetNullableInt64(paymentReader, "PACKAGE_ID"),
                    Applied = OracleValue.GetString(paymentReader, "APPLIED_FLAG") == "Y"
                });
            }
        }

        return (result, new StudentDashboardResponse
        {
            StudentId = id,
            FullName = fullName,
            ParentContact = contact,
            PreferredLanguage = language,
            HoursRemaining = hours,
            UnappliedCredit = credit,
            SessionsCompleted = completed,
            UpcomingSessions = upcoming,
            RecentPayments = payments,
            LastUpdatedUtc = DateTime.UtcNow
        });
    }

    public async Task<(string Result, long? StudentId)> ResolveAccessCodeAsync(
        string accessCode, CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var command = connection.CreateProcedureCommand(
            "PKG_STUDENTS.RESOLVE_ACCESS_CODE", _factory.CommandTimeoutSeconds);

        command.AddIn("p_access_code", OracleDbType.Varchar2, accessCode);
        var studentIdParam = command.AddOutNumber("p_student_id");
        var resultParam = command.AddOutVarchar("p_result", 40);

        await command.ExecuteNonQueryAsync(cancellationToken);

        return (OracleValue.String(resultParam) ?? "ERR_UNKNOWN",
                OracleValue.Int64(studentIdParam));
    }

    public async Task<string> SetActiveAsync(
        long studentId, bool isActive, CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateProcedureCommand(
            "PKG_STUDENTS.SET_ACTIVE", _factory.CommandTimeoutSeconds);

        command.AddIn("p_student_id", OracleDbType.Int64, studentId);
        command.AddIn("p_is_active", OracleDbType.Varchar2, isActive ? "Y" : "N");
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
}
