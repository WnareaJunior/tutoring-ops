#!/usr/bin/env bash
# =============================================================================
# A small Azure VM to host Oracle XE (x86_64), paid for by the hour. Used
# here as the deployed system's database host; also works as a disposable
# dev server for anyone without x86_64 hardware.
#
#   ./scripts/dev-vm.sh create    one-time: resource group, VM, lockdown, auto-shutdown
#   ./scripts/dev-vm.sh start     boot it and wait for SSH
#   ./scripts/dev-vm.sh stop      deallocate -- compute billing stops, AND the
#                                 deployed site loses its database (see below)
#   ./scripts/dev-vm.sh status    running or deallocated, and what it costs
#   ./scripts/dev-vm.sh ip        the VM's public IP
#   ./scripts/dev-vm.sh allow-me  re-point the SSH firewall rule at this laptop's
#                                 current public IP (run after your home IP changes)
#   ./scripts/dev-vm.sh always-on remove the nightly auto-shutdown
#   ./scripts/dev-vm.sh nightly   restore the nightly 07:00 UTC auto-shutdown
#   ./scripts/dev-vm.sh delete    remove everything, including the disk
#
# If the deployed site's database lives on this VM, `stop` takes the site
# down with it; `always-on` disables the nightly auto-shutdown for exactly
# that situation.
#
# Costs while this exists (northcentralus, Aug 2026 ballpark):
#   running      ~$0.06/hr  (Standard_B2as_v2, 2 vCPU x86_64, 8GB)
#   deallocated  ~$6/mo     (30GB Premium SSD + static IP) -- pennies for a week
#
# The static public IP is deliberate: it survives stop/start, so ~/.ssh/config
# and remote.sh never need re-pointing.
# =============================================================================
set -euo pipefail

RG="tutoring-dev-vm"
VM="tutoring-dev"
# The Azure for Students subscription is policy-limited to five regions
# (northcentralus, canadacentral, norwayeast, francecentral, westus) and
# offers no plain B2s anywhere; B2as_v2 is the cheapest fit that exists here.
LOCATION="northcentralus"
SIZE="Standard_B2as_v2"
IMAGE="Canonical:ubuntu-24_04-lts:server:latest"
ADMIN="${VM_ADMIN:-$USER}"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"

# -4: this network hands out IPv6 by default, but the NSG rule and the VM's
# public IP are IPv4, so the laptop reaches it over IPv4.
my_ip() { curl -4 -fsS https://ifconfig.me; }

case "${1:-}" in
    create)
        echo "Creating resource group $RG in $LOCATION..."
        az group create --name "$RG" --location "$LOCATION" --output none

        echo "Creating $VM ($SIZE, Ubuntu 24.04, SSH from $(my_ip) only)..."
        az vm create \
            --resource-group "$RG" \
            --name "$VM" \
            --image "$IMAGE" \
            --size "$SIZE" \
            --admin-username "$ADMIN" \
            --ssh-key-values "$SSH_KEY" \
            --public-ip-sku Standard \
            --public-ip-address-allocation static \
            --storage-sku Premium_LRS \
            --nsg-rule NONE \
            --output none

        # SSH only, and only from this laptop's current public IP.
        az network nsg rule create \
            --resource-group "$RG" \
            --nsg-name "${VM}NSG" \
            --name allow-ssh-home \
            --priority 100 \
            --access Allow --protocol Tcp --direction Inbound \
            --source-address-prefixes "$(my_ip)/32" \
            --destination-port-ranges 22 \
            --output none

        # Backstop for a forgotten VM: hard power-off at 07:00 UTC nightly.
        az vm auto-shutdown \
            --resource-group "$RG" \
            --name "$VM" \
            --time 0700 \
            --output none

        IP="$(az vm show -d --resource-group "$RG" --name "$VM" --query publicIps -o tsv)"
        echo
        echo "VM is up at $IP"
        echo "Add an ~/.ssh/config entry for that IP, set TUTORING_REMOTE, then:"
        echo "  ./scripts/remote.sh run './scripts/bootstrap-ubuntu.sh'"
        ;;

    start)
        az vm start --resource-group "$RG" --name "$VM" --output none
        IP="$(az vm show -d --resource-group "$RG" --name "$VM" --query publicIps -o tsv)"
        printf 'Started. Waiting for SSH at %s' "$IP"
        for _ in $(seq 1 30); do
            if nc -z -G2 "$IP" 22 2>/dev/null; then echo " -- ready."; exit 0; fi
            printf '.'; sleep 2
        done
        echo " -- SSH not answering after 60s; check 'status'." >&2
        exit 1
        ;;

    stop)
        echo "Deallocating (compute billing stops)..."
        az vm deallocate --resource-group "$RG" --name "$VM" --output none
        echo "Stopped."
        ;;

    status)
        STATE="$(az vm show -d --resource-group "$RG" --name "$VM" --query powerState -o tsv)"
        echo "$VM: $STATE"
        case "$STATE" in
            *running*)     echo "billing ~\$0.06/hr -- the deployed demo depends on this VM; 'stop' takes the site down" ;;
            *deallocated*) echo "compute billing stopped; only disk + IP (~\$6/mo)" ;;
        esac
        ;;

    ip)
        az vm show -d --resource-group "$RG" --name "$VM" --query publicIps -o tsv
        ;;

    allow-me)
        az network nsg rule update \
            --resource-group "$RG" \
            --nsg-name "${VM}NSG" \
            --name allow-ssh-home \
            --source-address-prefixes "$(my_ip)/32" \
            --output none
        echo "SSH now allowed from $(my_ip) only."
        ;;

    always-on)
        az vm auto-shutdown --resource-group "$RG" --name "$VM" --off --output none
        echo "Nightly auto-shutdown removed. The VM (and the demo) stay up until 'stop'."
        ;;

    nightly)
        az vm auto-shutdown --resource-group "$RG" --name "$VM" --time 0700 --output none
        echo "Nightly 07:00 UTC auto-shutdown restored."
        ;;

    delete)
        echo "This deletes the VM, its disk, and everything in $RG."
        az group delete --name "$RG" --yes
        ;;

    *)
        sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
