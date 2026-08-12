namespace TutoringOps.Api.Configuration;

/// <summary>
/// Oracle connection settings. The connection string itself never lives in
/// appsettings.json -- it comes from user secrets locally and from Azure app
/// configuration when deployed.
/// </summary>
public sealed class OracleOptions
{
    public const string SectionName = "Oracle";

    public string ConnectionString { get; set; } = string.Empty;

    /// <summary>Seconds before a command against Oracle is abandoned.</summary>
    public int CommandTimeoutSeconds { get; set; } = 30;
}

/// <summary>
/// Service Bus destinations for the outbox publisher. When
/// <see cref="ConnectionString"/> is empty the API logs events instead of
/// sending them, so the whole stack still runs on a laptop with no Azure
/// subscription attached.
/// </summary>
public sealed class ServiceBusOptions
{
    public const string SectionName = "ServiceBus";

    public string ConnectionString { get; set; } = string.Empty;

    /// <summary>Queue carrying every session event, for durable processing.</summary>
    public string QueueName { get; set; } = "session-events";

    /// <summary>Topic fanning the same events out to reminders and billing.</summary>
    public string TopicName { get; set; } = "session-notifications";

    public bool IsConfigured => !string.IsNullOrWhiteSpace(ConnectionString);
}

/// <summary>
/// Event Grid is a side-channel for a small number of event types that want a
/// handler of their own rather than a queue consumer — today just
/// PackageExhausted, which is a cue to sell the next block of hours.
///
/// Inert until both endpoint and key are set, so the core outbox path is
/// unaffected on a system that has never provisioned it.
/// </summary>
public sealed class EventGridOptions
{
    public const string SectionName = "EventGrid";

    public string TopicEndpoint { get; set; } = string.Empty;
    public string AccessKey { get; set; } = string.Empty;

    /// <summary>
    /// Outbox event types mirrored to Event Grid. Deliberately a short list:
    /// everything already goes to Service Bus, and this is for events that
    /// warrant a distinct handler rather than a second copy of the firehose.
    /// </summary>
    public string[] EventTypes { get; set; } = ["PackageExhausted"];

    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(TopicEndpoint) && !string.IsNullOrWhiteSpace(AccessKey);
}

/// <summary>Polling behaviour of the outbox publisher.</summary>
public sealed class OutboxOptions
{
    public const string SectionName = "Outbox";

    public bool Enabled { get; set; } = true;

    /// <summary>How long to wait between drains when the last one was empty.</summary>
    public int PollIntervalSeconds { get; set; } = 5;

    /// <summary>Events claimed per transaction.</summary>
    public int BatchSize { get; set; } = 50;
}
