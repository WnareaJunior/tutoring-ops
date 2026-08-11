using System.Data;
using Oracle.ManagedDataAccess.Client;
using Oracle.ManagedDataAccess.Types;
using TutoringOps.Api.Data;

namespace TutoringOps.Api.Outbox;

/// <summary>An unpublished row from EVENT_OUTBOX.</summary>
public sealed record OutboxEvent
{
    public required long EventId { get; init; }
    public required string EventType { get; init; }
    public required string AggregateType { get; init; }
    public required long AggregateId { get; init; }

    /// <summary>The JSON assembled by PKG_EVENTS. Forwarded verbatim.</summary>
    public required string Payload { get; init; }

    public required DateTime CreatedAt { get; init; }
    public required int AttemptCount { get; init; }
}

/// <summary>
/// Thin shell over PKG_OUTBOX.
///
/// Unlike the other repositories these methods take the caller's connection,
/// because the publisher has to hold one transaction across claim, send and
/// mark. Handing the connection in makes that ownership obvious rather than
/// hiding it behind a repository that quietly opens its own.
/// </summary>
public sealed class OutboxRepository
{
    private readonly IOracleConnectionFactory _factory;

    public OutboxRepository(IOracleConnectionFactory factory) => _factory = factory;

    public Task<OracleConnection> OpenConnectionAsync(CancellationToken cancellationToken) =>
        _factory.OpenAsync(cancellationToken);

    public async Task<IReadOnlyList<OutboxEvent>> ClaimBatchAsync(
        OracleConnection connection, int limit, CancellationToken cancellationToken)
    {
        using var command = connection.CreateProcedureCommand(
            "PKG_OUTBOX.CLAIM_BATCH", _factory.CommandTimeoutSeconds);

        command.AddIn("p_limit", OracleDbType.Int32, limit);
        var cursorParam = command.AddOutRefCursor("p_cursor");

        await command.ExecuteNonQueryAsync(cancellationToken);

        var events = new List<OutboxEvent>();
        await using var reader = SchedulingRepository.ReadCursor(cursorParam);
        while (await reader.ReadAsync(cancellationToken))
        {
            events.Add(new OutboxEvent
            {
                EventId = OracleValue.GetInt64(reader, "EVENT_ID"),
                EventType = OracleValue.GetString(reader, "EVENT_TYPE"),
                AggregateType = OracleValue.GetString(reader, "AGGREGATE_TYPE"),
                AggregateId = OracleValue.GetInt64(reader, "AGGREGATE_ID"),
                Payload = ReadClob(reader, "PAYLOAD"),
                CreatedAt = OracleValue.GetDateTime(reader, "CREATED_AT"),
                AttemptCount = OracleValue.GetInt32(reader, "ATTEMPT_COUNT")
            });
        }

        return events;
    }

    public async Task MarkPublishedAsync(
        OracleConnection connection, long eventId, CancellationToken cancellationToken)
    {
        using var command = connection.CreateProcedureCommand(
            "PKG_OUTBOX.MARK_PUBLISHED", _factory.CommandTimeoutSeconds);

        command.AddIn("p_event_id", OracleDbType.Int64, eventId);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    /// <summary>
    /// Records the failure. PKG_OUTBOX.mark_failed is autonomous, so this note
    /// survives the rollback of the batch that failed -- which is the only way
    /// the error is still there to read afterwards.
    /// </summary>
    public async Task MarkFailedAsync(
        long eventId, string error, CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var command = connection.CreateProcedureCommand(
            "PKG_OUTBOX.MARK_FAILED", _factory.CommandTimeoutSeconds);

        command.AddIn("p_event_id", OracleDbType.Int64, eventId);
        command.AddIn("p_error", OracleDbType.Varchar2, error.Length > 2000
            ? error[..2000]
            : error);

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<long> PendingCountAsync(CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var command = connection.CreateProcedureCommand(
            "PKG_OUTBOX.PENDING_COUNT", _factory.CommandTimeoutSeconds);

        // ODP.NET requires the return value of a packaged function to be the
        // first parameter added, even with BindByName on.
        var returnParam = command.Parameters.Add("ret", OracleDbType.Decimal);
        returnParam.Direction = ParameterDirection.ReturnValue;

        await command.ExecuteNonQueryAsync(cancellationToken);

        return OracleValue.Int64(returnParam) ?? 0;
    }

    /// <summary>
    /// CLOB columns need explicit handling: the default LOB fetch size means
    /// GetString can come back short or throw, depending on payload length.
    /// </summary>
    private static string ReadClob(OracleDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        if (reader.IsDBNull(ordinal))
        {
            return string.Empty;
        }

        using OracleClob clob = reader.GetOracleClob(ordinal);
        return clob.Value;
    }
}
