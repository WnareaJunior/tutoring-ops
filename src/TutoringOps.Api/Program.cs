using Microsoft.AspNetCore.Diagnostics;
using Microsoft.Extensions.Options;
using Oracle.ManagedDataAccess.Client;
using TutoringOps.Api.Configuration;
using TutoringOps.Api.Data;
using TutoringOps.Api.Outbox;

var builder = WebApplication.CreateBuilder(args);

// --- configuration ----------------------------------------------------------
builder.Services.Configure<OracleOptions>(
    builder.Configuration.GetSection(OracleOptions.SectionName));
builder.Services.Configure<ServiceBusOptions>(
    builder.Configuration.GetSection(ServiceBusOptions.SectionName));
builder.Services.Configure<OutboxOptions>(
    builder.Configuration.GetSection(OutboxOptions.SectionName));
builder.Services.Configure<EventGridOptions>(
    builder.Configuration.GetSection(EventGridOptions.SectionName));

// Azure App Service surfaces connection strings as CUSTOMCONNSTR_*, which the
// configuration provider exposes under ConnectionStrings. Prefer that when it
// is set so the deployed app needs no Oracle section at all.
var azureOracle = builder.Configuration.GetConnectionString("Oracle");
if (!string.IsNullOrWhiteSpace(azureOracle))
{
    builder.Services.PostConfigure<OracleOptions>(o => o.ConnectionString = azureOracle);
}

var azureServiceBus = builder.Configuration.GetConnectionString("ServiceBus");
if (!string.IsNullOrWhiteSpace(azureServiceBus))
{
    builder.Services.PostConfigure<ServiceBusOptions>(o => o.ConnectionString = azureServiceBus);
}

// --- data layer -------------------------------------------------------------
builder.Services.AddSingleton<IOracleConnectionFactory, OracleConnectionFactory>();
builder.Services.AddScoped<StudentRepository>();
builder.Services.AddScoped<SchedulingRepository>();
builder.Services.AddScoped<BillingRepository>();

// The publisher is a singleton because the hosted service that uses it is one.
builder.Services.AddSingleton<OutboxRepository>();

// --- event publishing -------------------------------------------------------
// Falling back to the logging publisher keeps the whole stack runnable without
// an Azure subscription, which matters for anyone cloning this repo.
builder.Services.AddSingleton<IEventPublisher>(sp =>
{
    var options = sp.GetRequiredService<IOptions<ServiceBusOptions>>();
    if (options.Value.IsConfigured)
    {
        return new ServiceBusEventPublisher(
            options, sp.GetRequiredService<ILogger<ServiceBusEventPublisher>>());
    }

    return new LoggingEventPublisher(sp.GetRequiredService<ILogger<LoggingEventPublisher>>());
});

// Event Grid is a stretch feature and stays entirely inert unless a topic is
// configured — the disabled implementation handles no event types, so the
// publisher never reaches it.
builder.Services.AddSingleton<IEventGridPublisher>(sp =>
{
    var options = sp.GetRequiredService<IOptions<EventGridOptions>>();
    if (!options.Value.IsConfigured)
    {
        return new DisabledEventGridPublisher();
    }

    return new AzureEventGridPublisher(
        options, sp.GetRequiredService<ILogger<AzureEventGridPublisher>>());
});

builder.Services.AddHostedService<OutboxPublisherService>();

// --- web --------------------------------------------------------------------
builder.Services.AddControllers();
builder.Services.AddProblemDetails();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(options =>
{
    options.SwaggerDoc("v1", new()
    {
        Title = "Tutoring Operations API",
        Version = "v1",
        Description =
            "A thin HTTP shell over Oracle PL/SQL packages. Business rules live " +
            "in PKG_SCHEDULING, PKG_BILLING and PKG_VALIDATION; this API binds " +
            "parameters and maps result codes to HTTP status codes."
    });
});

// The Razor Pages UI calls this API from the browser in local development.
builder.Services.AddCors(options => options.AddDefaultPolicy(policy => policy
    .AllowAnyHeader()
    .AllowAnyMethod()
    .SetIsOriginAllowed(origin => builder.Environment.IsDevelopment()
        || builder.Configuration.GetSection("Cors:AllowedOrigins")
            .Get<string[]>()?.Contains(origin) == true)));

var app = builder.Build();

// --- pipeline ---------------------------------------------------------------
app.UseExceptionHandler(handler => handler.Run(async context =>
{
    var feature = context.Features.Get<IExceptionHandlerFeature>();
    var logger = context.RequestServices.GetRequiredService<ILoggerFactory>()
        .CreateLogger("TutoringOps.Api");

    logger.LogError(feature?.Error, "Unhandled exception on {Path}", context.Request.Path);

    // An Oracle error that reaches here is a bug, not a business outcome:
    // business outcomes come back as result codes. Say so plainly rather than
    // leaking ORA- text to a parent's browser.
    var isOracle = feature?.Error is OracleException;
    context.Response.StatusCode = StatusCodes.Status500InternalServerError;
    await context.Response.WriteAsJsonAsync(new
    {
        title = isOracle ? "Database error" : "Unexpected error",
        status = 500,
        detail = app.Environment.IsDevelopment()
            ? feature?.Error.Message
            : "The request could not be completed."
    });
}));

// The OpenAPI document is served in every environment, because APIM imports the
// API from it — without that, every operation has to be recreated by hand in
// the portal and then kept in step. The document describes a public surface and
// contains no secrets. The interactive UI stays development-only.
app.UseSwagger();

if (app.Environment.IsDevelopment())
{
    app.UseSwaggerUI();
}

app.UseCors();
app.MapControllers();

// Liveness for App Service, and a readiness probe that actually talks to Oracle
// rather than reporting healthy while the database is unreachable.
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapGet("/health/ready", async (
    IOracleConnectionFactory factory, CancellationToken cancellationToken) =>
{
    try
    {
        await using var connection = await factory.OpenAsync(cancellationToken);
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1 FROM DUAL";
        await command.ExecuteScalarAsync(cancellationToken);
        return Results.Ok(new { status = "ok", oracle = "reachable" });
    }
    catch (Exception ex)
    {
        return Results.Json(
            new { status = "degraded", oracle = "unreachable", detail = ex.Message },
            statusCode: StatusCodes.Status503ServiceUnavailable);
    }
});

app.Run();

/// <summary>Exposed so the integration test project can host the API.</summary>
public partial class Program;
