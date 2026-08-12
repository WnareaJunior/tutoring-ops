using Azure;
using Azure.Messaging.EventGrid;
using Microsoft.Extensions.Options;
using TutoringOps.Api.Configuration;

namespace TutoringOps.Api.Outbox;

public interface IEventGridPublisher
{
    /// <summary>True when this event type is one Event Grid should receive.</summary>
    bool Handles(string eventType);

    Task PublishAsync(OutboxEvent outboxEvent, CancellationToken cancellationToken);

    string Description { get; }
}

/// <summary>
/// Mirrors selected outbox events to an Event Grid custom topic.
///
/// This is not a second copy of the event stream. Service Bus carries
/// everything and is where processing lives; Event Grid carries the handful of
/// events that want their own handler and no ordering guarantees — right now
/// just PackageExhausted, which exists to prompt selling the next package.
///
/// Failures propagate. That is deliberate and worth understanding: the outbox
/// publisher rolls the whole batch back on any send failure, so a misconfigured
/// Event Grid topic will stall *all* event delivery rather than silently
/// dropping these. The alternative -- swallowing the error -- would mean the
/// outbox no longer guarantees delivery to a destination it claims to serve,
/// and a guarantee with an undocumented exception is worse than none. Watch
/// GET /ops/outbox; a climbing pending count is the symptom.
/// </summary>
public sealed class AzureEventGridPublisher : IEventGridPublisher
{
    private readonly EventGridPublisherClient _client;
    private readonly HashSet<string> _eventTypes;
    private readonly ILogger<AzureEventGridPublisher> _logger;

    public AzureEventGridPublisher(
        IOptions<EventGridOptions> options,
        ILogger<AzureEventGridPublisher> logger)
    {
        var settings = options.Value;
        _logger = logger;

        _client = new EventGridPublisherClient(
            new Uri(settings.TopicEndpoint),
            new AzureKeyCredential(settings.AccessKey));

        _eventTypes = new HashSet<string>(settings.EventTypes, StringComparer.OrdinalIgnoreCase);

        Description = $"Event Grid ({string.Join(", ", _eventTypes)})";
    }

    public string Description { get; }

    public bool Handles(string eventType) => _eventTypes.Contains(eventType);

    public async Task PublishAsync(OutboxEvent outboxEvent, CancellationToken cancellationToken)
    {
        // Subject is a resource path so a subscription can filter on prefix --
        // "everything for student 12" is then a filter rather than code in a
        // handler.
        var subject = $"students/{outboxEvent.AggregateId}/{outboxEvent.AggregateType.ToLowerInvariant()}";

        var gridEvent = new EventGridEvent(
            subject: subject,
            eventType: $"TutoringOps.{outboxEvent.EventType}",
            dataVersion: "1.0",
            data: new BinaryData(outboxEvent.Payload))
        {
            // Same id as the outbox row, so a redelivery is recognisable as one.
            Id = outboxEvent.EventId.ToString(),
            EventTime = outboxEvent.CreatedAt
        };

        await _client.SendEventAsync(gridEvent, cancellationToken);

        _logger.LogInformation(
            "Mirrored event {EventId} ({EventType}) to Event Grid.",
            outboxEvent.EventId, outboxEvent.EventType);
    }
}

/// <summary>
/// What you get when Event Grid is not configured: it handles nothing, so the
/// publisher never calls it. Keeps the stretch feature entirely off the core
/// path rather than half-wired into it.
/// </summary>
public sealed class DisabledEventGridPublisher : IEventGridPublisher
{
    public string Description => "Event Grid (not configured)";

    public bool Handles(string eventType) => false;

    public Task PublishAsync(OutboxEvent outboxEvent, CancellationToken cancellationToken) =>
        Task.CompletedTask;
}
