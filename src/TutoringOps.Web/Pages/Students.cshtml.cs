using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using TutoringOps.Web.Services;

namespace TutoringOps.Web.Pages;

/// <summary>The roster and its balances, plus the two writes that change them.</summary>
public sealed class StudentsModel : AdminPageModel
{
    private readonly TutoringApiClient _api;

    public StudentsModel(TutoringApiClient api) => _api = api;

    public IReadOnlyList<StudentSummary> Students { get; private set; } = [];

    [BindProperty] public NewStudentInput NewStudent { get; set; } = new();
    [BindProperty] public PackageInput Package { get; set; } = new();

    [TempData] public string? SuccessMessage { get; set; }
    [TempData] public string? ErrorMessage { get; set; }
    [TempData] public string? ErrorCode { get; set; }

    public async Task OnGetAsync(CancellationToken cancellationToken) =>
        await LoadAsync(cancellationToken);

    public async Task<IActionResult> OnPostAddStudentAsync(CancellationToken cancellationToken)
    {
        var problem = await _api.CreateStudentAsync(
            NewStudent.FullName,
            NewStudent.ParentContact,
            NewStudent.ParentPhone,
            NewStudent.PreferredLanguage,
            cancellationToken);

        if (problem is null)
        {
            SuccessMessage = $"Added {NewStudent.FullName}. " +
                             "Their access code is on the student row below.";
        }
        else
        {
            ErrorMessage = problem.Detail;
            ErrorCode = problem.Code;
        }

        return RedirectToPage();
    }

    public async Task<IActionResult> OnPostSellPackageAsync(CancellationToken cancellationToken)
    {
        if (Package.StudentId <= 0 || Package.Hours <= 0)
        {
            ErrorMessage = "Pick a student and a number of hours.";
            return RedirectToPage();
        }

        var problem = await _api.PurchasePackageAsync(
            Package.StudentId, Package.Hours, Package.Amount, Package.Method, cancellationToken);

        if (problem is null)
        {
            SuccessMessage = $"Added {Package.Hours:0.##} hours.";
        }
        else
        {
            ErrorMessage = problem.Detail;
            ErrorCode = problem.Code;
        }

        return RedirectToPage();
    }

    private async Task LoadAsync(CancellationToken cancellationToken)
    {
        try
        {
            Students = await _api.GetStudentsAsync(activeOnly: false, cancellationToken);
        }
        catch (HttpRequestException)
        {
            ErrorMessage = "The API is not reachable. Is it running, and can it see Oracle?";
        }
    }

    public sealed class NewStudentInput
    {
        public string FullName { get; set; } = "";
        public string ParentContact { get; set; } = "";
        public string? ParentPhone { get; set; }
        public string PreferredLanguage { get; set; } = "EN";
    }

    public sealed class PackageInput
    {
        public long StudentId { get; set; }
        public decimal Hours { get; set; } = 10;
        public decimal Amount { get; set; } = 600;
        public string Method { get; set; } = "ZELLE";
    }
}
