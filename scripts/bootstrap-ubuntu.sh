#!/usr/bin/env bash
# =============================================================================
# Prepares an Ubuntu server to run this project: Docker (for Oracle XE) and the
# .NET 8 SDK.
#
#   ./scripts/bootstrap-ubuntu.sh --check     preflight only, changes nothing
#   ./scripts/bootstrap-ubuntu.sh             preflight, then install what is missing
#
# Safe to re-run: everything already present is skipped.
#
# The preflight matters more than the install. Oracle XE has real requirements
# that fail in confusing ways when they are not met -- an arm64 box gives you a
# manifest error, and 1GB of RAM gives you a container that starts and then dies
# during database creation twenty minutes later.
# =============================================================================
set -euo pipefail

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

FAIL=0
WARN=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; WARN=$((WARN + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# -----------------------------------------------------------------------------
step "Preflight"

# --- architecture ------------------------------------------------------------
# There is no arm64 build of Oracle XE. Not "it is slow" -- it does not exist,
# and no amount of emulation flags conjures one. Worth catching in the first
# second rather than after a confusing pull failure.
ARCH="$(uname -m)"
if [[ "$ARCH" == "x86_64" ]]; then
    ok "architecture is x86_64"
else
    bad "architecture is $ARCH -- Oracle XE is published for x86_64 only."
    echo "         There is no arm64 image of gvenzl/oracle-xe. Options:"
    echo "           * run Oracle on an x86_64 host and point the API at it"
    echo "           * use an x86_64 VM or cloud instance for the database"
fi

# --- OS ----------------------------------------------------------------------
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    ok "OS is ${PRETTY_NAME:-unknown}"
    UBUNTU_CODENAME_RESOLVED="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "this script targets Ubuntu; ${ID:-unknown} may need different package steps"
    fi
else
    warn "cannot read /etc/os-release"
    UBUNTU_CODENAME_RESOLVED=""
fi

# --- memory ------------------------------------------------------------------
# Oracle XE wants 2GB. It will technically start with less and then fall over
# during database creation, which looks like a hang rather than an error.
MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
MEM_GB=$((MEM_KB / 1024 / 1024))
if (( MEM_KB >= 3800000 )); then
    ok "memory is ${MEM_GB}GB"
elif (( MEM_KB >= 1900000 )); then
    warn "memory is ${MEM_GB}GB -- Oracle XE will run, but leave little headroom for .NET"
else
    bad "memory is ${MEM_GB}GB -- Oracle XE needs about 2GB and will fail during setup"
fi

# --- swap --------------------------------------------------------------------
SWAP_KB="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
if (( MEM_KB < 3800000 && SWAP_KB < 1000000 )); then
    warn "no meaningful swap on a ${MEM_GB}GB box; consider adding 2GB before first boot"
fi

# --- disk --------------------------------------------------------------------
# The image is ~2GB and the created database another ~2GB.
DISK_AVAIL_GB="$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')"
if (( DISK_AVAIL_GB >= 15 )); then
    ok "disk free on / is ${DISK_AVAIL_GB}GB"
elif (( DISK_AVAIL_GB >= 8 )); then
    warn "disk free on / is ${DISK_AVAIL_GB}GB -- tight; image plus database is roughly 5GB"
else
    bad "disk free on / is ${DISK_AVAIL_GB}GB -- not enough for the image and database"
fi

# --- ports -------------------------------------------------------------------
port_busy() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH "sport = :$1" 2>/dev/null | grep -q . && return 0
    fi
    return 1
}

for entry in "1521:Oracle" "5080:API" "5090:UI"; do
    port="${entry%%:*}"
    label="${entry##*:}"
    if port_busy "$port"; then
        warn "port $port ($label) is already in use"
    else
        ok "port $port ($label) is free"
    fi
done

# --- privileges --------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    warn "running as root; the docker group step will be skipped"
    SUDO=""
elif sudo -n true 2>/dev/null; then
    ok "passwordless sudo available"
    SUDO="sudo"
elif command -v sudo >/dev/null 2>&1; then
    # Deliberately not calling `sudo -v` here: --check should never prompt for
    # a password just to tell you whether it could have asked for one.
    ok "sudo is present; it will prompt for a password during install"
    SUDO="sudo"
else
    bad "sudo is not installed, and installing packages needs it"
    SUDO="sudo"
fi

# -----------------------------------------------------------------------------
step "Tooling"

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "docker and the compose plugin are installed"
    HAVE_DOCKER=1
elif command -v docker >/dev/null 2>&1; then
    warn "docker is installed but the compose plugin is missing"
else
    warn "docker is not installed"
fi

HAVE_DOTNET=0
if command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | grep -q '^8\.'; then
    ok "the .NET 8 SDK is installed"
    HAVE_DOTNET=1
else
    warn ".NET 8 SDK is not installed"
fi

if (( FAIL > 0 )); then
    printf '\n\033[31m%d blocking problem(s).\033[0m Fix those before going further.\n' "$FAIL"
    exit 1
fi

if (( CHECK_ONLY == 1 )); then
    printf '\n\033[32mPreflight passed\033[0m with %d warning(s). Nothing was changed.\n' "$WARN"
    exit 0
fi

# -----------------------------------------------------------------------------
# Installs. Each block is a no-op when the tool is already there.
# -----------------------------------------------------------------------------

if (( HAVE_DOCKER == 0 )); then
    step "Installing Docker Engine from Docker's apt repository"

    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq ca-certificates curl gnupg

    $SUDO install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME_RESOLVED} stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    $SUDO systemctl enable --now docker

    if [[ $EUID -ne 0 ]]; then
        # Without this every docker command needs sudo, and the db scripts call
        # docker directly.
        $SUDO usermod -aG docker "$USER"
        NEEDS_RELOGIN=1
    fi

    ok "docker installed"
fi

if (( HAVE_DOTNET == 0 )); then
    step "Installing the .NET 8 SDK"

    # Ubuntu 22.04 and later carry dotnet-sdk-8.0 in the main archive, which is
    # the least surprising source. Fall back to Microsoft's feed, then to the
    # official install script for anything older.
    if $SUDO apt-get install -y -qq dotnet-sdk-8.0 2>/dev/null; then
        ok "installed dotnet-sdk-8.0 from the Ubuntu archive"
    else
        warn "not in the Ubuntu archive; trying Microsoft's package feed"

        VERSION_ID_RESOLVED="${VERSION_ID:-22.04}"
        TMP_DEB="$(mktemp --suffix=.deb)"
        if curl -fsSL -o "$TMP_DEB" \
            "https://packages.microsoft.com/config/ubuntu/${VERSION_ID_RESOLVED}/packages-microsoft-prod.deb"
        then
            $SUDO dpkg -i "$TMP_DEB" >/dev/null
            rm -f "$TMP_DEB"
            $SUDO apt-get update -qq
            $SUDO apt-get install -y -qq dotnet-sdk-8.0
            ok "installed dotnet-sdk-8.0 from packages.microsoft.com"
        else
            rm -f "$TMP_DEB"
            warn "Microsoft's feed is unreachable; using the official install script"

            curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
            chmod +x /tmp/dotnet-install.sh
            /tmp/dotnet-install.sh --channel 8.0 --install-dir "$HOME/.dotnet"

            # A user-local install is not on PATH until told about it.
            if ! grep -q 'HOME/.dotnet' "$HOME/.bashrc" 2>/dev/null; then
                {
                    echo ''
                    echo '# .NET SDK (user-local install)'
                    echo 'export DOTNET_ROOT="$HOME/.dotnet"'
                    echo 'export PATH="$PATH:$HOME/.dotnet:$HOME/.dotnet/tools"'
                } >> "$HOME/.bashrc"
            fi
            NEEDS_RELOGIN=1
            ok "installed the .NET 8 SDK to ~/.dotnet"
        fi
    fi
fi

# -----------------------------------------------------------------------------
step "Done"

if [[ -n "${NEEDS_RELOGIN:-}" ]]; then
    cat <<'EOF'

  Log out and back in before continuing -- the docker group and the PATH
  change only apply to a new shell. Or, for this shell only:

      newgrp docker
      source ~/.bashrc
EOF
fi

cat <<'EOF'

  Next:

      cd db
      docker compose up -d      # first boot creates the database, 2-4 minutes
      ./install.sh
      ./run_tests.sh

  Or all of it at once, including the .NET build:

      ./scripts/verify.sh
EOF
