using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Oracle.ManagedDataAccess.Client;
using TutoringOps.Api.Outbox;
using Xunit;

namespace TutoringOps.Api.Tests;

/// <summary>
/// These are integration tests, not unit tests, and that is the point: the
/// behaviour under test lives in PL/SQL, so a mocked data layer would test
/// nothing worth testing. They run against the Docker Oracle from
/// db/docker-compose.yml.
///
/// When Oracle is not reachable the tests skip rather than fail, so a clone of
/// this repo with no database still gives a green build.
/// </summary>
public sealed class ApiFactory : WebApplicationFactory<Program>
{
    public const string ConnectionString =
        "User Id=tutoring;Password=TutorPw1;Data Source=localhost:1521/XEPDB1;" +
        "Pooling=true;Min Pool Size=1;Max Pool Size=10;Connection Timeout=5;";

    private static readonly Lazy<bool> Reachable = new(() =>
    {
        try
        {
            using var connection = new OracleConnection(ConnectionString);
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT 1 FROM DUAL";
            command.ExecuteScalar();
            return true;
        }
        catch
        {
            return false;
        }
    });

    public static bool OracleIsAvailable => Reachable.Value;

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseSetting("Oracle:ConnectionString", ConnectionString);
        builder.UseSetting("ServiceBus:ConnectionString", string.Empty);
        // The publisher would otherwise drain the outbox mid-test and make the
        // "an event was written" assertions racy.
        builder.UseSetting("Outbox:Enabled", "false");
        builder.UseSetting("Ops:ApiKey", "test-key");

        builder.ConfigureServices(services =>
        {
            // Guard against a future change quietly re-enabling the publisher.
            var hosted = services.FirstOrDefault(d =>
                d.ImplementationType == typeof(OutboxPublisherService));
            if (hosted is not null)
            {
                services.Remove(hosted);
            }
        });
    }
}

/// <summary>A Fact that skips itself when the Docker Oracle is not running.</summary>
public sealed class OracleFactAttribute : FactAttribute
{
    public OracleFactAttribute()
    {
        if (!ApiFactory.OracleIsAvailable)
        {
            Skip = "Oracle is not reachable on localhost:1521. Run: cd db && docker compose up -d && ./install.sh";
        }
    }
}

[CollectionDefinition("oracle")]
public sealed class OracleCollection : ICollectionFixture<ApiFactory>;
