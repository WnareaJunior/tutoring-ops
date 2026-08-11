using Microsoft.AspNetCore.Mvc;
using TutoringOps.Api.Data;

namespace TutoringOps.Api.Controllers;

/// <summary>
/// Turns a PL/SQL result code into an HTTP response. The raw code goes in the
/// problem-details title so a client can branch on the exact reason rather than
/// parsing prose, while the status code carries the same meaning to anything
/// that only speaks HTTP.
/// </summary>
[ApiController]
[Produces("application/json")]
public abstract class ApiControllerBase : ControllerBase
{
    protected ActionResult Failure(string resultCode) => Problem(
        title: resultCode,
        detail: ResultCode.ToMessage(resultCode),
        statusCode: ResultCode.ToStatusCode(resultCode));
}
