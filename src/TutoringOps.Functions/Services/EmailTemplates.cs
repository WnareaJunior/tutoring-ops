using System.Globalization;
using TutoringOps.Functions.Models;

namespace TutoringOps.Functions.Services;

public sealed record EmailMessage(string Subject, string HtmlBody, string TextBody);

/// <summary>
/// Reminder and confirmation copy, in English and Spanish.
///
/// Several of the families are Spanish-speaking, so the language is a column on
/// STUDENTS and travels in the event payload rather than being guessed here.
/// Dates are formatted with the matching culture too -- a Spanish email with an
/// American date format is only half translated.
/// </summary>
public static class EmailTemplates
{
    private static readonly CultureInfo English = new("en-US");
    private static readonly CultureInfo Spanish = new("es-ES");

    public static EmailMessage? Build(SessionEvent sessionEvent)
    {
        var spanish = string.Equals(sessionEvent.PreferredLanguage, "ES",
            StringComparison.OrdinalIgnoreCase);
        var culture = spanish ? Spanish : English;

        var when = sessionEvent.StartTime.ToString("dddd d MMMM, HH:mm", culture);
        var duration = sessionEvent.DurationMinutes;
        var name = sessionEvent.StudentName;
        var hours = sessionEvent.HoursRemaining.ToString("0.##", culture);

        return sessionEvent.EventType switch
        {
            EventTypes.SessionBooked => spanish
                ? Message(
                    $"Clase confirmada: {when}",
                    $"Hola,",
                    $"La clase de {name} está confirmada para el {when} ({duration} minutos).",
                    $"Horas restantes en el paquete: {hours}.",
                    "Si necesita cancelar, hágalo con más de 24 horas de antelación.")
                : Message(
                    $"Session confirmed: {when}",
                    "Hi,",
                    $"{name}'s session is confirmed for {when} ({duration} minutes).",
                    $"Hours remaining on the package: {hours}.",
                    "If you need to cancel, please do so more than 24 hours ahead."),

            EventTypes.SessionReminderDue => spanish
                ? Message(
                    $"Recordatorio: clase el {when}",
                    "Hola,",
                    $"Le recordamos que {name} tiene clase el {when} ({duration} minutos).",
                    $"Horas restantes: {hours}.",
                    "Nos vemos pronto.")
                : Message(
                    $"Reminder: session on {when}",
                    "Hi,",
                    $"A reminder that {name} has a session on {when} ({duration} minutes).",
                    $"Hours remaining: {hours}.",
                    "See you then."),

            EventTypes.SessionCancelled => spanish
                ? Message(
                    $"Clase cancelada: {when}",
                    "Hola,",
                    $"La clase de {name} del {when} ha sido cancelada.",
                    $"Las horas se han devuelto al paquete. Horas restantes: {hours}.",
                    "Puede reservar otro horario cuando quiera.")
                : Message(
                    $"Session cancelled: {when}",
                    "Hi,",
                    $"{name}'s session on {when} has been cancelled.",
                    $"The hours have been returned to the package. Hours remaining: {hours}.",
                    "You can book another time whenever suits."),

            EventTypes.SessionLateCancelled => spanish
                ? Message(
                    $"Clase cancelada (menos de 24 h): {when}",
                    "Hola,",
                    $"La clase de {name} del {when} ha sido cancelada con menos de 24 horas de antelación.",
                    $"Según la política, la hora se descuenta igualmente. Horas restantes: {hours}.",
                    "Gracias por avisar.")
                : Message(
                    $"Session cancelled inside 24 hours: {when}",
                    "Hi,",
                    $"{name}'s session on {when} was cancelled less than 24 hours ahead.",
                    $"Per the cancellation policy the hour is still charged. Hours remaining: {hours}.",
                    "Thanks for letting me know."),

            // Completions and package events are billing concerns, not things a
            // parent needs an email about. Returning null means "no email",
            // which the function treats as a successful no-op.
            _ => null
        };
    }

    private static EmailMessage Message(
        string subject, string greeting, string line1, string line2, string closing)
    {
        var text = string.Join(Environment.NewLine + Environment.NewLine,
            greeting, line1, line2, closing);

        var html = $"""
            <div style="font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
                        font-size:15px;line-height:1.55;color:#1f2933;max-width:560px">
              <p>{System.Net.WebUtility.HtmlEncode(greeting)}</p>
              <p>{System.Net.WebUtility.HtmlEncode(line1)}</p>
              <p>{System.Net.WebUtility.HtmlEncode(line2)}</p>
              <p>{System.Net.WebUtility.HtmlEncode(closing)}</p>
            </div>
            """;

        return new EmailMessage(subject, html, text);
    }
}
