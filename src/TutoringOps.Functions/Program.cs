using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using TutoringOps.Functions.Services;

// There are no HTTP triggers here -- everything is driven by Service Bus or the
// timer -- so the worker defaults are all this host needs.
var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices((context, services) =>
    {
        var configuration = context.Configuration;

        // Application Insights is optional; without a connection string the
        // registration is inert.
        services.AddApplicationInsightsTelemetryWorkerService();
        services.ConfigureFunctionsApplicationInsights();

        // --- the API client -------------------------------------------------
        // Every read of Oracle goes through the API, carrying the shared ops
        // key the timer function needs.
        services.AddHttpClient<TutoringApiClient>(client =>
        {
            var baseUrl = configuration["TutoringApiBaseUrl"]
                ?? throw new InvalidOperationException(
                    "TutoringApiBaseUrl is not configured. Point it at the API, " +
                    "e.g. http://localhost:5080/ locally.");

            // The trailing slash matters: relative paths resolve against it.
            client.BaseAddress = new Uri(baseUrl.EndsWith('/') ? baseUrl : baseUrl + "/");
            client.Timeout = TimeSpan.FromSeconds(30);

            var opsKey = configuration["TutoringApiOpsKey"];
            if (!string.IsNullOrWhiteSpace(opsKey))
            {
                client.DefaultRequestHeaders.Add("X-Ops-Key", opsKey);
            }
        });

        // --- email ----------------------------------------------------------
        services.AddSingleton<IEmailSender>(sp =>
        {
            var apiKey = configuration["SendGridApiKey"];
            var from = configuration["SendGridFromAddress"];

            if (string.IsNullOrWhiteSpace(apiKey) || string.IsNullOrWhiteSpace(from))
            {
                // No key, no send. The trigger, the template choice and the
                // language selection are all still exercised; the mail just
                // ends up in the log instead of a family's inbox.
                return new LoggingEmailSender(
                    sp.GetRequiredService<ILogger<LoggingEmailSender>>());
            }

            return new SendGridEmailSender(
                apiKey,
                from,
                configuration["SendGridFromName"] ?? "SAT Tutoring",
                sp.GetRequiredService<ILogger<SendGridEmailSender>>());
        });

        // --- Cosmos read model ----------------------------------------------
        services.AddSingleton<IReadModelStore>(sp =>
        {
            var connectionString = configuration["CosmosConnectionString"];

            if (string.IsNullOrWhiteSpace(connectionString))
            {
                return new LoggingReadModelStore(
                    sp.GetRequiredService<ILogger<LoggingReadModelStore>>());
            }

            return new CosmosReadModelStore(
                connectionString,
                configuration["CosmosDatabaseName"] ?? "tutoring",
                configuration["CosmosContainerName"] ?? "student-dashboards",
                sp.GetRequiredService<ILogger<CosmosReadModelStore>>());
        });
    })
    .Build();

host.Run();
