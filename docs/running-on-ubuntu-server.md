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

GitHub stopped accepting passwords over HTTPS in August 2021, so cloning needs
an SSH key (or a personal access token — a key is less to manage on a machine
that will be pulling unattended).

**First time on this machine only:**

```bash
ssh you@server

ssh-keygen -t ed25519 -C "you@example.com"    # Enter for the default path
cat ~/.ssh/id_ed25519.pub
```

Paste that public key into GitHub under **Settings → SSH and GPG keys → New SSH
key**, type *Authentication key*. The public key (`.pub`) is the one that leaves
the server; the private key never does.

Then check it works:

```bash
ssh -T git@github.com
```

The first connection asks you to trust GitHub's host key. Compare the
fingerprint it shows against GitHub's published list rather than typing `yes`
reflexively — for the Ed25519 key it should be
`SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`. GitHub publishes all of
them at *Authentication → GitHub's SSH key fingerprints* in their docs.

Success looks like `Hi <username>! You've successfully authenticated, but GitHub
does not provide shell access.` That last clause is expected, not an error.

**Then clone over SSH:**

```bash
git clone git@github.com:WnareaJunior/tutoring-ops.git
cd tutoring-ops
git checkout claude/tutoring-ops-system-jjcwz8
```

If you already cloned over HTTPS and want to keep that directory, just repoint
the remote:

```bash
git remote set-url origin git@github.com:WnareaJunior/tutoring-ops.git
git remote -v
```

### Notes on the key

**If you gave the key a passphrase**, git will ask for it on every pull. Load it
into an agent once per login instead:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

For a service that pulls unattended, a passphrase you are never there to type is
not protecting anything — either leave the key without one, or use a repo-scoped
**deploy key** (GitHub → repo → Settings → Deploy keys), which can be read-only
and is revocable without touching your account.

**If you would rather no key existed on the server at all**, forward the agent
from the laptop, which already has your GitHub key:

```bash
ssh -A you@server        # then git on the server uses the laptop's key
```

The trade is that anyone with root on the server can use your forwarded agent
while the session is open. On your own box that is usually fine; on a shared one
it is not.

**If outbound port 22 is blocked**, GitHub also serves SSH on 443. Add to
`~/.ssh/config` on the server:

```
Host github.com
    Hostname ssh.github.com
    Port 443
    User git
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

## 3a. Put Docker on the Thunderbolt SSD

A 2012 Intel Mac runs this fine — the CPU was never the bottleneck. Storage is,
and if there is a Thunderbolt SSD attached then the answer is simply to put
Docker's data on it and stop thinking about the internal drive.

Thunderbolt 1 on a 2012 Mac is 10 Gbps. A SATA SSD tops out around 550 MB/s, so
the interface is nowhere near the limit — you get the SSD's full speed, and the
timings below are the fast ones.

| Step | on the internal HDD | on the Thunderbolt SSD |
|---|---|---|
| `docker pull` of the image (~2GB) | 5–10 min | 1–2 min |
| First boot: creating the database | 15–30 min | 2–4 min |
| Later starts | 2–5 min | ~30 s |
| `./run_tests.sh` | 2–5 min | under a minute |
| `dotnet build` (first, cold NuGet) | 5–15 min | 1–2 min |

### First: check the filesystem

This is the step that decides whether any of it works. A drive that came from a
Mac is formatted APFS or HFS+, and neither is usable here — Linux has no
production-quality write support for APFS, and exFAT has no POSIX ownership at
all, which Docker and Oracle both require.

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL
```

If `FSTYPE` is `apfs`, `hfsplus` or `exfat`, it needs an ext4 filesystem. That
is **destructive** — copy anything you care about off it first:

```bash
sudo mkfs.ext4 -L tutoring-ssd /dev/sdX1     # check the device name twice
```

If it is already `ext4`, skip straight on.

### Mount it so it survives a reboot

```bash
sudo mkdir -p /mnt/ssd
sudo blkid /dev/sdX1        # copy the UUID
```

Add to `/etc/fstab`:

```
UUID=<uuid>  /mnt/ssd  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
```

`nofail` means the machine still boots if the drive is unplugged, rather than
dropping to an emergency shell over a missing external disk.

### Then stop Docker silently falling back

This is the part worth doing carefully. `nofail` lets the system boot without
the SSD — and if Docker starts while `/mnt/ssd` is not mounted, it will happily
create a brand new empty data-root at that path on the *internal* disk. Your
containers and volumes are not gone, but Docker will behave as though they never
existed, and the database will look empty for no visible reason.

Tell systemd that Docker requires the mount:

```bash
sudo systemctl edit docker.service
```

Add:

```ini
[Unit]
RequiresMountsFor=/mnt/ssd
```

Now Docker refuses to start without the SSD, which is a loud, obvious failure
instead of a quiet wrong one.

### Move the data

```bash
sudo systemctl stop docker
sudo mkdir -p /mnt/ssd/docker
sudo rsync -aP /var/lib/docker/ /mnt/ssd/docker/
printf '{\n  "data-root": "/mnt/ssd/docker"\n}\n' | sudo tee /etc/docker/daemon.json
sudo systemctl daemon-reload
sudo systemctl start docker

docker info -f '{{.DockerRootDir}}'      # should print /mnt/ssd/docker
```

Once that reports the new path and your containers are visible, reclaim the
space on the internal drive:

```bash
sudo rm -rf /var/lib/docker.bak && sudo mv /var/lib/docker /var/lib/docker.bak
# ... confirm everything still works, then:
sudo rm -rf /var/lib/docker.bak
```

`./scripts/bootstrap-ubuntu.sh --check` asks Docker where its root actually is,
so after this it should report an SSD rather than a spinning disk.

### Worth knowing

- **Do not unplug it while Oracle is running.** Datafiles on a disk that
  disappears mid-write is how you corrupt a database. Thunderbolt is stable
  enough for this; a yanked cable is not.
- **Put swap there too** if the box has 4GB or less. Swapping to the mechanical
  drive is the one thing that will make this feel unusable, and swapping to an
  SSD is merely unremarkable.
- **The build too.** Keeping the repo and the NuGet cache on the SSD is worth it
  for the same reason as Docker; the internal drive can end up doing nothing but
  holding the OS.
- **Thermals.** Twelve-year-old thermal paste plus sustained database I/O is
  worth an eye, since throttling shows up as mysterious slowness rather than an
  error: `sudo apt-get install -y lm-sensors && sudo sensors-detect --auto`,
  then `watch -n5 sensors`.

### If you end up on the internal drive after all

The timeouts in this project are sized for that case anyway — the compose
healthcheck allows 15 minutes before failures start counting, and `verify.sh`
waits up to 40 while printing elapsed time every minute, bailing early only if
the container actually dies.

**Do not interrupt the first boot.** A quiet terminal and a hung process look
identical, and killing Oracle partway through creating the database leaves a
volume that never becomes healthy; the recovery is
`docker compose down -v && docker compose up -d`. Watch it work with
`docker logs -f tutoring-oracle`. And do not run `dotnet build` while the
database is being created — on one spindle they halve each other.

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
`docker logs tutoring-oracle` and `free -h`. On a 2GB box, adding swap is enough
to get through database creation, though on a mechanical disk prefer `zram` over
a swap file (see §3a).

**First boot seems to have hung** — on a spinning disk it has probably not.
`docker logs -f tutoring-oracle` shows whether it is still working. See §3a for
what the timings actually look like on that hardware.

**Tests fail with `ORA-00942: table or view does not exist`** — the packages
compiled against a schema that was not installed. Re-run `./db/install.sh`; it
exits non-zero and prints `USER_ERRORS` if anything is INVALID.
