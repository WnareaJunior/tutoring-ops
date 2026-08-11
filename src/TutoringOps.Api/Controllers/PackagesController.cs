using Microsoft.AspNetCore.Mvc;
using TutoringOps.Api.Data;
using TutoringOps.Api.Models;

namespace TutoringOps.Api.Controllers;

[Route("packages")]
public sealed class PackagesController : ApiControllerBase
{
    private readonly BillingRepository _billing;
    private readonly StudentRepository _students;

    public PackagesController(BillingRepository billing, StudentRepository students)
    {
        _billing = billing;
        _students = students;
    }

    /// <summary>Buys a block of hours and records the payment behind it.</summary>
    [HttpPost]
    [ProducesResponseType(typeof(PurchasePackageResponse), StatusCodes.Status201Created)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status422UnprocessableEntity)]
    public async Task<ActionResult<PurchasePackageResponse>> Purchase(
        [FromBody] PurchasePackageRequest request, CancellationToken cancellationToken)
    {
        var (result, packageId) = await _billing.PurchasePackageAsync(
            request.StudentId,
            request.Hours,
            request.Amount,
            request.Method,
            request.ExpiresOn,
            cancellationToken);

        if (!ResultCode.IsOk(result) || packageId is null)
        {
            return Failure(result);
        }

        var (_, student) = await _students.GetAsync(request.StudentId, cancellationToken);

        return Created($"/packages/{packageId.Value}", new PurchasePackageResponse
        {
            PackageId = packageId.Value,
            HoursRemaining = student?.HoursRemaining ?? 0m
        });
    }
}

[Route("payments")]
public sealed class PaymentsController : ApiControllerBase
{
    private readonly BillingRepository _billing;

    public PaymentsController(BillingRepository billing) => _billing = billing;

    /// <summary>
    /// Money in from a pay-per-session student. Sits unapplied until a booking
    /// claims it, which is what lets those students book without a package.
    /// </summary>
    [HttpPost]
    [ProducesResponseType(typeof(PaymentResponse), StatusCodes.Status201Created)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status422UnprocessableEntity)]
    public async Task<ActionResult<PaymentResponse>> Record(
        [FromBody] RecordPaymentRequest request, CancellationToken cancellationToken)
    {
        var (result, paymentId) = await _billing.RecordPaymentAsync(
            request.StudentId,
            request.Amount,
            request.Method,
            request.Notes,
            cancellationToken);

        if (!ResultCode.IsOk(result) || paymentId is null)
        {
            return Failure(result);
        }

        return Created($"/payments/{paymentId.Value}", new PaymentResponse
        {
            PaymentId = paymentId.Value,
            Amount = request.Amount,
            Method = request.Method,
            PaidDate = DateTime.Now,
            Applied = false
        });
    }
}
