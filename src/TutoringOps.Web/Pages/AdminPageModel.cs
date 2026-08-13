using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace TutoringOps.Web.Pages;

/// <summary>
/// Base for pages that show student data or change the schedule. The same
/// shape as the parent gate: one shared passcode held in a session cookie,
/// not an identity system. With no Admin:Passcode configured -- a laptop --
/// the pages stay open, matching how every other secret in this project
/// behaves when absent.
/// </summary>
public abstract class AdminPageModel : PageModel
{
    internal const string SessionKey = "IsAdmin";

    public override void OnPageHandlerExecuting(PageHandlerExecutingContext context)
    {
        var configuration = context.HttpContext.RequestServices
            .GetRequiredService<IConfiguration>();
        var passcode = configuration["Admin:Passcode"];

        if (!string.IsNullOrWhiteSpace(passcode) &&
            context.HttpContext.Session.GetString(SessionKey) != "Y")
        {
            var request = context.HttpContext.Request;
            context.Result = RedirectToPage("/AdminLogin",
                new { returnUrl = request.Path + request.QueryString });
        }
    }
}
