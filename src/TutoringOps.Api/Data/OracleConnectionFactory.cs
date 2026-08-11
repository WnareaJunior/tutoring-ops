using System.Data;
using Microsoft.Extensions.Options;
using Oracle.ManagedDataAccess.Client;
using TutoringOps.Api.Configuration;

namespace TutoringOps.Api.Data;

public interface IOracleConnectionFactory
{
    /// <summary>Opens a new connection. Callers own disposal.</summary>
    Task<OracleConnection> OpenAsync(CancellationToken cancellationToken = default);

    int CommandTimeoutSeconds { get; }
}

public sealed class OracleConnectionFactory : IOracleConnectionFactory
{
    private readonly OracleOptions _options;

    public OracleConnectionFactory(IOptions<OracleOptions> options)
    {
        _options = options.Value;

        if (string.IsNullOrWhiteSpace(_options.ConnectionString))
        {
            throw new InvalidOperationException(
                "Oracle:ConnectionString is not configured. Set it in user secrets " +
                "locally or in the Web App's configuration when deployed.");
        }
    }

    public int CommandTimeoutSeconds => _options.CommandTimeoutSeconds;

    public async Task<OracleConnection> OpenAsync(CancellationToken cancellationToken = default)
    {
        var connection = new OracleConnection(_options.ConnectionString);
        try
        {
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }
}

/// <summary>
/// Keeps the repositories readable. Every call into the database is a stored
/// procedure with named parameters, so these wrap the ceremony that comes with
/// that and nothing else.
/// </summary>
public static class OracleCommandExtensions
{
    public static OracleCommand CreateProcedureCommand(
        this OracleConnection connection, string procedureName, int timeoutSeconds)
    {
        var command = connection.CreateCommand();
        command.CommandText = procedureName;
        command.CommandType = CommandType.StoredProcedure;
        command.CommandTimeout = timeoutSeconds;
        // Essential: the packages use default parameter values, and positional
        // binding would silently shift arguments when one is omitted.
        command.BindByName = true;
        return command;
    }

    public static OracleParameter AddIn(
        this OracleCommand command, string name, OracleDbType type, object? value)
    {
        var parameter = command.Parameters.Add(name, type);
        parameter.Direction = ParameterDirection.Input;
        parameter.Value = value ?? DBNull.Value;
        return parameter;
    }

    public static OracleParameter AddOutNumber(this OracleCommand command, string name)
    {
        var parameter = command.Parameters.Add(name, OracleDbType.Decimal);
        parameter.Direction = ParameterDirection.Output;
        return parameter;
    }

    /// <summary>
    /// Output VARCHAR2 parameters must declare a size up front; ODP.NET has no
    /// way to discover it and throws at execute time if it is missing.
    /// </summary>
    public static OracleParameter AddOutVarchar(
        this OracleCommand command, string name, int size = 400)
    {
        var parameter = command.Parameters.Add(name, OracleDbType.Varchar2, size);
        parameter.Direction = ParameterDirection.Output;
        return parameter;
    }

    public static OracleParameter AddOutRefCursor(this OracleCommand command, string name)
    {
        var parameter = command.Parameters.Add(name, OracleDbType.RefCursor);
        parameter.Direction = ParameterDirection.Output;
        return parameter;
    }
}
