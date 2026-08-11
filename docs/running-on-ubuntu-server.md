# Running this on an Ubuntu server

The original plan assumed Oracle in Docker on WSL. The actual setup is a laptop
with terminal access to an Ubuntu server, which is a better host: it is always
on, so the database and the API survive closing the laptop, and it gives the
deployed Azure pieces something real to reach.

The shape:

```
  laptop                          ubuntu server
  ──────                          ─────────────
  editor, browser   ──ssh──▶      Oracle XE (docker, 127.0.0.1:1521)
                                  API        (127.0.0.1:5080)
                                  UI         (127.0.0.1:5090)
```

Everything binds to loopback on the server and is reached from the laptop over
an SSH tunnel. Nothing needs a firewall hole, and the Oracle listener is never
exposed.

---

## 1. Get the code onto the server

```bash
ssh you@server
git clone https://github.com/WnareaJunior/tutoring-ops.git
cd tutoring-ops
git checkout claude/tutoring-ops-system-jjcwz8
```

## 2. Preflight, then install Docker and .NET

```bash
./scripts/bootstrap-ubuntu.sh --check     # changes nothing, just reports
./scripts/bootstrap-ubuntu.sh             # installs what is missing
```

Check this before anything else, because two of its checks are hard blockers:

- **Architecture must be x86_64.** There is no arm64 build of Oracle XE. If the
  server is ARM (many cheap VPS instances and anything Ampere-based are), the
  database cannot run there at all and needs an x86_64 host.
- **Memory should be 4GB, and 2GB is the floor.** Under 2GB, Oracle XE starts
  and then dies partway through creating the database, which reads as a hang
  rather than an error.

The script adds you to the `docker` group, so **log out and back in** before
continuing.

## 3. Bring it up and prove it works

```bash
./scripts/verify.sh
```

That starts Oracle, waits on the compose healthcheck, installs the schema and
packages, runs the business-rule suite, runs the concurrency suite, then builds
and tests the .NET solution. It stops at the first failure and prints how far it
got.

First boot creates the database and takes two to four minutes. Later starts are
seconds.

Expect to fix compile errors on this first run — none of this has been through
an Oracle compiler yet. `install.sh` prints the exact `USER_ERRORS` rows (object,
line, column, message) for anything that does not compile, so the failures come
with line numbers rather than a shrug.

When it goes green, update the "Has it been run?" section of
`docs/build-status.md`. That file is the claim-discipline record and it currently
says nothing has been executed.

## 4. Load demo data and start the apps

```bash
cd db && ./seed.sh && cd ..

dotnet run --project src/TutoringOps.Api &     # 127.0.0.1:5080
dotnet run --project src/TutoringOps.Web &     # 127.0.0.1:5090
```

With no Service Bus connection string configured, the outbox publisher logs the
events it would send rather than failing — the booking flow works end to end
with no Azure account attached.

## 5. See it from the laptop

From the **laptop**, forward the ports:

```bash
ssh -N \
  -L 5090:localhost:5090 \
  -L 5080:localhost:5080 \
  -L 1521:localhost:1521 \
  you@server
```

Then, in the laptop's browser:

- <http://localhost:5090> — the admin calendar and the parent status page
- <http://localhost:5080/swagger> — the API

The `1521` forward is there so SQL Developer or the VS Code Oracle extension on
the laptop can connect to the server's database as though it were local
(`localhost:1521/XEPDB1`, user `tutoring`).

Worth putting in the laptop's `~/.ssh/config` so it is one command:

```
Host tutoring
    HostName your.server.address
    User you
    LocalForward 5090 localhost:5090
    LocalForward 5080 localhost:5080
    LocalForward 1521 localhost:1521
```

Then `ssh -N tutoring` opens all three.

## 6. Editing

Two reasonable ways, both fine:

**VS Code Remote-SSH** — install the Remote-SSH extension on the laptop, connect
to the server, open `~/tutoring-ops`. Editor on the laptop, files and terminal on
the server, no syncing. This is the smoother option for day-to-day work.

**Git as the transport** — edit on the laptop, push, `git pull` on the server.
Slower loop, but it keeps the server clean and means every change is committed,
which suits the deploy workflow.

## 7. Keeping it running after you log out

`dotnet run &` dies with the SSH session. For anything you want to leave up —
and the parent status page is exactly that — use systemd.

`/etc/systemd/system/tutoring-api.service`:

```ini
[Unit]
Description=Tutoring Operations API
After=network.target docker.service

[Service]
Type=simple
User=YOUR_USER
WorkingDirectory=/home/YOUR_USER/tutoring-ops/src/TutoringOps.Api
ExecStart=/usr/bin/dotnet run --configuration Release
Restart=on-failure
RestartSec=10
Environment=ASPNETCORE_ENVIRONMENT=Development
Environment=ASPNETCORE_URLS=http://127.0.0.1:5080

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/tutoring-ui.service` is the same with `TutoringOps.Web`,
port `5090`, and a `Requires=tutoring-api.service`.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tutoring-api tutoring-ui
journalctl -u tutoring-api -f
```

For a real deployment, `dotnet publish` to a directory and point `ExecStart` at
the produced DLL rather than using `dotnet run`, which rebuilds on every start.

Oracle already restarts on its own: compose has no `restart:` policy set, so add
`restart: unless-stopped` to `db/docker-compose.yml` if you want it back after a
server reboot.

## 8. What this changes about the Azure plan

`docs/design-decisions.md` §9 decided Oracle would not be deployed to Azure and
would be reached over a tunnel instead. The Ubuntu server is now that host, and
it is a better one than a laptop — it does not sleep, so a demo does not depend
on a lid being open.

To let the deployed API reach it:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Then set the Oracle connection string on the Azure Web App to the server's
Tailscale address. `infra/provision.sh` prints the exact `az webapp config
connection-string set` command at the end.

**Do not** open 1521 to the internet as an alternative. The compose file binds it
to loopback deliberately; an Oracle listener on a public IP with a development
password is the kind of thing that gets found by a scanner within hours.

If the server has a public IP, a firewall is worth having regardless:

```bash
sudo ufw allow OpenSSH
sudo ufw enable
```

Nothing in this project needs another port open.

## Troubleshooting

**`ORA-00845: MEMORY_TARGET not supported`** — Docker's default `/dev/shm` is
64MB and Oracle sizes its SGA against it. The compose file sets `shm_size: 1gb`;
if you are running `docker run` by hand, pass `--shm-size=1g`.

**`no matching manifest for linux/arm64`** — the architecture blocker above.
Oracle XE is x86_64 only.

**Container is healthy but `install.sh` cannot connect** — the app user is
created on *first* boot only. If the volume was created before `APP_USER` was
set, the user does not exist. Start over:
`docker compose down -v && docker compose up -d`.

**`permission denied` on the docker socket** — the group change needs a new
login. `newgrp docker` fixes the current shell.

**Oracle dies a few minutes into first boot** — almost always memory. Check
`docker logs tutoring-oracle` and `free -h`. Adding 2GB of swap is enough to get
through database creation on a 2GB box.

**Tests fail with `ORA-00942: table or view does not exist`** — the packages
compiled against a schema that was not installed. Re-run `./db/install.sh`; it
exits non-zero and prints `USER_ERRORS` if anything is INVALID.
