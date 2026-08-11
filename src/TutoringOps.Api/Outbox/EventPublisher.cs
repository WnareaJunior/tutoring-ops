using System.Text;
using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.Options;
using TutoringOps.Api.Configuration;

namespace TutoringOps.Api.Outbox;

public interface IEventPublisher : IAsyncDisposable
{
    /// <summary>
    /// Sends one outbox event to its destinations. Throws on failure -- the
    /// publisher relies on that to roll the batch back and retry.
    /// </summary>
    Task PublishAsync(OutboxEvent outboxEvent, CancellationToken cancellationToken);

    string Description { get; }
}

/// <summary>
/// Sends each event twice on purpose: once to the queue, which is the durable
/// work list, and once to the topic, which fans out to the reminder and billing
/// subscriptions. The queue exists so a consumer can be added later without
/// having missed anything; the topic exists so today's two consumers do not
/// have to compete for the same messages.
/// </summary>
public sealed class ServiceBusEventPublisher : IEventPublisher
{
    private readonly ServiceBusClient _client;
    private readonly ServiceBusSender _queueSender;
    private readonly ServiceBusSender _topicSender;
    private readonly ILogger<ServiceBusEventPublisher> _logger;

    public ServiceBusEventPublisher(
        IOptions<ServiceBusOptions> options,
        ILogger<ServiceBusEventPublisher> logger)
    {
        var settings = options.Value;
        _logger = logger;

        _client = new ServiceBusClient(settings.ConnectionString);
        _queueSender = _client.CreateSender(settings.QueueName);
        _topicSender = _client.CreateSender(settings.TopicName);

        Description = $"Service Bus (queue: {settings.QueueName}, topic: {settings.TopicName})";
    }

    public string Description { get; }

    public async Task PublishAsync(OutboxEvent outboxEvent, CancellationToken cancellationToken)
    {
        var message = new ServiceBusMessage(new BinaryData(Encoding.UTF8.GetBytes(outboxEvent.Payload)))
        {
            ContentType = "application/json",
            Subject = outboxEvent.EventType,
            // The outbox id is the natural dedup key: it is stable across
            // retries of the same event, which is what makes duplicate
            // delivery detectable downstream.
            MessageId = outboxEvent.EventId.ToString(),
            CorrelationId = $"{outboxEvent.AggregateType}:{outboxEvent.AggregateId}"
        };

        // Subscription filters are written against these, so they are part of
        // the contract with the Function App, not decoration.
        message.ApplicationProperties["eventType"] = outboxEvent.EventType;
        message.ApplicationProperties["aggregateType"] = outboxEvent.AggregateType;
        message.ApplicationProperties["aggregateId"] = outboxEvent.AggregateId;

        await _queueSender.SendMessageAsync(message, cancellationToken);

        // A message instance cannot be sent twice, so the topic gets its own.
        var topicMessage = new ServiceBusMessage(message);
        await _topicSender.SendMessageAsync(topicMessage, cancellationToken);

        _logger.LogDebug("Published event {EventId} ({EventType})",
            outboxEvent.EventId, outboxEvent.EventType);
    }

    public async ValueTask DisposeAsync()
    {
        await _queueSender.DisposeAsync();
        await _topicSender.DisposeAsync();
        await _client.DisposeAsync();
    }
}

/// <summary>
/// Used when no Service Bus connection string is configured. The whole stack
/// still runs on a laptop with no Azure subscription: events drain from the
/// outbox and land in the log instead of on a queue.
/// </summary>
public sealed class LoggingEventPublisher : IEventPublisher
{
    private readonly ILogger<LoggingEventPublisher> _logger;

    public LoggingEventPublisher(ILogger<LoggingEventPublisher> logger) => _logger = logger;

    public string Description => "console log (Service Bus not configured)";

    public Task PublishAsync(OutboxEvent outboxEvent, CancellationToken cancellationToken)
    {
        _logger.LogInformation("[outbox] {EventType} #{EventId} {Payload}",
            outboxEvent.EventType, outboxEvent.EventId, outboxEvent.Payload);
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
