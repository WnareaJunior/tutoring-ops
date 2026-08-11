using System.Text.Json.Serialization;

namespace TutoringOps.Functions.Models;

/// <summary>
/// The payload PKG_EVENTS assembles. Property names match the JSON_OBJECT keys
/// in db/migrations/03_pkg_events.sql -- if you rename one there, rename it
/// here. Nothing else in this project depends on those names.
/// </summary>
public sealed record SessionEvent
{
    [JsonPropertyName("eventType")]
    public string EventType { get; init; } = string.Empty;

    [JsonPropertyName("sessionId")]
    public long SessionId { get; init; }

    [JsonPropertyName("studentId")]
    public long StudentId { get; init; }

    [JsonPropertyName("studentName")]
    public string StudentName { get; init; } = string.Empty;

    [JsonPropertyName("parentContact")]
    public string ParentContact { get; init; } = string.Empty;

    /// <summary>"EN" or "ES". Decides which reminder template is used.</summary>
    [JsonPropertyName("preferredLanguage")]
    public string PreferredLanguage { get; init; } = "EN";

    [JsonPropertyName("packageId")]
    public long? PackageId { get; init; }

    /// <summary>Business-local wall clock, ISO 8601 without an offset.</summary>
    [JsonPropertyName("startTime")]
    public DateTime StartTime { get; init; }

    [JsonPropertyName("endTime")]
    public DateTime EndTime { get; init; }

    [JsonPropertyName("durationMinutes")]
    public int DurationMinutes { get; init; }

    [JsonPropertyName("status")]
    public string Status { get; init; } = string.Empty;

    [JsonPropertyName("hoursRemaining")]
    public decimal HoursRemaining { get; init; }

    [JsonPropertyName("occurredAt")]
    public DateTime OccurredAt { get; init; }
}

/// <summary>Event type names, kept in one place to avoid string drift.</summary>
public static class EventTypes
{
    public const string SessionBooked = "SessionBooked";
    public const string SessionCancelled = "SessionCancelled";
    public const string SessionLateCancelled = "SessionLateCancelled";
    public const string SessionCompleted = "SessionCompleted";
    public const string SessionReminderDue = "SessionReminderDue";
    public const string PackagePurchased = "PackagePurchased";
    public const string PackageExhausted = "PackageExhausted";
    public const string PaymentRecorded = "PaymentRecorded";
}
