using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using TutoringOps.Functions.Models;
using TutoringOps.Functions.Services;

namespace TutoringOps.Functions.Functions;

/// <summary>
/// Subscription: billing-updates.
///
/// Rebuilds a student's dashboard document in Cosmos whenever anything about
/// their schedule or balance changes.
///
/// It does not compute the new balance from the event -- it re-reads the whole
/// dashboard from the API and writes that. That makes the function idempotent
/// and order-independent for free: replaying an old event just writes current
/// truth again, where applying a delta twice would quietly corrupt the number a
/// parent reads.
/// </summary>
public sealed class BillingProjectionFunction
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly TutoringApiClient _api;
    private readonly IReadModelStore _store;
    private readonly ILogger<BillingProjectionFunction> _logger;

    public BillingProjectionFunction(
        TutoringApiClient api,
        IReadModelStore store,
        ILogger<BillingProjectionFunction> logger)
    {
        _api = api;
        _store = store;
        _logger = logger;
    }

    [Function("UpdateStudentReadModel")]
    public async Task RunAsync(
        [ServiceBusTrigger(
            topicName: "%ServiceBusTopicName%",
            subscriptionName: "%ServiceBusBillingSubscription%",
            Connection = "ServiceBusConnection")]
        string messageBody,
        FunctionContext context,
        CancellationToken cancellationToken)
    {
        SessionEvent sessionEvent;
        try
        {
            sessionEvent = JsonSerializer.Deserialize<SessionEvent>(messageBody, JsonOptions)
                ?? throw new InvalidOperationException("Message body deserialised to null.");
        }
        catch (JsonException ex)
        {
            _logger.LogError(ex, "Could not parse event payload: {Body}", messageBody);
            throw;
        }

        if (sessionEvent.StudentId <= 0)
        {
            _logger.LogWarning("Event {EventType} carried no student id; nothing to project.",
                sessionEvent.EventType);
            return;
        }

        _logger.LogInformation(
            "Projecting student {StudentId} after {EventType}.",
            sessionEvent.StudentId, sessionEvent.EventType);

        var dashboard = await _api.GetDashboardAsync(sessionEvent.StudentId, cancellationToken);
        if (dashboard is null)
        {
            return;
        }

        var document = new StudentDashboardDocument
        {
            Id = dashboard.StudentId.ToString(),
            StudentId = dashboard.StudentId.ToString(),
            FullName = dashboard.FullName,
            ParentContact = dashboard.ParentContact,
            PreferredLanguage = dashboard.PreferredLanguage,
            HoursRemaining = dashboard.HoursRemaining,
            UnappliedCredit = dashboard.UnappliedCredit,
            SessionsCompleted = dashboard.SessionsCompleted,
            UpcomingSessions = dashboard.UpcomingSessions
                .Select(s => new DashboardSession
                {
                    SessionId = s.SessionId,
                    StartTime = s.StartTime,
                    EndTime = s.EndTime,
                    DurationMinutes = s.DurationMinutes,
                    Status = s.Status,
                    Notes = s.Notes
                })
                .ToList(),
            RecentPayments = dashboard.RecentPayments
                .Select(p => new DashboardPayment
                {
                    PaymentId = p.PaymentId,
                    Amount = p.Amount,
                    Method = p.Method,
                    PaidDate = p.PaidDate
                })
                .ToList(),
            LastUpdatedUtc = DateTime.UtcNow,
            LastEventType = sessionEvent.EventType
        };

        await _store.UpsertAsync(document, cancellationToken);
    }
}
