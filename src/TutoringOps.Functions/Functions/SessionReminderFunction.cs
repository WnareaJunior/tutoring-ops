using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using TutoringOps.Functions.Models;
using TutoringOps.Functions.Services;

namespace TutoringOps.Functions.Functions;

/// <summary>
/// Subscription: reminders.
///
/// Sends the parent a confirmation when a session is booked, a reminder the day
/// before, and a note when something is cancelled -- in Spanish when that is the
/// family's language.
///
/// Delivery from the outbox is at-least-once, so this function can see the same
/// event twice. A duplicate confirmation email is a minor annoyance rather than
/// a correctness problem, which is why the reminder side tolerates it while the
/// billing side is written to be idempotent.
/// </summary>
public sealed class SessionReminderFunction
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly IEmailSender _email;
    private readonly ILogger<SessionReminderFunction> _logger;

    public SessionReminderFunction(IEmailSender email, ILogger<SessionReminderFunction> logger)
    {
        _email = email;
        _logger = logger;
    }

    [Function("SendSessionReminder")]
    public async Task RunAsync(
        [ServiceBusTrigger(
            topicName: "%ServiceBusTopicName%",
            subscriptionName: "%ServiceBusRemindersSubscription%",
            Connection = "ServiceBusConnection")]
        string messageBody,
        FunctionContext context,
        CancellationToken cancellationToken)
    {
        var sessionEvent = Deserialise(messageBody);

        _logger.LogInformation(
            "Reminder trigger: {EventType} for session {SessionId} (student {StudentId}).",
            sessionEvent.EventType, sessionEvent.SessionId, sessionEvent.StudentId);

        var message = EmailTemplates.Build(sessionEvent);
        if (message is null)
        {
            // Not every event on this subscription needs an email; completions
            // and package events pass through silently.
            _logger.LogDebug("No parent email defined for {EventType}.", sessionEvent.EventType);
            return;
        }

        if (string.IsNullOrWhiteSpace(sessionEvent.ParentContact))
        {
            _logger.LogWarning(
                "Session {SessionId} has no parent contact; nothing to send.",
                sessionEvent.SessionId);
            return;
        }

        await _email.SendAsync(sessionEvent.ParentContact, message, cancellationToken);
    }

    private SessionEvent Deserialise(string body)
    {
        try
        {
            return JsonSerializer.Deserialize<SessionEvent>(body, JsonOptions)
                ?? throw new InvalidOperationException("Message body deserialised to null.");
        }
        catch (JsonException ex)
        {
            // Retrying will never fix malformed JSON, but throwing is still
            // right: the retry policy exhausts and the message dead-letters,
            // where it can be looked at instead of vanishing.
            _logger.LogError(ex, "Could not parse event payload: {Body}", body);
            throw;
        }
    }
}
