using System.ComponentModel.DataAnnotations;

namespace TutoringOps.Api.Models;

// Request shapes. Validation here is only about well-formedness -- whether a
// booking is *allowed* is decided in PL/SQL, never here.

public sealed record CreateStudentRequest
{
    [Required, StringLength(120, MinimumLength = 2)]
    public string FullName { get; init; } = string.Empty;

    [Required, EmailAddress, StringLength(200)]
    public string ParentContact { get; init; } = string.Empty;

    [StringLength(40)]
    public string? ParentPhone { get; init; }

    /// <summary>"EN" or "ES". Drives which language reminder emails use.</summary>
    [RegularExpression("^(EN|ES|en|es)$")]
    public string PreferredLanguage { get; init; } = "EN";
}

public sealed record BookSessionRequest
{
    [Required]
    public long StudentId { get; init; }

    [Required]
    public DateTime StartTime { get; init; }

    /// <summary>30-300, in 15 minute steps. The database has the final say.</summary>
    [Range(30, 300)]
    public int DurationMinutes { get; init; } = 60;

    [StringLength(400)]
    public string? Notes { get; init; }

    /// <summary>
    /// When true the session is created as REQUESTED and waits for the tutor,
    /// rather than being confirmed immediately.
    /// </summary>
    public bool AsRequest { get; init; }
}

public sealed record PurchasePackageRequest
{
    [Required]
    public long StudentId { get; init; }

    [Range(0.5, 500)]
    public decimal Hours { get; init; }

    [Range(0, 100000)]
    public decimal Amount { get; init; }

    public string Method { get; init; } = "ZELLE";

    public DateOnly? ExpiresOn { get; init; }
}

public sealed record RecordPaymentRequest
{
    [Required]
    public long StudentId { get; init; }

    [Range(0.01, 100000)]
    public decimal Amount { get; init; }

    public string Method { get; init; } = "ZELLE";

    [StringLength(400)]
    public string? Notes { get; init; }
}

// Response shapes.

public sealed record StudentResponse
{
    public long StudentId { get; init; }
    public string FullName { get; init; } = string.Empty;
    public string ParentContact { get; init; } = string.Empty;
    public string? ParentPhone { get; init; }
    public string PreferredLanguage { get; init; } = "EN";
    public bool IsActive { get; init; }
    public string? AccessCode { get; init; }
    public decimal HoursRemaining { get; init; }
    public decimal UnappliedCredit { get; init; }
    public DateTime CreatedAt { get; init; }
}

public sealed record StudentSummaryResponse
{
    public long StudentId { get; init; }
    public string FullName { get; init; } = string.Empty;
    public string ParentContact { get; init; } = string.Empty;
    public string PreferredLanguage { get; init; } = "EN";
    public bool IsActive { get; init; }
    public decimal HoursRemaining { get; init; }
}

public sealed record SessionResponse
{
    public long SessionId { get; init; }
    public long StudentId { get; init; }
    public string? StudentName { get; init; }
    public DateTime StartTime { get; init; }
    public DateTime EndTime { get; init; }
    public int DurationMinutes { get; init; }
    public string Status { get; init; } = string.Empty;
    public long? PackageId { get; init; }
    public string? Notes { get; init; }
}

public sealed record BookSessionResponse
{
    public long SessionId { get; init; }
    public string Status { get; init; } = string.Empty;
}

public sealed record BalanceResponse
{
    public long StudentId { get; init; }
    public decimal HoursRemaining { get; init; }
    public decimal UnappliedCredit { get; init; }
}

public sealed record PurchasePackageResponse
{
    public long PackageId { get; init; }
    public decimal HoursRemaining { get; init; }
}

public sealed record PaymentResponse
{
    public long PaymentId { get; init; }
    public decimal Amount { get; init; }
    public string Method { get; init; } = string.Empty;
    public DateTime PaidDate { get; init; }
    public long? PackageId { get; init; }
    public bool Applied { get; init; }
}

/// <summary>
/// The read model the parent status page and the Cosmos projection are built
/// from. One call, one consistent picture.
/// </summary>
public sealed record StudentDashboardResponse
{
    public long StudentId { get; init; }
    public string FullName { get; init; } = string.Empty;
    public string ParentContact { get; init; } = string.Empty;
    public string PreferredLanguage { get; init; } = "EN";
    public decimal HoursRemaining { get; init; }
    public decimal UnappliedCredit { get; init; }
    public int SessionsCompleted { get; init; }
    public IReadOnlyList<SessionResponse> UpcomingSessions { get; init; } = [];
    public IReadOnlyList<PaymentResponse> RecentPayments { get; init; } = [];
    public DateTime LastUpdatedUtc { get; init; } = DateTime.UtcNow;
}
