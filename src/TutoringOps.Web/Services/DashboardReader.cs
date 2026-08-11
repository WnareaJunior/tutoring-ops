using System.Net;
using Microsoft.Azure.Cosmos;

namespace TutoringOps.Web.Services;

public interface IDashboardReader
{
    Task<StudentDashboard?> GetAsync(long studentId, CancellationToken cancellationToken);

    /// <summary>Where the data came from, shown on the page so it is never a mystery.</summary>
    string SourceName { get; }
}

/// <summary>
/// Reads the read model straight out of Cosmos.
///
/// This is the whole point of having a read model: the parent status page does
/// not touch Oracle, does not hold a database connection, and stays up even
/// when the tunnel to the Oracle box is down. The cost is that it can be a few
/// seconds stale, which is why the page prints when it was last updated.
/// </summary>
public sealed class CosmosDashboardReader : IDashboardReader, IDisposable
{
    private readonly CosmosClient _client;
    private readonly Container _container;
    private readonly ILogger<CosmosDashboardReader> _logger;

    public CosmosDashboardReader(
        string connectionString,
        string databaseName,
        string containerName,
        ILogger<CosmosDashboardReader> logger)
    {
        _logger = logger;
        _client = new CosmosClient(connectionString, new CosmosClientOptions
        {
            ApplicationName = "TutoringOps.Web",
            ConnectionMode = ConnectionMode.Gateway
        });

        _container = _client.GetContainer(databaseName, containerName);
    }

    public string SourceName => "Cosmos DB read model";

    public async Task<StudentDashboard?> GetAsync(
        long studentId, CancellationToken cancellationToken)
    {
        var id = studentId.ToString();

        try
        {
            var response = await _container.ReadItemAsync<CosmosDashboardDocument>(
                id, new PartitionKey(id), cancellationToken: cancellationToken);

            return response.Resource.ToDashboard();
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // No document yet: the student exists but nothing has happened to
            // them since the projection was switched on.
            _logger.LogInformation("No dashboard document for student {StudentId} yet.", studentId);
            return null;
        }
    }

    public void Dispose() => _client.Dispose();
}

/// <summary>
/// Fallback for local development with no Cosmos account: reads the same shape
/// from the API instead. Same data, one hop further from the source.
///
/// The HttpClient is built per call from the factory rather than held for the
/// lifetime of this singleton, so the underlying handler still rotates the way
/// IHttpClientFactory intends.
/// </summary>
public sealed class ApiDashboardReader : IDashboardReader
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILoggerFactory _loggerFactory;

    public ApiDashboardReader(IHttpClientFactory httpClientFactory, ILoggerFactory loggerFactory)
    {
        _httpClientFactory = httpClientFactory;
        _loggerFactory = loggerFactory;
    }

    public string SourceName => "API (Cosmos not configured)";

    public Task<StudentDashboard?> GetAsync(long studentId, CancellationToken cancellationToken)
    {
        // Named after the typed client registration, so it picks up the same
        // base address and timeout configured in Program.cs.
        var http = _httpClientFactory.CreateClient(nameof(TutoringApiClient));
        var api = new TutoringApiClient(http, _loggerFactory.CreateLogger<TutoringApiClient>());

        return api.GetDashboardAsync(studentId, cancellationToken);
    }
}

/// <summary>The document as the Function App writes it.</summary>
internal sealed record CosmosDashboardDocument
{
    public string Id { get; init; } = "";
    public string StudentId { get; init; } = "";
    public string FullName { get; init; } = "";
    public string PreferredLanguage { get; init; } = "EN";
    public decimal HoursRemaining { get; init; }
    public decimal UnappliedCredit { get; init; }
    public int SessionsCompleted { get; init; }
    public List<CosmosSession> UpcomingSessions { get; init; } = [];
    public List<CosmosPayment> RecentPayments { get; init; } = [];
    public DateTime LastUpdatedUtc { get; init; }

    public StudentDashboard ToDashboard() => new()
    {
        StudentId = long.TryParse(StudentId, out var parsed) ? parsed : 0,
        FullName = FullName,
        PreferredLanguage = PreferredLanguage,
        HoursRemaining = HoursRemaining,
        UnappliedCredit = UnappliedCredit,
        SessionsCompleted = SessionsCompleted,
        LastUpdatedUtc = LastUpdatedUtc,
        UpcomingSessions = UpcomingSessions.Select(s => new SessionView
        {
            SessionId = s.SessionId,
            StartTime = s.StartTime,
            EndTime = s.EndTime,
            DurationMinutes = s.DurationMinutes,
            Status = s.Status,
            Notes = s.Notes
        }).ToList(),
        RecentPayments = RecentPayments.Select(p => new PaymentView
        {
            PaymentId = p.PaymentId,
            Amount = p.Amount,
            Method = p.Method,
            PaidDate = p.PaidDate
        }).ToList()
    };
}

internal sealed record CosmosSession
{
    public long SessionId { get; init; }
    public DateTime StartTime { get; init; }
    public DateTime EndTime { get; init; }
    public int DurationMinutes { get; init; }
    public string Status { get; init; } = "";
    public string? Notes { get; init; }
}

internal sealed record CosmosPayment
{
    public long PaymentId { get; init; }
    public decimal Amount { get; init; }
    public string Method { get; init; } = "";
    public DateTime PaidDate { get; init; }
}
