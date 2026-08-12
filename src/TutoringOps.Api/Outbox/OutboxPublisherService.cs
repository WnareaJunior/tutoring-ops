using Microsoft.Extensions.Options;
using TutoringOps.Api.Configuration;

namespace TutoringOps.Api.Outbox;

/// <summary>
/// Drains EVENT_OUTBOX into Service Bus.
///
/// The loop is deliberately dull: claim a batch inside a transaction, send each
/// message, mark each row published, commit once. A failure anywhere rolls the
/// whole batch back and the rows are claimed again next tick.
///
/// That gives at-least-once delivery, not exactly-once -- a send can succeed
/// and the commit still fail, replaying that message on the next pass. The
/// consumers are written to tolerate it, and every message carries a stable
/// MessageId so Service Bus duplicate detection can be switched on later.
///
/// Polling rather than a change feed is a deliberate fit to the scale: a
/// handful of bookings a day does not justify anything cleverer.
/// </summary>
public sealed class OutboxPublisherService : BackgroundService
{
    private readonly OutboxRepository _outbox;
    private readonly IEventPublisher _publisher;
    private readonly IEventGridPublisher _eventGrid;
    private readonly OutboxOptions _options;
    private readonly ILogger<OutboxPublisherService> _logger;

    public OutboxPublisherService(
        OutboxRepository outbox,
        IEventPublisher publisher,
        IEventGridPublisher eventGrid,
        IOptions<OutboxOptions> options,
        ILogger<OutboxPublisherService> logger)
    {
        _outbox = outbox;
        _publisher = publisher;
        _eventGrid = eventGrid;
        _options = options.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.Enabled)
        {
            _logger.LogWarning("Outbox publisher is disabled by configuration.");
            return;
        }

        var interval = TimeSpan.FromSeconds(Math.Max(1, _options.PollIntervalSeconds));
        _logger.LogInformation(
            "Outbox publisher started. Target: {Target}. Polling every {Interval}s, batches of {Batch}.",
            _publisher.Description, interval.TotalSeconds, _options.BatchSize);

        while (!stoppingToken.IsCancellationRequested)
        {
            int published;
            try
            {
                published = await DrainOnceAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // Never let a transient database or Service Bus fault kill the
                // loop; the rows are still in the outbox either way.
                _logger.LogError(ex, "Outbox drain failed; retrying after {Interval}s.",
                    interval.TotalSeconds);
                published = 0;
            }

            // A full batch probably means more is waiting, so go straight round
            // again instead of sleeping through a backlog.
            if (published < _options.BatchSize)
            {
                try
                {
                    await Task.Delay(interval, stoppingToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }

        _logger.LogInformation("Outbox publisher stopped.");
    }

    private async Task<int> DrainOnceAsync(CancellationToken cancellationToken)
    {
        await using var connection = await _outbox.OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();

        var events = await _outbox.ClaimBatchAsync(
            connection, _options.BatchSize, cancellationToken);

        if (events.Count == 0)
        {
            // Nothing claimed, but CLAIM_BATCH bumped no counters either.
            transaction.Rollback();
            return 0;
        }

        foreach (var outboxEvent in events)
        {
            try
            {
                await _publisher.PublishAsync(outboxEvent, cancellationToken);

                // Service Bus first, always. Event Grid is a side-channel for a
                // couple of event types and must never come before the
                // destination that everything actually depends on.
                if (_eventGrid.Handles(outboxEvent.EventType))
                {
                    await _eventGrid.PublishAsync(outboxEvent, cancellationToken);
                }

                await _outbox.MarkPublishedAsync(connection, outboxEvent.EventId, cancellationToken);
            }
            catch (Exception ex)
            {
                transaction.Rollback();

                // Written on its own connection so it survives the rollback.
                await _outbox.MarkFailedAsync(outboxEvent.EventId, ex.Message, CancellationToken.None);

                _logger.LogError(ex,
                    "Failed to publish event {EventId} ({EventType}); rolled back the batch.",
                    outboxEvent.EventId, outboxEvent.EventType);
                throw;
            }
        }

        transaction.Commit();

        _logger.LogInformation("Published {Count} event(s) to {Target}.",
            events.Count, _publisher.Description);

        return events.Count;
    }
}
