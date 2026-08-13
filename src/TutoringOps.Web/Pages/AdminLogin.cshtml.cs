using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace TutoringOps.Web.Pages;

public sealed class AdminLoginModel : PageModel
{
    private readonly IConfiguration _configuration;
    private readonly ILogger<AdminLoginModel> _logger;

    public AdminLoginModel(IConfiguration configuration, ILogger<AdminLoginModel> logger)
    {
        _configuration = configuration;
        _logger = logger;
    }

    [BindProperty]
    public string? Passcode { get; set; }

    [BindProperty(SupportsGet = true)]
    public string? ReturnUrl { get; set; }

    public string? ErrorMessage { get; private set; }

    public IActionResult OnGet()
    {
        // Nothing configured means nothing to guard -- a laptop.
        if (string.IsNullOrWhiteSpace(_configuration["Admin:Passcode"]))
        {
            return RedirectToPage("/Schedule");
        }

        return Page();
    }

    public IActionResult OnPost()
    {
        var expected = _configuration["Admin:Passcode"];

        if (!string.IsNullOrWhiteSpace(expected) &&
            string.Equals(Passcode?.Trim(), expected, StringComparison.Ordinal))
        {
            HttpContext.Session.SetString(AdminPageModel.SessionKey, "Y");

            // Only ever bounce within this site; a pasted absolute URL is not
            // somewhere a login form should send anyone.
            var target = (ReturnUrl is not null && ReturnUrl.StartsWith('/'))
                ? ReturnUrl
                : "/Schedule";
            return Redirect(target);
        }

        _logger.LogWarning("Failed admin sign-in attempt.");
        ErrorMessage = "That passcode is not right.";
        return Page();
    }
}
