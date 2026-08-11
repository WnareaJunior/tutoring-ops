using System.Net;
using System.Net.Http.Json;
using TutoringOps.Api.Models;
using Xunit;

namespace TutoringOps.Api.Tests;

/// <summary>
/// The Week 2 exit test, expressed as code rather than as a Postman run: the
/// full booking flow through HTTP, including every failure case.
/// </summary>
[Collection("oracle")]
public sealed class BookingFlowTests
{
    private readonly ApiFactory _factory;

    public BookingFlowTests(ApiFactory factory) => _factory = factory;

    // Each test uses its own slots so a shared database does not make them
    // collide. The offset is derived from a counter rather than randomness so
    // a failure is reproducible.
    private static int _slotCounter = 100;

    private static DateTime NextSlot(int hour = 10)
    {
        var offset = Interlocked.Increment(ref _slotCounter);
        var date = DateTime.Today.AddDays(offset);
        while (date.DayOfWeek == DayOfWeek.Sunday)
        {
            date = date.AddDays(1);
        }

        return date.AddHours(hour);
    }

    private async Task<long> CreateStudentAsync(HttpClient client, string language = "EN")
    {
        var response = await client.PostAsJsonAsync("/students", new CreateStudentRequest
        {
            FullName = $"Integration Student {Guid.NewGuid():N}"[..40],
            ParentContact = "integration@example.com",
            PreferredLanguage = language
        });

        response.EnsureSuccessStatusCode();
        var student = await response.Content.ReadFromJsonAsync<StudentResponse>();
        Assert.NotNull(student);
        return student!.StudentId;
    }

    private static async Task BuyHoursAsync(HttpClient client, long studentId, decimal hours)
    {
        var response = await client.PostAsJsonAsync("/packages", new PurchasePackageRequest
        {
            StudentId = studentId,
            Hours = hours,
            Amount = hours * 60,
            Method = "ZELLE"
        });

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
    }

    private static async Task<decimal> GetBalanceAsync(HttpClient client, long studentId)
    {
        var balance = await client.GetFromJsonAsync<BalanceResponse>(
            $"/students/{studentId}/balance");
        Assert.NotNull(balance);
        return balance!.HoursRemaining;
    }

    /// <summary>The PL/SQL result code travels in the problem-details title.</summary>
    private static async Task AssertFailureAsync(
        HttpResponseMessage response, HttpStatusCode expectedStatus, string expectedCode)
    {
        Assert.Equal(expectedStatus, response.StatusCode);

        var problem = await response.Content.ReadFromJsonAsync<ProblemShape>();
        Assert.NotNull(problem);
        Assert.Equal(expectedCode, problem!.Title);
    }

    private sealed record ProblemShape(string? Title, int? Status, string? Detail);

    [OracleFact]
    public async Task Booking_reserves_hours_and_cancelling_gives_them_back()
    {
        var client = _factory.CreateClient();
        var studentId = await CreateStudentAsync(client);
        await BuyHoursAsync(client, studentId, 10);

        Assert.Equal(10m, await GetBalanceAsync(client, studentId));

        var booked = await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = studentId,
            StartTime = NextSlot(),
            DurationMinutes = 90
        });

        Assert.Equal(HttpStatusCode.Created, booked.StatusCode);
        var session = await booked.Content.ReadFromJsonAsync<SessionResponse>();
        Assert.NotNull(session);
        Assert.Equal("CONFIRMED", session!.Status);

        // Reserved at booking, not at completion.
        Assert.Equal(8.5m, await GetBalanceAsync(client, studentId));

        var cancelled = await client.DeleteAsync($"/sessions/{session.SessionId}");
        cancelled.EnsureSuccessStatusCode();

        var afterCancel = await cancelled.Content.ReadFromJsonAsync<SessionResponse>();
        Assert.Equal("CANCELLED", afterCancel!.Status);
        Assert.Equal(10m, await GetBalanceAsync(client, studentId));
    }

    [OracleFact]
    public async Task Cancelling_twice_is_refused_and_does_not_credit_twice()
    {
        var client = _factory.CreateClient();
        var studentId = await CreateStudentAsync(client);
        await BuyHoursAsync(client, studentId, 5);

        var booked = await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = studentId,
            StartTime = NextSlot(),
            DurationMinutes = 60
        });
        var session = await booked.Content.ReadFromJsonAsync<SessionResponse>();

        (await client.DeleteAsync($"/sessions/{session!.SessionId}")).EnsureSuccessStatusCode();
        Assert.Equal(5m, await GetBalanceAsync(client, studentId));

        var second = await client.DeleteAsync($"/sessions/{session.SessionId}");
        await AssertFailureAsync(second, HttpStatusCode.Conflict, "ERR_INVALID_TRANSITION");

        // The balance is the assertion that matters: a second credit here would
        // be free tutoring hours conjured out of an HTTP retry.
        Assert.Equal(5m, await GetBalanceAsync(client, studentId));
    }

    [OracleFact]
    public async Task Overlapping_booking_is_a_conflict()
    {
        var client = _factory.CreateClient();
        var first = await CreateStudentAsync(client);
        var second = await CreateStudentAsync(client);
        await BuyHoursAsync(client, first, 5);
        await BuyHoursAsync(client, second, 5);

        var slot = NextSlot(14);

        var one = await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = first,
            StartTime = slot,
            DurationMinutes = 60
        });
        Assert.Equal(HttpStatusCode.Created, one.StatusCode);

        // Different student, same tutor, overlapping half hour.
        var two = await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = second,
            StartTime = slot.AddMinutes(30),
            DurationMinutes = 60
        });
        await AssertFailureAsync(two, HttpStatusCode.Conflict, "ERR_DOUBLE_BOOKED");

        // The refused booking must not have spent anything.
        Assert.Equal(5m, await GetBalanceAsync(client, second));
    }

    [OracleFact]
    public async Task Booking_without_balance_is_payment_required()
    {
        var client = _factory.CreateClient();
        var studentId = await CreateStudentAsync(client);

        var response = await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = studentId,
            StartTime = NextSlot(),
            DurationMinutes = 60
        });

        await AssertFailureAsync(
            response, HttpStatusCode.PaymentRequired, "ERR_INSUFFICIENT_HOURS");
    }

    [OracleFact]
    public async Task Times_outside_business_hours_are_rejected()
    {
        var client = _factory.CreateClient();
        var studentId = await CreateStudentAsync(client);
        await BuyHoursAsync(client, studentId, 10);

        var tooEarly = await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = studentId,
            StartTime = NextSlot(6),
            DurationMinutes = 60
        });
        await AssertFailureAsync(tooEarly,
            HttpStatusCode.UnprocessableEntity, "ERR_OUTSIDE_BUSINESS_HOURS");

        // Starts inside hours but would run past closing.
        var overruns = await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = studentId,
            StartTime = NextSlot(20),
            DurationMinutes = 120
        });
        await AssertFailureAsync(overruns,
            HttpStatusCode.UnprocessableEntity, "ERR_OUTSIDE_BUSINESS_HOURS");

        var inThePast = await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = studentId,
            StartTime = DateTime.Today.AddDays(-3).AddHours(10),
            DurationMinutes = 60
        });
        await AssertFailureAsync(inThePast,
            HttpStatusCode.UnprocessableEntity, "ERR_START_IN_PAST");
    }

    [OracleFact]
    public async Task A_completed_session_cannot_be_cancelled()
    {
        var client = _factory.CreateClient();
        var studentId = await CreateStudentAsync(client);
        await BuyHoursAsync(client, studentId, 5);

        var booked = await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = studentId,
            StartTime = NextSlot(),
            DurationMinutes = 60
        });
        var session = await booked.Content.ReadFromJsonAsync<SessionResponse>();

        var completed = await client.PostAsync($"/sessions/{session!.SessionId}/complete", null);
        completed.EnsureSuccessStatusCode();
        var after = await completed.Content.ReadFromJsonAsync<SessionResponse>();
        Assert.Equal("COMPLETED", after!.Status);

        var cancel = await client.DeleteAsync($"/sessions/{session.SessionId}");
        await AssertFailureAsync(cancel, HttpStatusCode.Conflict, "ERR_INVALID_TRANSITION");

        Assert.Equal(4m, await GetBalanceAsync(client, studentId));
    }

    [OracleFact]
    public async Task Pay_per_session_students_book_against_unapplied_credit()
    {
        var client = _factory.CreateClient();
        var studentId = await CreateStudentAsync(client);

        var payment = await client.PostAsJsonAsync("/payments", new RecordPaymentRequest
        {
            StudentId = studentId,
            Amount = 75,
            Method = "VENMO"
        });
        Assert.Equal(HttpStatusCode.Created, payment.StatusCode);

        var booked = await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = studentId,
            StartTime = NextSlot(),
            DurationMinutes = 60
        });
        Assert.Equal(HttpStatusCode.Created, booked.StatusCode);

        var balance = await client.GetFromJsonAsync<BalanceResponse>(
            $"/students/{studentId}/balance");
        Assert.Equal(0m, balance!.HoursRemaining);
        Assert.Equal(0m, balance.UnappliedCredit);
    }

    [OracleFact]
    public async Task Dashboard_shows_upcoming_sessions_and_balance()
    {
        var client = _factory.CreateClient();
        var studentId = await CreateStudentAsync(client, "ES");
        await BuyHoursAsync(client, studentId, 6);

        await client.PostAsJsonAsync("/sessions", new BookSessionRequest
        {
            StudentId = studentId,
            StartTime = NextSlot(11),
            DurationMinutes = 60
        });

        var dashboard = await client.GetFromJsonAsync<StudentDashboardResponse>(
            $"/students/{studentId}/dashboard");

        Assert.NotNull(dashboard);
        Assert.Equal("ES", dashboard!.PreferredLanguage);
        Assert.Equal(5m, dashboard.HoursRemaining);
        Assert.Single(dashboard.UpcomingSessions);
        Assert.Single(dashboard.RecentPayments);
    }

    [OracleFact]
    public async Task Unknown_ids_are_not_found()
    {
        var client = _factory.CreateClient();

        await AssertFailureAsync(
            await client.GetAsync("/students/999999999"),
            HttpStatusCode.NotFound, "ERR_STUDENT_NOT_FOUND");

        await AssertFailureAsync(
            await client.DeleteAsync("/sessions/999999999"),
            HttpStatusCode.NotFound, "ERR_SESSION_NOT_FOUND");
    }
}
