using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using TutoringOps.Web.Services;

namespace TutoringOps.Web.Pages;

/// <summary>
/// The tutor's week: what is booked, and the two things done most often --
/// booking a lesson and cancelling one.
///
/// Every refusal shown on this page comes from PL/SQL. The page has no idea
/// what a double booking is; it just prints what the database said.
/// </summary>
public sealed class ScheduleModel : PageModel
{
    private readonly TutoringApiClient _api;
    private readonly ILogger<ScheduleModel> _logger;

    public ScheduleModel(TutoringApiClient api, ILogger<ScheduleModel> logger)
    {
        _api = api;
        _logger = logger;
    }

    /// <summary>Any date in the week being shown; defaults to this week.</summary>
    [BindProperty(SupportsGet = true)]
    public DateOnly? Week { get; set; }

    [BindProperty]
    public BookingInput Booking { get; set; } = new();

    public DateOnly WeekStart { get; private set; }
    public DateOnly WeekEnd { get; private set; }
    public IReadOnlyList<SessionView> Sessions { get; private set; } = [];
    public IReadOnlyList<StudentSummary> Students { get; private set; } = [];

    [TempData] public string? SuccessMessage { get; set; }
    [TempData] public string? ErrorMessage { get; set; }
    [TempData] public string? ErrorCode { get; set; }

    /// <summary>Working days, Monday to Saturday. Sunday is closed.</summary>
    public IEnumerable<DateOnly> Days =>
        Enumerable.Range(0, 6).Select(offset => WeekStart.AddDays(offset));

    /// <summary>Start-of-hour rows, matching PKG_VALIDATION's opening hours.</summary>
    public IEnumerable<int> Hours => Enumerable.Range(8, 13);

    public IEnumerable<SessionView> SessionsAt(DateOnly day, int hour) =>
        Sessions.Where(s =>
            DateOnly.FromDateTime(s.StartTime) == day &&
            s.StartTime.Hour == hour &&
            s.Status is "REQUESTED" or "CONFIRMED" or "COMPLETED");

    public async Task OnGetAsync(CancellationToken cancellationToken)
    {
        await LoadAsync(cancellationToken);
    }

    public async Task<IActionResult> OnPostBookAsync(CancellationToken cancellationToken)
    {
        if (Booking.StudentId <= 0 || Booking.Date is null)
        {
            ErrorMessage = "Pick a student and a date.";
            return RedirectToPage(new { week = Week?.ToString("yyyy-MM-dd") });
        }

        var startTime = Booking.Date.Value.ToDateTime(
            new TimeOnly(Booking.Hour, Booking.Minute));

        var problem = await _api.BookAsync(
            Booking.StudentId, startTime, Booking.DurationMinutes,
            Booking.Notes, cancellationToken);

        if (problem is null)
        {
            SuccessMessage = $"Booked {startTime:ddd d MMM HH:mm}.";
        }
        else
        {
            ErrorMessage = problem.Detail;
            ErrorCode = problem.Code;
            _logger.LogInformation("Booking refused: {Code}", problem.Code);
        }

        // Land on the week the booking was for, not the week the form was on.
        return RedirectToPage(new { week = Booking.Date.Value.ToString("yyyy-MM-dd") });
    }

    public async Task<IActionResult> OnPostCancelAsync(
        long sessionId, CancellationToken cancellationToken)
    {
        var problem = await _api.CancelAsync(sessionId, cancellationToken);

        if (problem is null)
        {
            // Whether the hours came back depends on the 24 hour rule, and that
            // is the database's call -- so say so rather than guessing here.
            SuccessMessage = "Cancelled. Hours were returned unless it was inside 24 hours.";
        }
        else
        {
            ErrorMessage = problem.Detail;
            ErrorCode = problem.Code;
        }

        return RedirectToPage(new { week = Week?.ToString("yyyy-MM-dd") });
    }

    public async Task<IActionResult> OnPostCompleteAsync(
        long sessionId, CancellationToken cancellationToken)
    {
        var problem = await _api.CompleteAsync(sessionId, cancellationToken);

        if (problem is null)
        {
            SuccessMessage = "Marked complete.";
        }
        else
        {
            ErrorMessage = problem.Detail;
            ErrorCode = problem.Code;
        }

        return RedirectToPage(new { week = Week?.ToString("yyyy-MM-dd") });
    }

    public async Task<IActionResult> OnPostConfirmAsync(
        long sessionId, CancellationToken cancellationToken)
    {
        var problem = await _api.ConfirmAsync(sessionId, cancellationToken);

        if (problem is null)
        {
            SuccessMessage = "Confirmed.";
        }
        else
        {
            ErrorMessage = problem.Detail;
            ErrorCode = problem.Code;
        }

        return RedirectToPage(new { week = Week?.ToString("yyyy-MM-dd") });
    }

    private async Task LoadAsync(CancellationToken cancellationToken)
    {
        var anchor = Week ?? DateOnly.FromDateTime(DateTime.Today);

        // Monday of the anchor's week. DayOfWeek puts Sunday at 0, so shift it
        // to 7 before subtracting.
        var dayNumber = (int)anchor.ToDateTime(TimeOnly.MinValue).DayOfWeek;
        var mondayOffset = dayNumber == 0 ? 6 : dayNumber - 1;

        WeekStart = anchor.AddDays(-mondayOffset);
        WeekEnd = WeekStart.AddDays(5);

        try
        {
            Sessions = await _api.GetScheduleAsync(WeekStart, WeekEnd, cancellationToken);
            Students = await _api.GetStudentsAsync(activeOnly: true, cancellationToken);
        }
        catch (HttpRequestException ex)
        {
            // The API being down is the single most likely local failure, and a
            // stack trace helps nobody -- say which thing is unreachable.
            _logger.LogError(ex, "Could not reach the API.");
            ErrorMessage = "The API is not reachable. Is it running, and can it see Oracle?";
        }
    }

    public sealed class BookingInput
    {
        public long StudentId { get; set; }
        public DateOnly? Date { get; set; }
        public int Hour { get; set; } = 16;
        public int Minute { get; set; }
        public int DurationMinutes { get; set; } = 60;
        public string? Notes { get; set; }
    }
}
