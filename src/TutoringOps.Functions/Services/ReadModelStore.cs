using System.Net;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Logging;
using TutoringOps.Functions.Models;

namespace TutoringOps.Functions.Services;

public interface IReadModelStore
{
    Task UpsertAsync(StudentDashboardDocument document, CancellationToken cancellationToken);
}

/// <summary>
/// Writes the per-student dashboard document to Cosmos.
///
/// Upsert rather than patch, because the document is a whole projection of
/// current state rather than an accumulation of edits: rebuilding it from the
/// API response makes an out-of-order event harmless. Whichever event arrives
/// last simply writes the freshest read of the truth.
/// </summary>
public sealed class CosmosReadModelStore : IReadModelStore, IAsyncDisposable
{
    private readonly CosmosClient _client;
    private readonly Container _container;
    private readonly ILogger<CosmosReadModelStore> _logger;

    public CosmosReadModelStore(
        string connectionString,
        string databaseName,
        string containerName,
        ILogger<CosmosReadModelStore> logger)
    {
        _logger = logger;
        _client = new CosmosClient(connectionString, new CosmosClientOptions
        {
            ApplicationName = "TutoringOps.Functions",
            // The document is small and written from one place; direct mode's
            // extra ports buy nothing here and gateway mode traverses
            // corporate networks and the free tier more predictably.
            ConnectionMode = ConnectionMode.Gateway,
            SerializerOptions = new CosmosSerializationOptions
            {
                PropertyNamingPolicy = CosmosPropertyNamingPolicy.CamelCase
            }
        });

        _container = _client.GetContainer(databaseName, containerName);
    }

    public async Task UpsertAsync(
        StudentDashboardDocument document, CancellationToken cancellationToken)
    {
        try
        {
            var response = await _container.UpsertItemAsync(
                document,
                new PartitionKey(document.StudentId),
                cancellationToken: cancellationToken);

            _logger.LogInformation(
                "Upserted dashboard for student {StudentId} ({Charge} RU).",
                document.StudentId, response.RequestCharge);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            // The free tier throttles at 1000 RU/s. Let the Functions retry
            // policy back off rather than swallowing it and losing the update.
            _logger.LogWarning(
                "Cosmos throttled the write for student {StudentId}; retry after {Retry}.",
                document.StudentId, ex.RetryAfter);
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        _client.Dispose();
        await ValueTask.CompletedTask;
    }
}

/// <summary>
/// Used when Cosmos is not configured, so the rest of the chain still runs
/// locally. Logs what it would have written.
/// </summary>
public sealed class LoggingReadModelStore : IReadModelStore
{
    private readonly ILogger<LoggingReadModelStore> _logger;

    public LoggingReadModelStore(ILogger<LoggingReadModelStore> logger) => _logger = logger;

    public Task UpsertAsync(StudentDashboardDocument document, CancellationToken cancellationToken)
    {
        _logger.LogInformation(
            "[cosmos not configured] would upsert student {StudentId}: {Hours}h remaining, " +
            "{Upcoming} upcoming session(s).",
            document.StudentId, document.HoursRemaining, document.UpcomingSessions.Count);
        return Task.CompletedTask;
    }
}
