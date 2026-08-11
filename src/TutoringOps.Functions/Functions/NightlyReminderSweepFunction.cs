using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using TutoringOps.Functions.Services;

namespace TutoringOps.Functions.Functions;

/// <summary>
/// Runs at 18:00 every evening and asks the API to queue a reminder for every
/// confirmed session inside the next 24 hours.
///
/// The function holds no logic of its own: "which sessions need a reminder, and
/// has one already been queued" is PKG_SCHEDULING.queue_due_reminders, which is
/// idempotent. So a retry, a double firing, or a manual run costs nothing --
/// the second call queues zero.
///
/// The reminder events it queues land in the outbox and travel the same path as
/// everything else, which is why this function does not send any email itself.
/// </summary>
public sealed class NightlyReminderSweepFunction
{
    private const int HoursAhead = 24;

    private readonly TutoringApiClient _api;
    private readonly ILogger<NightlyReminderSweepFunction> _logger;

    public NightlyReminderSweepFunction(
        TutoringApiClient api, ILogger<NightlyReminderSweepFunction> logger)
    {
        _api = api;
        _logger = logger;
    }

    // 18:00 daily. RunOnStartup stays off deliberately: a deploy should not
    // trigger a sweep, even though the sweep is safe to repeat.
    [Function("NightlyReminderSweep")]
    public async Task RunAsync(
        [TimerTrigger("0 0 18 * * *")] TimerInfo timer,
        CancellationToken cancellationToken)
    {
        _logger.LogInformation(
            "Nightly reminder sweep starting. Last run: {Last}. Next: {Next}.",
            timer.ScheduleStatus?.Last, timer.ScheduleStatus?.Next);

        var queued = await _api.QueueRemindersAsync(HoursAhead, cancellationToken);

        _logger.LogInformation(
            "Queued {Count} reminder(s) for sessions in the next {Hours} hours.",
            queued, HoursAhead);
    }
}
