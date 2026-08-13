using TutoringOps.Web.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();

// Admin pages talk to the API; the API talks to PL/SQL. Nothing here touches
// Oracle directly.
builder.Services.AddHttpClient<TutoringApiClient>(client =>
{
    var baseUrl = builder.Configuration["TutoringApi:BaseUrl"] ?? "http://localhost:5080/";
    client.BaseAddress = new Uri(baseUrl.EndsWith('/') ? baseUrl : baseUrl + "/");
    client.Timeout = TimeSpan.FromSeconds(30);

    // The API requires this key for anything beyond /health once one is
    // configured; the Function App sends the same one.
    var opsKey = builder.Configuration["TutoringApi:OpsKey"];
    if (!string.IsNullOrWhiteSpace(opsKey))
    {
        client.DefaultRequestHeaders.Add("X-Ops-Key", opsKey);
    }
});

// The parent status page reads the Cosmos projection when it is configured and
// falls back to the API when it is not, so the page works on a laptop too.
builder.Services.AddSingleton<IDashboardReader>(sp =>
{
    var connectionString = builder.Configuration["Cosmos:ConnectionString"];

    if (string.IsNullOrWhiteSpace(connectionString))
    {
        return new ApiDashboardReader(
            sp.GetRequiredService<IHttpClientFactory>(),
            sp.GetRequiredService<ILoggerFactory>());
    }

    return new CosmosDashboardReader(
        connectionString,
        builder.Configuration["Cosmos:DatabaseName"] ?? "tutoring",
        builder.Configuration["Cosmos:ContainerName"] ?? "student-dashboards",
        sp.GetRequiredService<ILogger<CosmosDashboardReader>>());
});

// The parent's access code is held in a session cookie so it does not sit in
// the URL of every page they visit. This is not an identity system and is not
// pretending to be one -- see docs/design-decisions.md.
builder.Services.AddDistributedMemoryCache();
builder.Services.AddSession(options =>
{
    options.IdleTimeout = TimeSpan.FromHours(12);
    options.Cookie.HttpOnly = true;
    options.Cookie.IsEssential = true;
    options.Cookie.SameSite = SameSiteMode.Lax;
});

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();
app.UseSession();
app.MapRazorPages();
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.Run();
