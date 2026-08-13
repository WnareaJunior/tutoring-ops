# Tutoring Operations Platform

Scheduling and billing for a real SAT tutoring business. Oracle + PL/SQL for the
business rules, a thin .NET 8 API over them, Azure Service Bus → Function Apps →
a Cosmos read model, and Razor Pages on top.

The project exists to demonstrate a specific architecture, so the architecture
is not negotiable in service of making something pass. Read "Rules that are not
up for negotiation" before changing anything under `db/`.

`docs/build-status.md` is the project's execution record: it tracks what is
*written* separately from what has actually *run*, because only the second kind
counts. Do not mark anything there as run until you have watched it run.

## Where things run

Nothing here assumes your laptop can run Oracle — the image is x86_64 only.
If the database lives on another machine, `scripts/remote.sh` syncs the tree
over SSH and runs anything there; set `TUTORING_REMOTE=user@host`. Long jobs
(`verify`, `build`) run detached in tmux on the far end — start one, then poll
with `tail`; do not wait on it synchronously. Do not edit files over SSH with
`sed` or heredocs; edit locally and let `remote.sh` sync.

Iterate with `install` then `tests`, not with `verify.sh` — the full run
rebuilds .NET and re-runs everything, which is minutes of waiting for feedback
you do not need while fixing a PL/SQL syntax error.

The deployed system's Oracle is self-hosted and reached privately (VNet
integration; see `docs/design-decisions.md` §9). If the deployed API's
`/health/ready` reports Oracle unreachable, the database host is down or its
container is not running.

## Rules that are not up for negotiation

These are the point of the project. A test failing against one of them means the
**code** is wrong.

1. **Business logic lives in PL/SQL.** The API binds parameters, calls a
   procedure, and maps a result code to HTTP. It never decides whether a booking
   is allowed, never recomputes a balance, never re-checks a rule. If you find
   yourself adding an `if` to C# that encodes a business rule, it belongs in a
   package instead.

2. **Never weaken a constraint to make a test pass.** Two constraints carry the
   entire argument for this design:
   - `CK_PACKAGES_REMAIN` — hours can never go negative
   - `UX_LEDGER_SESSION_ENTRY` — hours can never be restored twice

   If a test trips one, something upstream is wrong. Dropping or relaxing either
   deletes the reason this project is interesting.

3. **Packages never `COMMIT`.** The caller owns the transaction. That is what
   makes a `SESSIONS` row and its `EVENT_OUTBOX` row atomic. The one deliberate
   exception is `PKG_OUTBOX.mark_failed`, which is autonomous so the error note
   survives the rollback of the batch that failed.

4. **Hours are reserved at booking, not deducted at completion.** Deliberate,
   and it contradicts the original project plan for a good reason —
   `docs/design-decisions.md` §1. `complete_session` moves no hours; the absence
   of a `RELEASE` row is what makes the deduction final.

5. **Lock ordering is STUDENTS then TUTORS, everywhere.** Reversing it anywhere
   introduces a deadlock between two concurrent bookings.

6. **No `BOOLEAN` in a package spec signature.** ODP.NET cannot bind PL/SQL
   BOOLEAN. Use `VARCHAR2` `'Y'`/`'N'`, as `PKG_VALIDATION.is_valid_transition`
   does.

## Layout

| Path | What |
|---|---|
| `db/migrations/` | Schema then packages, in install order (01–07) |
| `db/tests/` | Assertion suite; `run_all.sql` is the entry point |
| `db/run_concurrency.sh` | Real races across independent sessions |
| `src/TutoringOps.Api/` | Thin API + the outbox publisher |
| `src/TutoringOps.Functions/` | Reminders, Cosmos projection, nightly sweep |
| `src/TutoringOps.Web/` | Razor Pages: admin calendar, parent status page |
| `docs/design-decisions.md` | Why things are the way they are — read before redesigning |
| `docs/build-status.md` | Written vs. actually run. Keep it honest. |

## Conventions

- Result codes are `VARCHAR2` constants on `PKG_VALIDATION`, mapped to HTTP in
  `src/TutoringOps.Api/Data/ResultCode.cs`. Add to both when adding a code.
- Test assertions go through `PKG_TEST`. Do not introduce utPLSQL.
- Comments explain *why*, not what. Match the existing density; do not add
  narration to code that is already clear.
- `main` is the default branch, and pushing it deploys to Azure. Work on a
  feature branch and merge to `main` when something meaningful works and is
  verified.
- Secrets never enter this repository. The admin passcode, the ops API key,
  and every connection string live in Azure app settings only. The passwords
  in `db/docker-compose.yml` are local-dev-only by design and documented as
  such.

## Gotchas that will cost you an hour

- **Do not interrupt Oracle's first boot.** Killing it partway through creating
  the database leaves a volume that never becomes healthy. Recovery is
  `docker compose down -v && docker compose up -d`, which starts over.
- **The app user is created on first boot only.** If `install.sh` cannot connect
  as `tutoring` but the container is healthy, the volume predates the `APP_USER`
  setting. Same recovery as above.
- **Image pulls can fail over IPv6** with `connection reset by peer` on some
  networks. `verify.sh` retries five times; if it still fails, append
  `precedence ::ffff:0:0/96  100` to `/etc/gai.conf` and restart Docker.
- **`docker.socket` restarts the daemon** via socket activation. Stop both when
  doing anything to Docker's storage.
- Integration tests skip themselves when Oracle is unreachable. A green
  `dotnet test` with everything skipped is not a pass — check the skip count.
