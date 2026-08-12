using System.Text.Json;
using Azure.Messaging.EventGrid;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using TutoringOps.Functions.Models;
using TutoringOps.Functions.Services;

namespace TutoringOps.Functions.Functions;

/// <summary>
/// Event Grid handler for PackageExhausted.
///
/// The event is raised by PKG_BILLING.refresh_package_status the instant a
/// package's last hour is reserved — not on a nightly sweep, not when someone
/// remembers to look. This handler turns that into an email to the tutor,
/// because a student running out of hours is a sales moment that is otherwise
/// only visible to anyone who happens to be reading the balances column.
///
/// Deliberately separate from the Service Bus consumers. Those two subscriptions
/// serve the family — confirmations, reminders, the dashboard. This one serves
/// the business, has a different audience and a different failure tolerance, and
/// giving it its own path means a broken sales nudge can never delay a parent's
/// reminder email.
/// </summary>
public sealed class PackageExhaustedFunction
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly IEmailSender _email;
    private readonly IConfiguration _configuration;
    private readonly ILogger<PackageExhaustedFunction> _logger;

    public PackageExhaustedFunction(
        IEmailSender email,
        IConfiguration configuration,
        ILogger<PackageExhaustedFunction> logger)
    {
        _email = email;
        _configuration = configuration;
        _logger = logger;
    }

    [Function("PackageExhaustedHandler")]
    public async Task RunAsync(
        [EventGridTrigger] EventGridEvent gridEvent,
        CancellationToken cancellationToken)
    {
        _logger.LogInformation(
            "Event Grid delivered {EventType} for {Subject}.",
            gridEvent.EventType, gridEvent.Subject);

        // The topic could carry other types later; only act on the one this
        // handler is about rather than assuming the subscription filter is the
        // only thing standing between us and unrelated events.
        if (!gridEvent.EventType.EndsWith(EventTypes.PackageExhausted, StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogDebug("Ignoring {EventType}.", gridEvent.EventType);
            return;
        }

        PackageEvent packageEvent;
        try
        {
            packageEvent = gridEvent.Data.ToObjectFromJson<PackageEvent>(JsonOptions)
                ?? throw new InvalidOperationException("Event data deserialised to null.");
        }
        catch (JsonException ex)
        {
            _logger.LogError(ex, "Could not parse package event data: {Data}", gridEvent.Data);
            throw;
        }

        var recipient = _configuration["TutorNotificationEmail"];
        if (string.IsNullOrWhiteSpace(recipient))
        {
            // Nothing to retry towards. Failing loudly here would dead-letter an
            // event over a missing setting, so say what is wrong and stop.
            _logger.LogWarning(
                "TutorNotificationEmail is not configured; not sending the nudge for " +
                "student {StudentId}, package {PackageId}.",
                packageEvent.StudentId, packageEvent.PackageId);
            return;
        }

        await _email.SendAsync(
            recipient,
            EmailTemplates.BuildPackageExhausted(packageEvent),
            cancellationToken);

        _logger.LogInformation(
            "Notified {Recipient} that {StudentName} exhausted package {PackageId}.",
            recipient, packageEvent.StudentName, packageEvent.PackageId);
    }
}
