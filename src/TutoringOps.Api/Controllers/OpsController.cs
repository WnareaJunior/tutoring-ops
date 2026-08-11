using Microsoft.AspNetCore.Mvc;
using TutoringOps.Api.Data;
using TutoringOps.Api.Outbox;

namespace TutoringOps.Api.Controllers;

/// <summary>
/// Operational endpoints called by the Function App rather than by a person.
///
/// Guarded by a shared key in the X-Ops-Key header. That is not an identity
/// system and is not pretending to be one -- it is one secret shared between
/// two services I own, which is the right size of solution for the problem.
/// </summary>
[Route("ops")]
public sealed class OpsController : ApiControllerBase
{
    private const string ApiKeyHeader = "X-Ops-Key";

    private readonly SchedulingRepository _scheduling;
    private readonly OutboxRepository _outbox;
    private readonly IConfiguration _configuration;
    private readonly ILogger<OpsController> _logger;

    public OpsController(
        SchedulingRepository scheduling,
        OutboxRepository outbox,
        IConfiguration configuration,
        ILogger<OpsController> logger)
    {
        _scheduling = scheduling;
        _outbox = outbox;
        _configuration = configuration;
        _logger = logger;
    }

    /// <summary>
    /// Queues reminder events for sessions starting soon. Called nightly by the
    /// timer-triggered function. Idempotent: PL/SQL will not queue a second
    /// reminder for a session that already has one.
    /// </summary>
    [HttpPost("reminders")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status401Unauthorized)]
    public async Task<ActionResult> QueueReminders(
        [FromQuery] int hoursAhead = 24, CancellationToken cancellationToken = default)
    {
        if (!IsAuthorised())
        {
            return Unauthorized();
        }

        var queued = await _scheduling.QueueDueRemindersAsync(hoursAhead, cancellationToken);
        _logger.LogInformation("Queued {Count} reminder(s) for the next {Hours}h.",
            queued, hoursAhead);

        return Ok(new { queued, hoursAhead });
    }

    /// <summary>How many events are still waiting to reach Service Bus.</summary>
    [HttpGet("outbox")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status401Unauthorized)]
    public async Task<ActionResult> OutboxStatus(CancellationToken cancellationToken)
    {
        if (!IsAuthorised())
        {
            return Unauthorized();
        }

        return Ok(new { pending = await _outbox.PendingCountAsync(cancellationToken) });
    }

    private bool IsAuthorised()
    {
        var expected = _configuration["Ops:ApiKey"];

        // No key configured means local development. Refusing to run without
        // one would make the stack harder to try than it needs to be, but an
        // unset key in a deployed environment is worth a loud log line.
        if (string.IsNullOrWhiteSpace(expected))
        {
            _logger.LogWarning("Ops:ApiKey is not configured; /ops endpoints are unprotected.");
            return true;
        }

        return Request.Headers.TryGetValue(ApiKeyHeader, out var provided)
            && string.Equals(provided.ToString(), expected, StringComparison.Ordinal);
    }
}
