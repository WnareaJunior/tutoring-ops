using System.Text.Json.Serialization;

namespace TutoringOps.Functions.Models;

/// <summary>
/// The Cosmos read model: one document per student, in the shape the parent
/// status page renders.
///
/// Written only by the billing function, read only by the UI. That one-way flow
/// is the whole design -- there is no path by which a stale or wrong document
/// can corrupt the Oracle data it is derived from, so the worst case is a
/// dashboard that lags by a few seconds.
/// </summary>
public sealed record StudentDashboardDocument
{
    /// <summary>Cosmos document id: the student id as a string.</summary>
    [JsonPropertyName("id")]
    public string Id { get; init; } = string.Empty;

    /// <summary>Partition key (/studentId). Same value as <see cref="Id"/>.</summary>
    [JsonPropertyName("studentId")]
    public string StudentId { get; init; } = string.Empty;

    [JsonPropertyName("fullName")]
    public string FullName { get; init; } = string.Empty;

    [JsonPropertyName("parentContact")]
    public string ParentContact { get; init; } = string.Empty;

    [JsonPropertyName("preferredLanguage")]
    public string PreferredLanguage { get; init; } = "EN";

    [JsonPropertyName("hoursRemaining")]
    public decimal HoursRemaining { get; init; }

    [JsonPropertyName("unappliedCredit")]
    public decimal UnappliedCredit { get; init; }

    [JsonPropertyName("sessionsCompleted")]
    public int SessionsCompleted { get; init; }

    [JsonPropertyName("upcomingSessions")]
    public IReadOnlyList<DashboardSession> UpcomingSessions { get; init; } = [];

    [JsonPropertyName("recentPayments")]
    public IReadOnlyList<DashboardPayment> RecentPayments { get; init; } = [];

    [JsonPropertyName("lastUpdatedUtc")]
    public DateTime LastUpdatedUtc { get; init; }

    /// <summary>
    /// What caused this version of the document. Useful when a dashboard looks
    /// wrong and the question is which event last touched it.
    /// </summary>
    [JsonPropertyName("lastEventType")]
    public string? LastEventType { get; init; }
}

public sealed record DashboardSession
{
    [JsonPropertyName("sessionId")]
    public long SessionId { get; init; }

    [JsonPropertyName("startTime")]
    public DateTime StartTime { get; init; }

    [JsonPropertyName("endTime")]
    public DateTime EndTime { get; init; }

    [JsonPropertyName("durationMinutes")]
    public int DurationMinutes { get; init; }

    [JsonPropertyName("status")]
    public string Status { get; init; } = string.Empty;

    [JsonPropertyName("notes")]
    public string? Notes { get; init; }
}

public sealed record DashboardPayment
{
    [JsonPropertyName("paymentId")]
    public long PaymentId { get; init; }

    [JsonPropertyName("amount")]
    public decimal Amount { get; init; }

    [JsonPropertyName("method")]
    public string Method { get; init; } = string.Empty;

    [JsonPropertyName("paidDate")]
    public DateTime PaidDate { get; init; }
}

/// <summary>The API's dashboard response, deserialised.</summary>
public sealed record StudentDashboardResponse
{
    [JsonPropertyName("studentId")]
    public long StudentId { get; init; }

    [JsonPropertyName("fullName")]
    public string FullName { get; init; } = string.Empty;

    [JsonPropertyName("parentContact")]
    public string ParentContact { get; init; } = string.Empty;

    [JsonPropertyName("preferredLanguage")]
    public string PreferredLanguage { get; init; } = "EN";

    [JsonPropertyName("hoursRemaining")]
    public decimal HoursRemaining { get; init; }

    [JsonPropertyName("unappliedCredit")]
    public decimal UnappliedCredit { get; init; }

    [JsonPropertyName("sessionsCompleted")]
    public int SessionsCompleted { get; init; }

    [JsonPropertyName("upcomingSessions")]
    public List<ApiSession> UpcomingSessions { get; init; } = [];

    [JsonPropertyName("recentPayments")]
    public List<ApiPayment> RecentPayments { get; init; } = [];
}

public sealed record ApiSession
{
    [JsonPropertyName("sessionId")] public long SessionId { get; init; }
    [JsonPropertyName("startTime")] public DateTime StartTime { get; init; }
    [JsonPropertyName("endTime")] public DateTime EndTime { get; init; }
    [JsonPropertyName("durationMinutes")] public int DurationMinutes { get; init; }
    [JsonPropertyName("status")] public string Status { get; init; } = string.Empty;
    [JsonPropertyName("notes")] public string? Notes { get; init; }
}

public sealed record ApiPayment
{
    [JsonPropertyName("paymentId")] public long PaymentId { get; init; }
    [JsonPropertyName("amount")] public decimal Amount { get; init; }
    [JsonPropertyName("method")] public string Method { get; init; } = string.Empty;
    [JsonPropertyName("paidDate")] public DateTime PaidDate { get; init; }
}
