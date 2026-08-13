# Design decisions

The choices in this system that are worth being able to defend, and the two
places where the build deliberately departs from the original plan.

---

## 1. Hours are reserved at booking, not deducted at completion

**The plan said:** `complete_session` deducts hours from the package.

**What is built:** `book_session` reserves the hours; `complete_session` moves
no hours at all.

**Why the change was necessary.** The original plan contains a rule that cannot
work under deduct-on-completion: *"cancel outside the window: hours restored to
package."* If hours have not left the package yet, there is nothing to restore.
The two rules contradict each other.

Reservation resolves it and fixes a second problem at the same time: under
deduct-on-completion, a student with two hours left could book ten sessions,
because nothing checks the balance against work already committed. Reserving at
booking makes `HOURS_REMAINING` mean "hours not yet spoken for", which is the
number that actually needs protecting.

The four outcomes then line up:

| Outcome | Ledger | Effect |
|---|---|---|
| booked | `RESERVE` (negative) | balance drops |
| completed | *nothing* | the deduction becomes final by never being released |
| cancelled on time | `RELEASE` (positive) | balance restored |
| cancelled late | *nothing* | the reservation stands — the hour is charged |

If the real business policy differs, the place to change it is
`PKG_SCHEDULING.cancel_session` and `PKG_VALIDATION.c_late_cancel_hours` — the
policy is in one procedure and one constant, not spread across the stack.

## 2. A ledger, not just a balance column

`PACKAGES.HOURS_REMAINING` could have been the only record of hours. Instead
every movement is also a row in `PACKAGE_LEDGER`, and the balance is the running
sum of those rows.

That buys two things no amount of careful application code can:

```sql
CREATE UNIQUE INDEX UX_LEDGER_SESSION_ENTRY
  ON PACKAGE_LEDGER (SESSION_ID, PACKAGE_ID, ENTRY_TYPE);
```

A second `RELEASE` for the same session is a constraint violation, not a silent
double credit. And:

```sql
CONSTRAINT CK_PACKAGES_REMAIN CHECK (HOURS_REMAINING >= 0)
```

A negative balance cannot be committed by any code path, correct or not.

It also handles a case a single `PACKAGE_ID` column on `SESSIONS` cannot: a
90-minute lesson against a package with one hour left spills into the next
package and writes two `RESERVE` rows. Cancelling unwinds both, exactly once
each. `db/tests/20_test_billing.sql` covers it.

**The short answer to "why is the business logic in the database":** because
the invariant is enforced by the schema. Two people can hit cancel at the same
instant on two different machines and the hour comes back once, because the
second `RELEASE` cannot exist. No amount of retry logic, distributed lock or
careful C# is needed, and no future caller can get it wrong.

## 3. Lock ordering: students, then tutors

Two locks exist:

- the **student row**, taken by everything that changes that student's hours or
  money
- the **tutor row**, taken by everything that changes the calendar

Booking needs both. Deadlock is avoided the boring way: **STUDENTS is always
locked before TUTORS**, in every procedure, with no exceptions. Two concurrent
bookings queue up instead of deadlocking.

The tutor row is the lock target for double-booking because you cannot lock a
row that does not exist yet — there is no "the 3pm slot" row to take. Locking
the tutor serialises anyone trying to put anything on that tutor's calendar,
which makes the overlap count a decision rather than a guess.

`db/run_concurrency.sh` runs six concurrent sessions against each of these paths
and asserts exactly one winner.

## 4. The outbox, and at-least-once delivery

Business procedures never publish to Service Bus. They write a row to
`EVENT_OUTBOX` in the same transaction as the state change, and a background
service in the API drains it.

If the transaction rolls back, the event disappears with it. The alternative —
publishing from application code after the commit — has a window where a parent
gets "your lesson is confirmed" for a lesson that does not exist.
`db/tests/40_test_consistency.sql` asserts a rolled-back booking leaves no event.

**This is at-least-once, not exactly-once, and the code says so.** The publisher
holds one transaction across claim → send → mark → commit. A send can succeed
and the commit still fail, replaying that message. So:

- every message carries a stable `MessageId` (the outbox id), so Service Bus
  duplicate detection can be turned on without changing any code
- the billing consumer re-reads the whole dashboard rather than applying a
  delta, which makes replay a no-op
- a duplicate reminder email is accepted as the cost, because it is an
  annoyance rather than a correctness problem

Polling every few seconds rather than a change feed is a deliberate fit to the
scale. A handful of bookings a day does not justify anything cleverer.

## 5. A queue *and* a topic

Both, on purpose, and they do different jobs:

- **`session-events` (queue)** — the durable work list. A consumer added next
  year gets everything from the moment it subscribes, and competing consumers
  can share the load.
- **`session-notifications` (topic)** — fan-out. The reminder function and the
  billing function each need to see *every* relevant message; on a queue they
  would compete and each would see about half.

The `reminders` subscription carries a SQL filter so it only receives events a
parent should hear about. `billing-updates` keeps the default rule, because
anything that can change a balance should refresh the read model.

## 6. The Function App reads through the API, not Oracle

The functions hold no Oracle connection. Every read goes through the API.

Oracle lives on a machine at home behind a tunnel. Funnelling reads through the
API means one component holds that connection string and one component knows the
PL/SQL contract. It also means the read model is built from exactly the data the
parent page would show, because it is literally the same endpoint.

The cost is a network hop and a hard dependency on the API being up. At this
scale that is the right trade; at a larger one the projection would move to a
change feed off the database itself.

## 7. The read model is rebuilt, not patched

`BillingProjectionFunction` does not compute the new balance from the event. It
re-reads the whole dashboard and upserts that.

This makes the function idempotent and order-independent for free. Replaying an
old event just writes current truth again. Applying a delta twice would quietly
corrupt the number a parent reads — and it would be corrupt in Cosmos while
Oracle stayed correct, which is the worst kind of wrong to debug.

One-way flow throughout: Oracle → events → Cosmos → the page. There is no path
by which a stale document can corrupt the data it came from.

## 8. The parent page has a code, not an identity system

The status page takes an eight-character per-student code and keeps it in a
session cookie. That is all.

It is not an identity system and does not pretend to be one. What it actually
provides: a URL a parent cannot guess, that does not expose any other family's
data, and that can be rotated by updating one column. What it does not provide:
revocation on a shared link, an audit trail, or protection against a code
forwarded to someone else.

For a business with a few families that is the right size of solution. Adding
real identity would mean a login, a password reset flow and an account a parent
has to remember — more surface area, more to go wrong, in exchange for
protecting a list of lesson times.

The codes deliberately exclude `0/O` and `1/I/L`, because they get read aloud
over the phone.

## 9. Oracle stays self-hosted, on the Ubuntu server

The plan offered a choice. This is the decision: **Oracle is not deployed to
Azure.** `infra/provision.sh` provisions everything else.

Oracle XE in Azure means a VM, a disk and an ongoing bill for a database serving
a handful of bookings a day. The deployed API reaches it over a tunnel
(a private VNet or an overlay network), and the connection string is set by
hand on the Web App rather than committed.

The plan said WSL; the host is a dedicated Ubuntu server, which is strictly
better for this. It does not sleep, so the parent status page and the nightly
reminder sweep keep working when the laptop is shut.

The listener is bound to loopback and reached over SSH or a private network,
never published. An Oracle port open to the internet with a development password is
found by scanners in hours, and "it is only a side project" is not a mitigation.

This is worth saying out loud rather than hiding: the claim is "built with
Oracle and PL/SQL", which is true either way. Paying to run XE in a cloud would
not make it more true.

## 10. Test choices

**Not utPLSQL.** `PKG_TEST` is a small assertion harness that fits on a screen.
One fewer thing to install on a fresh box, and the suite runs from `sqlplus`.

**The concurrency suite is separate.** Genuine races need more than one session,
so `run_concurrency.sh` drives independent `sqlplus` processes and asserts on
the outcomes. Everything single-session lives in `db/tests/`.

**The .NET tests are integration tests, not unit tests.** The behaviour under
test lives in PL/SQL; a mocked data layer would test the mock. They skip
themselves when Oracle is unreachable so a fresh clone still gets a green build,
and CI runs a real Oracle container so a skip in CI is not possible.

## 11. What is deliberately not here

- **Data Factory and Service Fabric.** No use for either. Adding them to be able
  to name them would be the kind of claim this project exists to avoid.
- **APIM and Event Grid.** Listed as stretch goals and not built. `PackageExhausted`
  is already emitted by `PKG_BILLING.refresh_package_status`, so the Event Grid
  handler has a real event waiting for it whenever it gets built.
- **Full identity.** See above.
- **Multi-tutor scheduling.** The schema supports it — `SESSIONS.TUTOR_ID` is a
  real foreign key and conflicts are per tutor — but there is one row in
  `TUTORS` and the UI assumes it.
