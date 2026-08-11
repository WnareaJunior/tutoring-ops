using Microsoft.AspNetCore.Mvc;
using TutoringOps.Api.Data;
using TutoringOps.Api.Models;

namespace TutoringOps.Api.Controllers;

[Route("sessions")]
public sealed class SessionsController : ApiControllerBase
{
    private readonly SchedulingRepository _scheduling;

    public SessionsController(SchedulingRepository scheduling) => _scheduling = scheduling;

    /// <summary>
    /// Books a session. The interesting responses are the failures:
    /// 409 when the slot is taken, 402 when the student has nothing to pay with,
    /// 422 when the time is outside business hours.
    /// </summary>
    [HttpPost]
    [ProducesResponseType(typeof(SessionResponse), StatusCodes.Status201Created)]
    [ProducesResponseType(StatusCodes.Status402PaymentRequired)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    [ProducesResponseType(StatusCodes.Status422UnprocessableEntity)]
    public async Task<ActionResult<SessionResponse>> Book(
        [FromBody] BookSessionRequest request, CancellationToken cancellationToken)
    {
        var (result, sessionId) = await _scheduling.BookAsync(
            request.StudentId,
            request.StartTime,
            request.DurationMinutes,
            request.Notes,
            request.AsRequest,
            cancellationToken);

        if (!ResultCode.IsOk(result) || sessionId is null)
        {
            return Failure(result);
        }

        var (_, session) = await _scheduling.GetAsync(sessionId.Value, cancellationToken);
        return CreatedAtAction(nameof(Get), new { sessionId = sessionId.Value }, session);
    }

    [HttpGet("{sessionId:long}")]
    [ProducesResponseType(typeof(SessionResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<SessionResponse>> Get(
        long sessionId, CancellationToken cancellationToken)
    {
        var (result, session) = await _scheduling.GetAsync(sessionId, cancellationToken);
        return ResultCode.IsOk(result) && session is not null
            ? Ok(session)
            : Failure(result);
    }

    /// <summary>
    /// Every session in a date range, for the admin week calendar. Defaults to
    /// the coming seven days.
    /// </summary>
    [HttpGet]
    [ProducesResponseType(typeof(IReadOnlyList<SessionResponse>), StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<SessionResponse>>> GetSchedule(
        [FromQuery] DateTime? from,
        [FromQuery] DateTime? to,
        CancellationToken cancellationToken)
    {
        var fromDate = from ?? DateTime.Today;
        var toDate = to ?? fromDate.AddDays(6);

        if (toDate < fromDate)
        {
            return Failure(ResultCode.InvalidInput);
        }

        return Ok(await _scheduling.GetScheduleAsync(fromDate, toDate, cancellationToken));
    }

    /// <summary>
    /// Cancels a session. Whether the hours come back is the database's
    /// decision, not this endpoint's: inside 24 hours they are forfeited and
    /// the session becomes LATE_CANCELLED.
    /// </summary>
    [HttpDelete("{sessionId:long}")]
    [ProducesResponseType(typeof(SessionResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SessionResponse>> Cancel(
        long sessionId, CancellationToken cancellationToken)
    {
        var result = await _scheduling.CancelAsync(sessionId, cancellationToken);
        if (!ResultCode.IsOk(result))
        {
            return Failure(result);
        }

        // Return the session so the caller can see which of the two
        // cancellation outcomes it got without asking again.
        var (_, session) = await _scheduling.GetAsync(sessionId, cancellationToken);
        return Ok(session);
    }

    [HttpPost("{sessionId:long}/confirm")]
    [ProducesResponseType(typeof(SessionResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SessionResponse>> Confirm(
        long sessionId, CancellationToken cancellationToken)
    {
        var result = await _scheduling.ConfirmAsync(sessionId, cancellationToken);
        if (!ResultCode.IsOk(result))
        {
            return Failure(result);
        }

        var (_, session) = await _scheduling.GetAsync(sessionId, cancellationToken);
        return Ok(session);
    }

    [HttpPost("{sessionId:long}/complete")]
    [ProducesResponseType(typeof(SessionResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<SessionResponse>> Complete(
        long sessionId, CancellationToken cancellationToken)
    {
        var result = await _scheduling.CompleteAsync(sessionId, cancellationToken);
        if (!ResultCode.IsOk(result))
        {
            return Failure(result);
        }

        var (_, session) = await _scheduling.GetAsync(sessionId, cancellationToken);
        return Ok(session);
    }
}
