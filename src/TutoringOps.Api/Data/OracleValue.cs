using Oracle.ManagedDataAccess.Client;
using Oracle.ManagedDataAccess.Types;

namespace TutoringOps.Api.Data;

/// <summary>
/// ODP.NET hands back its own value types (OracleDecimal, OracleString) rather
/// than CLR primitives, and each has its own null representation. These helpers
/// keep that detail out of the repositories.
/// </summary>
public static class OracleValue
{
    public static string? String(OracleParameter parameter) => parameter.Value switch
    {
        null => null,
        OracleString s => s.IsNull ? null : s.Value,
        DBNull => null,
        var v => v.ToString()
    };

    public static long? Int64(OracleParameter parameter) => parameter.Value switch
    {
        null => null,
        OracleDecimal d => d.IsNull ? null : d.ToInt64(),
        DBNull => null,
        var v => Convert.ToInt64(v)
    };

    public static decimal? Decimal(OracleParameter parameter) => parameter.Value switch
    {
        null => null,
        OracleDecimal d => d.IsNull ? null : d.Value,
        DBNull => null,
        var v => Convert.ToDecimal(v)
    };

    // --- reader helpers -----------------------------------------------------

    public static string? GetNullableString(OracleDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
    }

    public static long? GetNullableInt64(OracleDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetInt64(ordinal);
    }

    public static long GetInt64(OracleDataReader reader, string column) =>
        reader.GetInt64(reader.GetOrdinal(column));

    public static decimal GetDecimal(OracleDataReader reader, string column) =>
        reader.GetDecimal(reader.GetOrdinal(column));

    public static int GetInt32(OracleDataReader reader, string column) =>
        reader.GetInt32(reader.GetOrdinal(column));

    public static string GetString(OracleDataReader reader, string column) =>
        reader.GetString(reader.GetOrdinal(column));

    public static DateTime GetDateTime(OracleDataReader reader, string column) =>
        reader.GetDateTime(reader.GetOrdinal(column));

    public static DateTime? GetNullableDateTime(OracleDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
    }
}
