using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TutoringOps.Web.Services;

// The shapes the API returns. Kept here rather than shared from the API project
// so the UI depends on the HTTP contract, not on the API's internals.

public sealed record StudentSummary
{
    [JsonPropertyName("studentId")] public long StudentId { get; init; }
    [JsonPropertyName("fullName")] public string FullName { get; init; } = "";
    [JsonPropertyName("parentContact")] public string ParentContact { get; init; } = "";
    [JsonPropertyName("preferredLanguage")] public string PreferredLanguage { get; init; } = "EN";
    [JsonPropertyName("isActive")] public bool IsActive { get; init; }
    [JsonPropertyName("hoursRemaining")] public decimal HoursRemaining { get; init; }
}

public sealed record SessionView
{
    [JsonPropertyName("sessionId")] public long SessionId { get; init; }
    [JsonPropertyName("studentId")] public long StudentId { get; init; }
    [JsonPropertyName("studentName")] public string? StudentName { get; init; }
    [JsonPropertyName("startTime")] public DateTime StartTime { get; init; }
    [JsonPropertyName("endTime")] public DateTime EndTime { get; init; }
    [JsonPropertyName("durationMinutes")] public int DurationMinutes { get; init; }
    [JsonPropertyName("status")] public string Status { get; init; } = "";
    [JsonPropertyName("notes")] public string? Notes { get; init; }
}

public sealed record StudentDashboard
{
    [JsonPropertyName("studentId")] public long StudentId { get; init; }
    [JsonPropertyName("fullName")] public string FullName { get; init; } = "";
    [JsonPropertyName("preferredLanguage")] public string PreferredLanguage { get; init; } = "EN";
    [JsonPropertyName("hoursRemaining")] public decimal HoursRemaining { get; init; }
    [JsonPropertyName("unappliedCredit")] public decimal UnappliedCredit { get; init; }
    [JsonPropertyName("sessionsCompleted")] public int SessionsCompleted { get; init; }
    [JsonPropertyName("upcomingSessions")] public List<SessionView> UpcomingSessions { get; init; } = [];
    [JsonPropertyName("recentPayments")] public List<PaymentView> RecentPayments { get; init; } = [];
    [JsonPropertyName("lastUpdatedUtc")] public DateTime LastUpdatedUtc { get; init; }
}

public sealed record PaymentView
{
    [JsonPropertyName("paymentId")] public long PaymentId { get; init; }
    [JsonPropertyName("amount")] public decimal Amount { get; init; }
    [JsonPropertyName("method")] public string Method { get; init; } = "";
    [JsonPropertyName("paidDate")] public DateTime PaidDate { get; init; }
}

/// <summary>The failure the API reported, with its PL/SQL result code intact.</summary>
public sealed record ApiProblem(string Code, string Detail, HttpStatusCode Status);

/// <summary>
/// The admin pages' route to the system. Every write goes through the API,
/// which goes through PL/SQL -- the UI never reaches Oracle and never decides
/// whether an action is allowed.
/// </summary>
public sealed class TutoringApiClient
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly HttpClient _http;
    private readonly ILogger<TutoringApiClient> _logger;

    public TutoringApiClient(HttpClient http, ILogger<TutoringApiClient> logger)
    {
        _http = http;
        _logger = logger;
    }

    public async Task<IReadOnlyList<StudentSummary>> GetStudentsAsync(
        bool activeOnly, CancellationToken cancellationToken)
    {
        var students = await _http.GetFromJsonAsync<List<StudentSummary>>(
            $"students?activeOnly={activeOnly.ToString().ToLowerInvariant()}",
            JsonOptions, cancellationToken);

        return students ?? [];
    }

    public async Task<IReadOnlyList<SessionView>> GetScheduleAsync(
        DateOnly from, DateOnly to, CancellationToken cancellationToken)
    {
        var sessions = await _http.GetFromJsonAsync<List<SessionView>>(
            $"sessions?from={from:yyyy-MM-dd}&to={to:yyyy-MM-dd}",
            JsonOptions, cancellationToken);

        return sessions ?? [];
    }

    public async Task<StudentDashboard?> GetDashboardAsync(
        long studentId, CancellationToken cancellationToken)
    {
        var response = await _http.GetAsync(
            $"students/{studentId}/dashboard", cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        return await response.Content.ReadFromJsonAsync<StudentDashboard>(
            JsonOptions, cancellationToken);
    }

    public async Task<StudentDashboard?> GetDashboardByCodeAsync(
        string accessCode, CancellationToken cancellationToken)
    {
        var response = await _http.GetAsync($"students/by-code/{accessCode}", cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        var student = await response.Content.ReadFromJsonAsync<StudentSummary>(
            JsonOptions, cancellationToken);

        return student is null
            ? null
            : await GetDashboardAsync(student.StudentId, cancellationToken);
    }

    public async Task<ApiProblem?> BookAsync(
        long studentId, DateTime startTime, int durationMinutes, string? notes,
        CancellationToken cancellationToken)
    {
        var response = await _http.PostAsJsonAsync("sessions", new
        {
            studentId,
            startTime = startTime.ToString("s"),
            durationMinutes,
            notes
        }, cancellationToken);

        return await ReadProblemAsync(response, cancellationToken);
    }

    public async Task<ApiProblem?> CancelAsync(long sessionId, CancellationToken cancellationToken) =>
        await ReadProblemAsync(
            await _http.DeleteAsync($"sessions/{sessionId}", cancellationToken),
            cancellationToken);

    public async Task<ApiProblem?> CompleteAsync(long sessionId, CancellationToken cancellationToken) =>
        await ReadProblemAsync(
            await _http.PostAsync($"sessions/{sessionId}/complete", null, cancellationToken),
            cancellationToken);

    public async Task<ApiProblem?> ConfirmAsync(long sessionId, CancellationToken cancellationToken) =>
        await ReadProblemAsync(
            await _http.PostAsync($"sessions/{sessionId}/confirm", null, cancellationToken),
            cancellationToken);

    public async Task<ApiProblem?> PurchasePackageAsync(
        long studentId, decimal hours, decimal amount, string method,
        CancellationToken cancellationToken)
    {
        var response = await _http.PostAsJsonAsync("packages", new
        {
            studentId, hours, amount, method
        }, cancellationToken);

        return await ReadProblemAsync(response, cancellationToken);
    }

    public async Task<ApiProblem?> CreateStudentAsync(
        string fullName, string parentContact, string? parentPhone, string language,
        CancellationToken cancellationToken)
    {
        var response = await _http.PostAsJsonAsync("students", new
        {
            fullName, parentContact, parentPhone, preferredLanguage = language
        }, cancellationToken);

        return await ReadProblemAsync(response, cancellationToken);
    }

    /// <summary>
    /// Null on success. On failure the problem-details title carries the PL/SQL
    /// result code, so the page can show the real reason a booking was refused
    /// rather than a generic "something went wrong".
    /// </summary>
    private async Task<ApiProblem?> ReadProblemAsync(
        HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (response.IsSuccessStatusCode)
        {
            return null;
        }

        try
        {
            var problem = await response.Content.ReadFromJsonAsync<ProblemShape>(
                JsonOptions, cancellationToken);

            return new ApiProblem(
                problem?.Title ?? "ERR_UNKNOWN",
                problem?.Detail ?? "The request was refused.",
                response.StatusCode);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not read the problem body from a {Status} response.",
                (int)response.StatusCode);
            return new ApiProblem("ERR_UNKNOWN", "The request was refused.", response.StatusCode);
        }
    }

    private sealed record ProblemShape(string? Title, string? Detail, int? Status);
}
