# Tutoring Operations Platform

Scheduling and billing for an SAT tutoring business. Transactional data lives in
Oracle, the business rules live in PL/SQL packages, and a .NET API sits on top
as a thin shell. Bookings and cancellations become events that flow through
Azure Service Bus into .NET Function Apps, which send reminders and maintain a
Cosmos DB read model for the parent-facing dashboard.

The point of the architecture is the first sentence: **the rules are in the
database.** Everything above it asks and displays.

## Live demo

| | |
|---|---|
| Admin UI (calendar, students, packages) | <https://app-tutoringops-ui-204360.azurewebsites.net> |
| Parent view (what a family sees) | <https://app-tutoringops-ui-204360.azurewebsites.net/Status> |
| API health, including the Oracle round-trip | <https://app-tutoringops-api-204360.azurewebsites.net/health/ready> |

Demo access codes for the parent view: `T6THSXKE` (Maria Rodriguez — a
Spanish-preference family, so her page renders in Spanish) or `5XJT62Y7`
(James Chen, English). The parent dashboard is served from the Cosmos DB read
model; the admin pages talk to Oracle through the API. Booking something on
the Schedule page and watching it appear on the family's dashboard a few
seconds later is the whole event pipeline doing its job.

It runs on the cheapest tiers Azure sells, so give a cold page a few seconds.

```
┌──────────────┐   HTTP    ┌──────────────┐   stored procs   ┌────────────────────┐
│  Razor Pages │──────────▶│  ASP.NET API │─────────────────▶│  Oracle XE 21c     │
│  admin + UI  │           │  (thin shell)│                  │  PKG_SCHEDULING    │
└──────────────┘           └──────┬───────┘                  │  PKG_BILLING       │
        ▲                         │ polls                    │  PKG_VALIDATION    │
        │                         │ EVENT_OUTBOX             │  PKG_EVENTS        │
        │                         ▼                          │  EVENT_OUTBOX      │
        │                  ┌──────────────┐                  └────────────────────┘
        │                  │ Service Bus  │
        │                  │ queue+topic  │
        │                  └──────┬───────┘
        │                         │
        │            ┌────────────┴────────────┐
        │            ▼                         ▼
        │     ┌─────────────┐          ┌──────────────┐
        │     │ reminders   │          │ billing      │
        │     │ function    │          │ function     │
        │     │ (email)     │          │              │
        │     └─────────────┘          └──────┬───────┘
        │                                     │ upsert
        │            ┌────────────────────────┘
        └────────────│  Cosmos DB: student-dashboards
                     └───────────────────────────────
```

## Repository layout

| Path | What it is |
|---|---|
| `db/migrations/` | Schema and the PL/SQL packages, in install order |
| `db/tests/` | The business-rule test suite (`run_all.sql`) |
| `db/run_concurrency.sh` | The same rules, proven under real concurrent sessions |
| `db/seed/` | Demo dataset, loaded through the packages |
| `src/TutoringOps.Api/` | ASP.NET Core 8 Web API + the outbox publisher |
| `src/TutoringOps.Api.Tests/` | Integration tests against a live Oracle |
| `src/TutoringOps.Functions/` | Isolated-worker Function App: reminders, projection, nightly sweep |
| `src/TutoringOps.Web/` | Razor Pages: admin calendar and the parent status page |
| `infra/provision.sh` | Azure resources via the `az` CLI |
| `scripts/` | Ubuntu bootstrap and the one-command verify run |
| `.github/workflows/` | CI (with a real Oracle) and deployment |
| `docs/` | Design decisions, server setup, and an honest map of what is built |

## Getting it running

On a fresh Ubuntu box, all of it in two commands:

```bash
./scripts/bootstrap-ubuntu.sh   # preflight, then Docker and the .NET 8 SDK
./scripts/verify.sh             # Oracle, schema, both SQL suites, build, tests
```

`bootstrap-ubuntu.sh --check` reports without changing anything. Two of its
checks are hard blockers worth knowing about before you start: **Oracle XE is
x86_64 only** (there is no arm64 image), and it needs **about 2GB of RAM** or it
dies partway through creating the database. It also reports the storage behind
Docker's data root, which decides whether first boot takes three minutes or
thirty — an SSD behind it is by far the highest-leverage change.

If the server is a separate machine from the one you are typing on,
`scripts/remote.sh` syncs the working tree over SSH and runs any of this
remotely; point `TUTORING_REMOTE` at the box.

The steps individually:

### 1. Oracle

```bash
cd db
docker compose up -d          # Oracle XE 21c; first boot takes a couple of minutes
./install.sh                  # schema + packages, verifies every object is VALID
./run_tests.sh                # the business-rule suite
./run_concurrency.sh          # the concurrency suite
./seed.sh                     # optional demo data
```

The listener is bound to `127.0.0.1` on purpose — see the note in
`docker-compose.yml` before changing it.

The container creates an application schema (`tutoring`) inside `XEPDB1`.
Nothing is ever built in `SYSTEM`.

The scripts use `sqlplus` if it is on your PATH and otherwise run it inside the
container, so no Oracle client install is needed.

### 2. The API

```bash
cd src/TutoringOps.Api
dotnet run
```

`appsettings.Development.json` already points at the local container. Swagger is
at <http://localhost:5080/swagger>, and `TutoringOps.Api.http` walks the whole
booking flow including every failure case.

With no Service Bus connection string configured, the outbox publisher logs
events instead of sending them — the whole stack runs on a laptop with no Azure
subscription.

### 3. The UI

```bash
cd src/TutoringOps.Web
dotnet run     # http://localhost:5090
```

### 4. The Function App

```bash
cd src/TutoringOps.Functions
cp local.settings.json.template local.settings.json   # then fill in
func start
```

Without a SendGrid key it logs the emails it would send; without a Cosmos
connection string it logs the documents it would write. Both paths still
exercise the trigger, the language selection and the projection logic.

### 5. Azure

```bash
az login
./infra/provision.sh
```

Provisions the Service Bus namespace (Standard — topics need it), the queue, the
topic and its two filtered subscriptions, a free-tier Cosmos account and
container, an App Service plan, two Web Apps and a Consumption Function App,
then wires the settings between them. Oracle is deliberately not provisioned;
see `docs/design-decisions.md`.

## The rules, and where each one lives

| Rule | Enforced by |
|---|---|
| The tutor cannot be double booked | `PKG_SCHEDULING.book_session` — locks the tutor row, then checks for overlap |
| Sessions run Mon–Sat, 08:00–21:00, and must finish before closing | `PKG_VALIDATION.check_business_hours` |
| Durations are 30–300 minutes on the quarter hour | `PKG_VALIDATION.check_duration` + a check constraint |
| A booking needs prepaid hours or an unapplied payment | `PKG_BILLING.reserve_hours`, falling back to `apply_payment` |
| Hours come off the oldest package first | `PKG_BILLING.reserve_hours`, FIFO with `FOR UPDATE` |
| Cancelling more than 24 hours ahead returns the hours | `PKG_SCHEDULING.cancel_session` |
| Cancelling inside 24 hours forfeits them | same procedure, `LATE_CANCELLED` |
| A completed session can never be cancelled | `PKG_VALIDATION.is_valid_transition` |
| Hours can never go negative | `CK_PACKAGES_REMAIN` — a check constraint, not application code |
| Hours can never be restored twice | `UX_LEDGER_SESSION_ENTRY` — a unique index, not application code |
| An event exists only if its transaction committed | `EVENT_OUTBOX`, written in the same transaction |

The last three are the interesting ones: they are enforced by the schema, so
they hold even against a caller that gets the logic wrong, a transaction that
rolls back halfway, or two people clicking cancel at the same moment.
`db/tests/40_test_consistency.sql` and `db/run_concurrency.sh` prove exactly
that.

## How hours are accounted for

Hours are **reserved when a session is booked**, not deducted when it is taught.

That is a deliberate departure from the more obvious "deduct on completion", and
it is what makes the cancellation rules coherent: if hours only left the package
at completion, there would be nothing for an on-time cancellation to give back,
and a student with two hours left could book ten sessions. Under reservation:

- **book** → `RESERVE` ledger row, balance drops
- **complete** → no ledger row; the absence of a release is what makes the
  deduction final
- **cancel on time** → `RELEASE` ledger row, balance restored
- **cancel late** → no ledger row; the reservation simply stands, which is what
  "the hour is still charged" means

`PACKAGES.HOURS_REMAINING` is a materialised balance and `PACKAGE_LEDGER` is the
append-only truth behind it. Every test asserts the two agree.

## Result codes and HTTP

PL/SQL returns a string result code; the API maps it and passes the raw code
through in the problem-details `title`, so a client can branch on the exact
reason rather than parsing prose.

| Result code | HTTP |
|---|---|
| `ERR_DOUBLE_BOOKED`, `ERR_INVALID_TRANSITION` | 409 Conflict |
| `ERR_INSUFFICIENT_HOURS` | 402 Payment Required |
| `ERR_*_NOT_FOUND` | 404 Not Found |
| `ERR_OUTSIDE_BUSINESS_HOURS`, `ERR_INVALID_DURATION`, `ERR_START_IN_PAST`, `ERR_STUDENT_INACTIVE`, `ERR_INVALID_INPUT` | 422 Unprocessable Entity |

## Further reading

- `docs/design-decisions.md` — the choices worth defending, including where this
  departs from the original plan and why
- `docs/build-status.md` — exactly which parts have been executed and which have
  not, kept honest on purpose
