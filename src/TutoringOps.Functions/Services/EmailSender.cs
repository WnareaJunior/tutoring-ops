using Microsoft.Extensions.Logging;
using SendGrid;
using SendGrid.Helpers.Mail;

namespace TutoringOps.Functions.Services;

public interface IEmailSender
{
    Task SendAsync(string toAddress, EmailMessage message, CancellationToken cancellationToken);
}

public sealed class SendGridEmailSender : IEmailSender
{
    private readonly SendGridClient _client;
    private readonly EmailAddress _from;
    private readonly ILogger<SendGridEmailSender> _logger;

    public SendGridEmailSender(string apiKey, string fromAddress, string fromName,
        ILogger<SendGridEmailSender> logger)
    {
        _client = new SendGridClient(apiKey);
        _from = new EmailAddress(fromAddress, fromName);
        _logger = logger;
    }

    public async Task SendAsync(
        string toAddress, EmailMessage message, CancellationToken cancellationToken)
    {
        var mail = MailHelper.CreateSingleEmail(
            _from,
            new EmailAddress(toAddress),
            message.Subject,
            message.TextBody,
            message.HtmlBody);

        var response = await _client.SendEmailAsync(mail, cancellationToken);

        if ((int)response.StatusCode >= 400)
        {
            var body = await response.Body.ReadAsStringAsync(cancellationToken);

            // Throwing puts the message back on the subscription, and host.json
            // retries with backoff before it lands in the dead-letter queue.
            throw new InvalidOperationException(
                $"SendGrid rejected the message: {(int)response.StatusCode} {body}");
        }

        _logger.LogInformation("Sent \"{Subject}\" to {Recipient}.", message.Subject, toAddress);
    }
}

/// <summary>
/// Used when no SendGrid key is configured. Local runs still exercise the whole
/// chain -- trigger, template selection, language choice -- without needing a
/// mail provider or sending anything to a real family.
/// </summary>
public sealed class LoggingEmailSender : IEmailSender
{
    private readonly ILogger<LoggingEmailSender> _logger;

    public LoggingEmailSender(ILogger<LoggingEmailSender> logger) => _logger = logger;

    public Task SendAsync(
        string toAddress, EmailMessage message, CancellationToken cancellationToken)
    {
        _logger.LogInformation(
            "[email not sent -- no SendGrid key] to {Recipient} | {Subject}{NewLine}{Body}",
            toAddress, message.Subject, Environment.NewLine, message.TextBody);
        return Task.CompletedTask;
    }
}
