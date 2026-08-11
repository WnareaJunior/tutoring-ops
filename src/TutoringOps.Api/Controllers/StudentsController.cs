using Microsoft.AspNetCore.Mvc;
using TutoringOps.Api.Data;
using TutoringOps.Api.Models;

namespace TutoringOps.Api.Controllers;

[Route("students")]
public sealed class StudentsController : ApiControllerBase
{
    private readonly StudentRepository _students;

    public StudentsController(StudentRepository students) => _students = students;

    /// <summary>Adds a student and returns the parent's access code.</summary>
    [HttpPost]
    [ProducesResponseType(typeof(StudentResponse), StatusCodes.Status201Created)]
    [ProducesResponseType(StatusCodes.Status422UnprocessableEntity)]
    public async Task<ActionResult<StudentResponse>> Create(
        [FromBody] CreateStudentRequest request, CancellationToken cancellationToken)
    {
        var (result, studentId, _) = await _students.CreateAsync(
            request.FullName,
            request.ParentContact,
            request.ParentPhone,
            request.PreferredLanguage,
            cancellationToken);

        if (!ResultCode.IsOk(result) || studentId is null)
        {
            return Failure(result);
        }

        var (_, student) = await _students.GetAsync(studentId.Value, cancellationToken);
        return CreatedAtAction(nameof(Get), new { studentId = studentId.Value }, student);
    }

    [HttpGet("{studentId:long}")]
    [ProducesResponseType(typeof(StudentResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<StudentResponse>> Get(
        long studentId, CancellationToken cancellationToken)
    {
        var (result, student) = await _students.GetAsync(studentId, cancellationToken);
        return ResultCode.IsOk(result) && student is not null
            ? Ok(student)
            : Failure(result);
    }

    [HttpGet]
    [ProducesResponseType(typeof(IReadOnlyList<StudentSummaryResponse>), StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<StudentSummaryResponse>>> List(
        [FromQuery] bool activeOnly = true, CancellationToken cancellationToken = default) =>
        Ok(await _students.ListAsync(activeOnly, cancellationToken));

    /// <summary>Hours left across active packages, plus any unapplied cash.</summary>
    [HttpGet("{studentId:long}/balance")]
    [ProducesResponseType(typeof(BalanceResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<BalanceResponse>> GetBalance(
        long studentId, CancellationToken cancellationToken)
    {
        var (result, student) = await _students.GetAsync(studentId, cancellationToken);
        if (!ResultCode.IsOk(result) || student is null)
        {
            return Failure(result);
        }

        return Ok(new BalanceResponse
        {
            StudentId = student.StudentId,
            HoursRemaining = student.HoursRemaining,
            UnappliedCredit = student.UnappliedCredit
        });
    }

    /// <summary>
    /// The read model behind the parent status page. The billing Function App
    /// calls this and projects the result into Cosmos.
    /// </summary>
    [HttpGet("{studentId:long}/dashboard")]
    [ProducesResponseType(typeof(StudentDashboardResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<StudentDashboardResponse>> GetDashboard(
        long studentId, CancellationToken cancellationToken)
    {
        var (result, dashboard) = await _students.GetDashboardAsync(studentId, cancellationToken);
        return ResultCode.IsOk(result) && dashboard is not null
            ? Ok(dashboard)
            : Failure(result);
    }

    /// <summary>Exchanges a parent's access code for a student id.</summary>
    [HttpGet("by-code/{accessCode}")]
    [ProducesResponseType(typeof(StudentResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<StudentResponse>> GetByAccessCode(
        string accessCode, CancellationToken cancellationToken)
    {
        var (result, studentId) = await _students.ResolveAccessCodeAsync(
            accessCode, cancellationToken);

        if (!ResultCode.IsOk(result) || studentId is null)
        {
            return Failure(result);
        }

        var (_, student) = await _students.GetAsync(studentId.Value, cancellationToken);
        return Ok(student);
    }

    [HttpPost("{studentId:long}/deactivate")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> Deactivate(long studentId, CancellationToken cancellationToken)
    {
        var result = await _students.SetActiveAsync(studentId, false, cancellationToken);
        return ResultCode.IsOk(result) ? NoContent() : Failure(result);
    }

    [HttpPost("{studentId:long}/reactivate")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> Reactivate(long studentId, CancellationToken cancellationToken)
    {
        var result = await _students.SetActiveAsync(studentId, true, cancellationToken);
        return ResultCode.IsOk(result) ? NoContent() : Failure(result);
    }
}
