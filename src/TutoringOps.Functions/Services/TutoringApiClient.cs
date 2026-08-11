using System.Net;
using System.Net.Http.Json;
using Microsoft.Extensions.Logging;
using TutoringOps.Functions.Models;

namespace TutoringOps.Functions.Services;

/// <summary>
/// The functions' only route to Oracle.
///
/// They deliberately do not hold a database connection of their own. Oracle
/// lives on a machine at home behind a tunnel; funnelling every read through
/// the API means one component holds that connection string and one component
/// knows the PL/SQL contract. It also means the read model is built from
/// exactly the data the parent page would show, because it is literally the
/// same endpoint.
/// </summary>
public sealed class TutoringApiClient
{
    private readonly HttpClient _http;
    private readonly ILogger<TutoringApiClient> _logger;

    public TutoringApiClient(HttpClient http, ILogger<TutoringApiClient> logger)
    {
        _http = http;
        _logger = logger;
    }

    public async Task<StudentDashboardResponse?> GetDashboardAsync(
        long studentId, CancellationToken cancellationToken)
    {
        var response = await _http.GetAsync(
            $"students/{studentId}/dashboard", cancellationToken);

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            // The student was deleted between the event and this call. Nothing
            // to project, and no reason to retry forever.
            _logger.LogWarning("Student {StudentId} not found; skipping projection.", studentId);
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<StudentDashboardResponse>(
            cancellationToken: cancellationToken);
    }

    /// <summary>
    /// Asks the API to queue reminder events for sessions starting soon.
    /// Returns how many were queued.
    /// </summary>
    public async Task<int> QueueRemindersAsync(int hoursAhead, CancellationToken cancellationToken)
    {
        var response = await _http.PostAsync(
            $"ops/reminders?hoursAhead={hoursAhead}", content: null, cancellationToken);

        response.EnsureSuccessStatusCode();

        var result = await response.Content.ReadFromJsonAsync<QueueRemindersResult>(
            cancellationToken: cancellationToken);

        return result?.Queued ?? 0;
    }

    private sealed record QueueRemindersResult(int Queued, int HoursAhead);
}
