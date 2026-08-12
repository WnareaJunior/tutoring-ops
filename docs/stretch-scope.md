# Stretch scope: Event Grid and APIM

The two items the original plan marked "only if the month has room". Both are
now written, and both are **off by default** — the core system behaves exactly
as it did without them until someone provisions the Azure side and sets the
configuration.

That default matters more than usual here. None of this project has been
executed yet, and stretch code that could break the main path while the main
path is still unproven would make every failure ambiguous.

---

## What is built

### Event Grid: package exhausted → sell the next one

The event already existed. `PKG_BILLING.refresh_package_status` raises
`PackageExhausted` the instant a package's last hour is reserved — not on a
sweep, not when someone remembers to check the balances column. Everything here
is about turning that into an email.

| Piece | Where |
|---|---|
| Event raised in PL/SQL | `db/migrations/04_pkg_billing.sql`, `refresh_package_status` |
| Mirrored from the outbox to a custom topic | `src/TutoringOps.Api/Outbox/EventGridPublisher.cs` |
| Which event types get mirrored | `EventGrid:EventTypes`, default `PackageExhausted` only |
| Handler | `src/TutoringOps.Functions/Functions/PackageExhaustedFunction.cs` |
| Email copy | `EmailTemplates.BuildPackageExhausted` — tutor-facing, English |
| Provisioning | `infra/provision-stretch.sh` |

Why a separate path rather than a third Service Bus subscription: the two
existing subscriptions serve the family — confirmations, reminders, the
dashboard. This one serves the business. Different audience, different urgency,
different tolerance for failure. Keeping it separate means a broken sales nudge
can never delay a parent's reminder.

**The failure mode to understand.** Event Grid is a first-class outbox
destination, so a send failure rolls the batch back and retries — the same
contract as Service Bus. The consequence is that a *misconfigured* topic stalls
all event delivery rather than silently dropping these events. That is the
deliberate choice: an at-least-once guarantee with an undocumented exception is
worse than no guarantee. Watch `GET /ops/outbox`; a climbing pending count is
the symptom, and clearing `EventGrid:TopicEndpoint` is the immediate mitigation.

### APIM: a subscription key and one rate limit

| Piece | Where |
|---|---|
| Policy | `infra/apim-policy.xml` |
| Instance, API import, product, key | `infra/provision-stretch.sh` |
| OpenAPI document served in all environments | `src/TutoringOps.Api/Program.cs` |

Two things worth knowing before touching this:

**The Consumption tier does not support `<rate-limit>` or `<quota>`.** They are
subscription-scoped and depend on state the Consumption gateway does not keep.
Use them and the policy fails validation or silently never applies. The policy
here uses `<rate-limit-by-key>`, which carries its own counter key. This is the
single most common way to lose an hour on APIM Consumption.

**APIM imports the API from its OpenAPI document**, which is why `UseSwagger()`
now runs in every environment rather than only in development. Without it, every
operation has to be recreated by hand in the portal and then kept in step with
the code — the kind of drift that makes a gateway actively misleading. The
document describes a public surface and contains no secrets; the interactive UI
is still development-only.

The rate limit is 60 calls a minute per subscription. The business books a
handful of sessions a day, so that is nowhere near a real ceiling — it exists so
a runaway client is bounded and visible, and so the limit is enforced at the
edge rather than in application code. Raise it freely.

---

## What this needs from you

Three values the script cannot invent, and refuses to guess. It exits
immediately if any is unset rather than provisioning something half-configured:

| Variable | Why it cannot be defaulted |
|---|---|
| `APIM_PUBLISHER_EMAIL` | Azure requires a real publisher contact on an APIM instance |
| `APIM_PUBLISHER_NAME` | Same |
| `TUTOR_NOTIFICATION_EMAIL` | Where the package-exhausted nudge goes. A notification with no recipient is not a feature |

```bash
export APIM_PUBLISHER_EMAIL="you@example.com"
export APIM_PUBLISHER_NAME="Your Name"
export TUTOR_NOTIFICATION_EMAIL="you@example.com"

./infra/provision-stretch.sh
```

## Ordering, which is not optional

1. `infra/provision.sh` — the base resources
2. **Deploy the Function App** — Azure validates the endpoint when the Event
   Grid subscription is created, so `PackageExhaustedHandler` has to exist
   before it can be subscribed
3. **Deploy the API** — APIM imports operations from a live
   `/swagger/v1/swagger.json`
4. `infra/provision-stretch.sh`

Run it too early and it tells you which prerequisite is missing and skips that
step. Everything is idempotent, so re-running after the deploy finishes the job.

## Verifying it actually works

**APIM.** Without a key this must be rejected, which is the whole point of the
product:

```bash
curl -i "$GATEWAY/tutoring/health"                                    # 401
curl -i "$GATEWAY/tutoring/health" -H "Ocp-Apim-Subscription-Key: $KEY"  # 200
```

The rate limit, which should turn over to 429 partway through:

```bash
for i in $(seq 1 70); do
  curl -s -o /dev/null -w "%{http_code} " "$GATEWAY/tutoring/health" \
    -H "Ocp-Apim-Subscription-Key: $KEY"
done; echo
```

**Event Grid.** Book sessions against a student until their package reaches
zero, then check the Function App logs for `PackageExhaustedHandler`. The
package must actually hit zero — `refresh_package_status` only raises the event
on the transition to `EXHAUSTED`, not on every booking, which is what stops it
firing repeatedly for a student who is already out of hours.

## Cost

Neither is a standing charge. An Event Grid custom topic is effectively free at
this volume (first 100k operations a month). APIM Consumption is billed per call
with a large free grant. The App Service plan from `provision.sh` remains the
only thing that costs money whether or not anyone uses it.

## What is deliberately still not here

- **Data Factory and Service Fabric.** No use for either. Adding them to be able
  to name them is exactly the claim this project exists to avoid making.
- **APIM in front of the UI.** The plan says "in front of the API", and a
  gateway in front of server-rendered pages buys nothing here.
- **Anything reading `X-Forwarded-By`.** The policy sets it so that "only accept
  traffic through APIM" becomes a one-line change in the API later, but nothing
  enforces it today. The Web App is still directly reachable, and pretending
  otherwise would be worse than the honest note.
