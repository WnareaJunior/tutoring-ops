namespace TutoringOps.Api.Data;

/// <summary>
/// The result codes PL/SQL hands back, and the HTTP status each one means.
///
/// This class is the entire translation layer between the database's vocabulary
/// and HTTP. There is deliberately no business logic here -- the API does not
/// decide when a booking conflicts, it only decides that a conflict is a 409.
/// </summary>
public static class ResultCode
{
    public const string Ok = "OK";
    public const string InvalidInput = "ERR_INVALID_INPUT";
    public const string StudentNotFound = "ERR_STUDENT_NOT_FOUND";
    public const string StudentInactive = "ERR_STUDENT_INACTIVE";
    public const string SessionNotFound = "ERR_SESSION_NOT_FOUND";
    public const string PackageNotFound = "ERR_PACKAGE_NOT_FOUND";
    public const string PaymentNotFound = "ERR_PAYMENT_NOT_FOUND";
    public const string DoubleBooked = "ERR_DOUBLE_BOOKED";
    public const string OutsideBusinessHours = "ERR_OUTSIDE_BUSINESS_HOURS";
    public const string InsufficientHours = "ERR_INSUFFICIENT_HOURS";
    public const string InvalidTransition = "ERR_INVALID_TRANSITION";
    public const string InvalidDuration = "ERR_INVALID_DURATION";
    public const string StartInPast = "ERR_START_IN_PAST";

    public static bool IsOk(string? code) =>
        string.Equals(code, Ok, StringComparison.Ordinal);

    /// <summary>
    /// 404 for things that are not there, 409 for a conflict with the current
    /// state of the calendar, 402 when the answer is "pay first", and 422 for a
    /// request that is well-formed but breaks a business rule.
    /// </summary>
    public static int ToStatusCode(string? code) => code switch
    {
        Ok => StatusCodes.Status200OK,

        StudentNotFound or SessionNotFound or PackageNotFound or PaymentNotFound
            => StatusCodes.Status404NotFound,

        // The slot is taken, or the session has already moved on to a state
        // this operation cannot act on. Both are conflicts with current state.
        DoubleBooked or InvalidTransition
            => StatusCodes.Status409Conflict,

        // Nothing is wrong with the request; the student simply has no hours
        // and no unapplied credit.
        InsufficientHours
            => StatusCodes.Status402PaymentRequired,

        StudentInactive or OutsideBusinessHours or InvalidDuration
            or StartInPast or InvalidInput
            => StatusCodes.Status422UnprocessableEntity,

        _ => StatusCodes.Status500InternalServerError
    };

    /// <summary>Human-readable explanation for the problem-details body.</summary>
    public static string ToMessage(string? code) => code switch
    {
        Ok => "Success.",
        StudentNotFound => "No student with that id.",
        StudentInactive => "That student is no longer active.",
        SessionNotFound => "No session with that id.",
        PackageNotFound => "No package with that id.",
        PaymentNotFound => "No payment with that id.",
        DoubleBooked => "The tutor already has a session overlapping that time.",
        OutsideBusinessHours => "That time is outside business hours.",
        InsufficientHours => "The student has no remaining hours and no unapplied payment.",
        InvalidTransition => "That session cannot move to the requested state.",
        InvalidDuration => "Duration must be 30-300 minutes, in 15 minute steps.",
        StartInPast => "Sessions cannot be booked in the past.",
        InvalidInput => "One or more values were missing or invalid.",
        _ => $"Unexpected result from the database: {code}"
    };
}
