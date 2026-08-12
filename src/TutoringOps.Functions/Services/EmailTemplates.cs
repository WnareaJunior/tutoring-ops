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

    /// <summary>
    /// The package-exhausted nudge. This one goes to the tutor, not the family,
    /// so it is English regardless of the student's language and it reads as a
    /// prompt to act rather than as a notification. The moment a student runs
    /// out is the moment to sell the next block, and that moment is easy to
    /// miss when it happens quietly in a database.
    /// </summary>
    public static EmailMessage BuildPackageExhausted(PackageEvent packageEvent)
    {
        var culture = English;
        var name = packageEvent.StudentName;
        var purchased = packageEvent.HoursPurchased.ToString("0.##", culture);
        var since = packageEvent.PurchasedDate.ToString("d MMMM yyyy", culture);

        var subject = $"{name} has used all their hours";

        var text = string.Join(Environment.NewLine + Environment.NewLine,
            $"{name} has just used the last hour of a {purchased} hour package bought on {since}.",
            $"Parent contact: {packageEvent.ParentContact}",
            "Any session booked from here needs a new package or a one-off payment, "
                + "so this is the moment to ask.");

        var html = $"""
            <div style="font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
                        font-size:15px;line-height:1.55;color:#1f2933;max-width:560px">
              <p><strong>{System.Net.WebUtility.HtmlEncode(name)}</strong> has just used the last
                 hour of a {purchased} hour package bought on {since}.</p>
              <p>Parent contact:
                 <a href="mailto:{System.Net.WebUtility.HtmlEncode(packageEvent.ParentContact)}">
                 {System.Net.WebUtility.HtmlEncode(packageEvent.ParentContact)}</a></p>
              <p>Any session booked from here needs a new package or a one-off payment,
                 so this is the moment to ask.</p>
            </div>
            """;

        return new EmailMessage(subject, html, text);
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
