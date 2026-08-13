# Tutoring Operations Platform

Scheduling and billing for a real SAT tutoring business. Oracle + PL/SQL for the
business rules, a thin .NET 8 API over them, Azure Service Bus → Function Apps →
a Cosmos read model, and Razor Pages on top.

The project exists to demonstrate a specific architecture, so the architecture
is not negotiable in service of making something pass. Read "Rules that are not
up for negotiation" before changing anything under `db/`.

---

## Current state: nothing has ever been executed

The code was written in an environment with no Oracle and no .NET SDK. The
PL/SQL has never been compiled, and the C# has never been built. Only static
checks were possible: every package spec member has a body implementation, and
every `PKG_X.member` reference resolves.

**The immediate task is to get `./scripts/verify.sh` to pass end to end.** Expect
genuine compile errors on the first run — that is the expected starting point,
not a surprise.

When it does pass, update the "Has it been run?" section of
`docs/build-status.md`. That file is the project's claim-discipline record: it
tracks what is *written* separately from what has actually *run*, because only
the second kind counts. Do not mark anything there as run until you have watched
it run.

## The machines

Two servers, two jobs (as of Aug 2026):

**`devbox` — the dev server.** The desktop PC: WSL2 Ubuntu behind Tailscale,
SSH port 2222, keys only (the laptop's `~/.ssh/config` has the block).
`remote.sh` targets it by default. x86_64, 47GB RAM, fast disk.

- After the desktop reboots, WSL only starts once someone logs into Windows:
  `ping devbox` works while `ssh devbox` is refused. Nothing is broken.
- `sudo` wants a password, and remote sessions cannot type one. The .NET SDK
  is therefore user-local in `~/.dotnet` (remote.sh puts it on PATH);
  anything needing root needs a human at the desktop.
- Another agent runs a separate app's containers (`reroute-*`) in the same
  WSL. Leave them alone; do not restart the Docker daemon casually.
- Oracle XE 21c in Docker, bound to `127.0.0.1:1521`, same schema and
  passwords as always (`db/docker-compose.yml`, local dev only).

**`wilsserver` — the Azure VM, now only the deployed system's Oracle host.**
The deployed API reaches it via VNet integration and a socat forwarder on its
private IP. Managed with `scripts/dev-vm.sh`; bills ~$0.06/hr running,
auto-stops 07:00 UTC nightly. **If it is stopped or Oracle is down on it, the
deployed site is degraded** — `restart: unless-stopped` brings Oracle up with
the VM. Do not point the dev loop here; export `TUTORING_REMOTE` explicitly
when it genuinely needs attention.

## Where you are running

**If this session is on a laptop and the server is remote:** nothing here can be
executed locally. There is no Oracle and no database on the laptop. Edit files
here, then run them there with `scripts/remote.sh`, which rsyncs the working
tree before every command so what runs is always what you just edited.

```bash
./scripts/remote.sh install          # sync, then db/install.sh -- the main SQL loop
./scripts/remote.sh tests            # sync, then the business rule suite
./scripts/remote.sh concurrency      # sync, then the races
./scripts/remote.sh run '<command>'  # sync, then anything, in the repo directory
./scripts/remote.sh verify           # the full run -- DETACHED, poll it
./scripts/remote.sh tail verify      # last 60 lines, returns immediately
./scripts/remote.sh status verify    # still going?
./scripts/remote.sh logs             # docker logs from the Oracle container
```

`verify` and `build` run detached in tmux on the server and tee to a log, so a
20 minute job cannot be killed by a dropped connection or a tool timeout. Start
one, then poll with `tail` — do not wait on it synchronously.

Do not edit files over SSH with `sed` or heredocs. Edit them locally with the
normal file tools; `remote.sh` gets them across.

**If this session is on the server itself:** run the scripts directly.

```bash
./scripts/verify.sh              # everything: container, schema, both suites, build, tests
./scripts/verify.sh --db-only    # stop after the SQL suites
./scripts/bootstrap-ubuntu.sh --check   # preflight, changes nothing

cd db
./install.sh                     # schema + packages; prints USER_ERRORS and exits non-zero if any are INVALID
./run_tests.sh                   # business rule suite
./run_concurrency.sh             # races, driven from independent sqlplus sessions
./seed.sh                        # demo data

docker logs -f tutoring-oracle   # watch first boot; it is slow, not hung
```

Either way: iterate with install-then-tests, not with `verify.sh`. The full run
rebuilds .NET and re-runs everything, which is minutes of waiting for feedback
you do not need while fixing a PL/SQL syntax error.

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
| `docs/running-on-ubuntu-server.md` | This machine's setup and troubleshooting |

## Conventions

- Result codes are `VARCHAR2` constants on `PKG_VALIDATION`, mapped to HTTP in
  `src/TutoringOps.Api/Data/ResultCode.cs`. Add to both when adding a code.
- Test assertions go through `PKG_TEST`. Do not introduce utPLSQL.
- Comments explain *why*, not what. Match the existing density; do not add
  narration to code that is already clear.
- Work on branch `claude/tutoring-ops-system-jjcwz8`. Commit and push when
  something meaningful works.

## Gotchas that will cost you an hour

- **Do not interrupt Oracle's first boot.** Killing it partway through creating
  the database leaves a volume that never becomes healthy. Recovery is
  `docker compose down -v && docker compose up -d`, which starts over.
- **The app user is created on first boot only.** If `install.sh` cannot connect
  as `tutoring` but the container is healthy, the volume predates the `APP_USER`
  setting. Same recovery as above.
- **Image pulls can fail over IPv6** with `connection reset by peer` on this
  network. `verify.sh` retries five times; if it still fails, append
  `precedence ::ffff:0:0/96  100` to `/etc/gai.conf` and restart Docker.
- **`docker.socket` restarts the daemon** via socket activation. Stop both when
  doing anything to Docker's storage.
- Integration tests skip themselves when Oracle is unreachable. A green
  `dotnet test` with everything skipped is not a pass — check the skip count.
