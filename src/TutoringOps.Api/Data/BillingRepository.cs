using Oracle.ManagedDataAccess.Client;

namespace TutoringOps.Api.Data;

/// <summary>Thin shell over PKG_BILLING. Same discipline as SchedulingRepository.</summary>
public sealed class BillingRepository
{
    private readonly IOracleConnectionFactory _factory;

    public BillingRepository(IOracleConnectionFactory factory) => _factory = factory;

    public async Task<(string Result, long? PackageId)> PurchasePackageAsync(
        long studentId,
        decimal hours,
        decimal amount,
        string method,
        DateOnly? expiresOn,
        CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateProcedureCommand(
            "PKG_BILLING.PURCHASE_PACKAGE", _factory.CommandTimeoutSeconds);

        command.AddIn("p_student_id", OracleDbType.Int64, studentId);
        command.AddIn("p_hours", OracleDbType.Decimal, hours);
        command.AddIn("p_amount", OracleDbType.Decimal, amount);
        command.AddIn("p_method", OracleDbType.Varchar2, method);
        command.AddIn("p_expires_on", OracleDbType.Date,
            expiresOn?.ToDateTime(TimeOnly.MinValue));
        var packageIdParam = command.AddOutNumber("p_package_id");
        var resultParam = command.AddOutVarchar("p_result", 40);

        await command.ExecuteNonQueryAsync(cancellationToken);

        var result = OracleValue.String(resultParam) ?? "ERR_UNKNOWN";
        if (ResultCode.IsOk(result))
        {
            transaction.Commit();
        }
        else
        {
            transaction.Rollback();
        }

        return (result, OracleValue.Int64(packageIdParam));
    }

    public async Task<(string Result, long? PaymentId)> RecordPaymentAsync(
        long studentId,
        decimal amount,
        string method,
        string? notes,
        CancellationToken cancellationToken)
    {
        await using var connection = await _factory.OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateProcedureCommand(
            "PKG_BILLING.RECORD_PAYMENT", _factory.CommandTimeoutSeconds);

        command.AddIn("p_student_id", OracleDbType.Int64, studentId);
        command.AddIn("p_amount", OracleDbType.Decimal, amount);
        command.AddIn("p_method", OracleDbType.Varchar2, method);
        command.AddIn("p_notes", OracleDbType.Varchar2, notes);
        var paymentIdParam = command.AddOutNumber("p_payment_id");
        var resultParam = command.AddOutVarchar("p_result", 40);

        await command.ExecuteNonQueryAsync(cancellationToken);

        var result = OracleValue.String(resultParam) ?? "ERR_UNKNOWN";
        if (ResultCode.IsOk(result))
        {
            transaction.Commit();
        }
        else
        {
            transaction.Rollback();
        }

        return (result, OracleValue.Int64(paymentIdParam));
    }
}
