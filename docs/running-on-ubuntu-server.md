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

**Do the same on the laptop, with its own key.** One key per machine, never a
copy of the same private key on both — that way losing the laptop means
revoking one key on GitHub rather than rotating access on every machine you
own. The steps are identical; just generate and upload a second key.

**If you gave the key a passphrase**, git will ask for it on every pull. Load it
into an agent once per login instead:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

To have it survive reboots so you are never asked again, put this **in the file**
`~/.ssh/config` — it is configuration, not shell commands. Run the whole block
below as one paste and it writes itself:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh

if grep -q '^Host github.com' ~/.ssh/config 2>/dev/null; then
    echo "github.com is already configured in ~/.ssh/config"
else
    cat >> ~/.ssh/config <<'EOF'

Host github.com
    AddKeysToAgent yes
    IdentityFile ~/.ssh/id_ed25519
EOF
    # macOS only. On Linux this is an unknown option and ssh will refuse to
    # read the file at all, which looks like the key has stopped working.
    [ "$(uname)" = "Darwin" ] && printf '    UseKeychain yes\n' >> ~/.ssh/config
    chmod 600 ~/.ssh/config
    echo "written"
fi
```

Then store the passphrase once, so it is never requested again:

- **macOS:** `ssh-add --apple-use-keychain ~/.ssh/id_ed25519` (on macOS 11 and
  earlier the flag is `-K`). It goes into the login keychain.
- **Linux:** the desktop keyring normally handles it after the first unlock.
- **Windows:** set the `ssh-agent` service to start automatically, then
  `ssh-add` once.

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

First boot creates the database: two to four minutes with Docker's data on an
SSD, fifteen to thirty on a mechanical drive. Later starts are much quicker. If
there is an external SSD on the machine, do §3a first — it is the difference
between those two columns.

Expect to fix compile errors on this first run — none of this has been through
an Oracle compiler yet. `install.sh` prints the exact `USER_ERRORS` rows (object,
line, column, message) for anything that does not compile, so the failures come
with line numbers rather than a shrug.

When it goes green, update the "Has it been run?" section of
`docs/build-status.md`. That file is the claim-discipline record and it currently
says nothing has been executed.

## 3a. Put Docker on the external SSD

A 2012 Intel Mac runs this fine — the CPU was never the bottleneck. Storage is,
and if there is an external SSD attached then the answer is simply to put
Docker's data on it and stop thinking about the internal drive.

A 2012 Mac has USB 3.0 (5 Gbps) and Thunderbolt 1 (10 Gbps), so an external SSD
lands somewhere around 400–500 MB/s over USB — short of what a modern NVMe
portable drive can do on a newer port, but four or five times the internal
mechanical drive, and far better than it on the random I/O that actually decides
how long creating a database takes.

| Step | on the internal HDD | on the external SSD |
|---|---|---|
| `docker pull` of the image (~2GB) | 5–10 min | 1–2 min |
| First boot: creating the database | 15–30 min | 2–4 min |
| Later starts | 2–5 min | ~30 s |
| `./run_tests.sh` | 2–5 min | under a minute |
| `dotnet build` (first, cold NuGet) | 5–15 min | 1–2 min |

The examples below use `/srv/storage`, which is where the SSD on this machine is
mounted. Substitute your own path.

### First: find it and check the filesystem

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL
```

If the SSD already shows `ext4` and a mount point, there is nothing to do here —
skip to the next step.

If `FSTYPE` is `apfs`, `hfsplus` or `exfat`, it needs an ext4 filesystem before
it is usable. Linux has no production-quality write support for APFS, and exFAT
has no POSIX ownership at all, which Docker and Oracle both require. Reformatting
is **destructive** — copy anything you care about off it first:

```bash
sudo mkfs.ext4 -L tutoring-ssd /dev/sdX1     # check the device name twice
```

### Make sure the mount survives a reboot

Being mounted right now does not mean it is in `/etc/fstab`:

```bash
grep storage /etc/fstab || echo "NOT IN FSTAB -- it will not come back after a reboot"
```

If it is missing, get the UUID with `sudo blkid /dev/sda1` and add:

```
UUID=<uuid>  /srv/storage  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
```

`nofail` means the machine still boots when the drive is unplugged, rather than
dropping to an emergency shell over a missing external disk.

### Then stop Docker silently falling back

This is the part worth doing carefully, and the reason is `nofail` above. It
lets the system boot without the SSD — and if Docker starts while `/srv/storage`
is not mounted, it will happily create a brand new empty data-root at that path
on the *internal* disk. Your containers and volumes are not gone, but Docker
behaves as though they never existed, and the database looks empty with no error
anywhere to explain it.

Tell systemd that Docker requires the mount:

```bash
sudo systemctl edit docker.service
```

Add exactly this, with **your** mount point:

```ini
[Unit]
RequiresMountsFor=/srv/storage
```

Now Docker refuses to start without the SSD: a loud, obvious failure instead of
a quiet wrong one.

A path that is not actually a mount point fails silently in the other direction
— systemd resolves it to the nearest enclosing mount, usually `/`, which is
always present. Docker keeps starting and the protection does nothing. So check
the value rather than assuming:

```bash
sudo cat /etc/systemd/system/docker.service.d/override.conf
findmnt /srv/storage        # must name the SSD, not the root filesystem
```

### Move the data

`docker.socket` has to stop too, or socket activation restarts the daemon
underneath you mid-copy.

```bash
sudo systemctl stop docker docker.socket
sudo mkdir -p /srv/storage/docker
sudo rsync -aP /var/lib/docker/ /srv/storage/docker/
printf '{\n  "data-root": "/srv/storage/docker"\n}\n' | sudo tee /etc/docker/daemon.json
sudo systemctl daemon-reload
sudo systemctl start docker

docker info -f '{{.DockerRootDir}}'      # should print /srv/storage/docker
```

Once that reports the new path and your containers are visible, reclaim the
space on the internal drive — renaming first, deleting only after something has
actually run:

```bash
sudo mv /var/lib/docker /var/lib/docker.old
# ... run ./scripts/verify.sh, confirm it all works, then:
sudo rm -rf /var/lib/docker.old
```

`./scripts/bootstrap-ubuntu.sh --check` asks Docker where its root actually is,
so after this it should report an SSD rather than a spinning disk.

### Worth knowing

- **Do not unplug it while Oracle is running.** Datafiles on a disk that
  disappears mid-write is how you corrupt a database. The cable being seated is
  the only thing standing between you and that.
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

**The image pull dies partway with `connection reset by peer`** — look at the
addresses in the error. If they are IPv6 (`2600:...`), the transfer is going out
over an IPv6 path that cannot carry it, usually a broken path-MTU. A 2GB pull
gives it plenty of opportunity to fail where ordinary browsing never would.

Retry once first, since CloudFront resets are also just transient and Docker
resumes from the layers it already has. If it keeps happening, tell glibc to
prefer IPv4 — the daemon uses the system resolver, so this covers it:

```bash
echo 'precedence ::ffff:0:0/96  100' | sudo tee -a /etc/gai.conf
sudo systemctl restart docker
```

That line is present but commented out in the stock `/etc/gai.conf`; appending
it turns IPv4 preference on. It changes resolution order only, and leaves IPv6
working for anything that needs it. `verify.sh` retries the pull five times with
backoff before giving up, so a flaky link usually gets through on its own.

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
