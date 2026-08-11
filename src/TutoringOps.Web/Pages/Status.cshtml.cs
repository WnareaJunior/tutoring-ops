using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using TutoringOps.Web.Services;

namespace TutoringOps.Web.Pages;

/// <summary>
/// The page a parent opens instead of texting to ask how many hours are left.
///
/// Reads the Cosmos read model, not Oracle. That is the payoff of the one-way
/// flow: this page cannot change anything, cannot hold a database connection,
/// and keeps working when the tunnel to the Oracle box is down.
///
/// Access is a per-student code, kept in a session cookie. It is not an
/// identity system and does not pretend to be one -- the reasoning, and what it
/// would take to make it one, is in docs/design-decisions.md.
/// </summary>
public sealed class StatusModel : PageModel
{
    private const string SessionKey = "student-id";

    private readonly TutoringApiClient _api;
    private readonly IDashboardReader _reader;

    public StatusModel(TutoringApiClient api, IDashboardReader reader)
    {
        _api = api;
        _reader = reader;
    }

    [BindProperty] public string AccessCode { get; set; } = "";

    public StudentDashboard? Dashboard { get; private set; }
    public string DataSource => _reader.SourceName;
    public bool IsSpanish => Dashboard?.PreferredLanguage == "ES";

    [TempData] public string? ErrorMessage { get; set; }

    public async Task OnGetAsync(CancellationToken cancellationToken)
    {
        var studentId = HttpContext.Session.GetInt32(SessionKey);
        if (studentId is null)
        {
            return;
        }

        Dashboard = await _reader.GetAsync(studentId.Value, cancellationToken);

        if (Dashboard is null)
        {
            // The projection has not been written yet -- the student exists but
            // nothing has happened to them since the read model went live.
            // Fall back to the API so the parent sees something real.
            Dashboard = await _api.GetDashboardAsync(studentId.Value, cancellationToken);
        }
    }

    public async Task<IActionResult> OnPostAsync(CancellationToken cancellationToken)
    {
        var code = (AccessCode ?? string.Empty).Trim().ToUpperInvariant();

        if (string.IsNullOrWhiteSpace(code))
        {
            ErrorMessage = "Enter the code from your welcome message.";
            return RedirectToPage();
        }

        var dashboard = await _api.GetDashboardByCodeAsync(code, cancellationToken);
        if (dashboard is null)
        {
            ErrorMessage = "That code did not match an active student.";
            return RedirectToPage();
        }

        HttpContext.Session.SetInt32(SessionKey, (int)dashboard.StudentId);
        return RedirectToPage();
    }

    public IActionResult OnPostSignOut()
    {
        HttpContext.Session.Remove(SessionKey);
        return RedirectToPage();
    }
}
