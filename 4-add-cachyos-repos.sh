#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 4-add-cachyos-repos.sh — OPTIONAL.
#
# Arch Linux publishes official cloud images; CachyOS does not. So the VM is
# built from the Arch cloud image and, if you want the CachyOS-optimised
# packages (x86-64-v3/v4, PGO/LTO/BOLT rebuilds), this script layers the
# official CachyOS repositories on top of it inside the guest.
#
# It runs the vendor's own script, interactively, over SSH:
#   https://wiki.cachyos.org/features/optimized_repos/
#
# Run as your normal user:  ./4-add-cachyos-repos.sh
#
# This is a large, one-way migration (~1-2 GB of packages). A stock Arch VM is
# already a perfectly good development machine; skip this unless you want the
# CachyOS builds or the CachyOS kernel.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

SSH_KEY="$(vm_ssh_key)"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

# --- locate the guest ------------------------------------------------------
if ! virsh_system version >/dev/null 2>&1; then
  die "Cannot talk to libvirtd as '$(id -un)'. Log out and back in so the 'libvirt' group applies."
fi
domain_exists || die "No domain named '${VM_NAME}'. Create it with: sudo ${HERE}/2-create-vm.sh"

IP="$(vm_ip)"
[[ -n "$IP" ]] || die "Could not determine the guest address. Is the VM running?  ${HERE}/3-vmctl.sh status"

ssh_opts_for "$SSH_KEY"

# --- is it already done? ---------------------------------------------------
if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@${IP}" \
     "grep -q '^\[cachyos' /etc/pacman.conf" >/dev/null 2>&1; then
  ok "The CachyOS repositories are already configured in the guest. Nothing to do."
  exit 0
fi

if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@${IP}" \
      "grep -q '^ID=arch' /etc/os-release" >/dev/null 2>&1; then
  warn "The guest does not look like a stock Arch system."
  warn "This script is only meant to run against the image that 2-create-vm.sh built."
fi

# --- confirm ---------------------------------------------------------------
cat <<EOF
About to convert the guest at ${IP} from stock Arch to CachyOS repositories:

  * downloads and runs the vendor script from mirror.cachyos.org
  * replaces many core/extra packages with the x86-64-v3/v4 rebuilds
  * is interactive - it will ask about installing the CachyOS kernel
  * takes a while and roughly 1-2 GB of packages

Your file system and dotfiles are not touched; this only changes packages.
EOF

read -r -p "Continue? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# --- run the vendor migration over an interactive SSH session --------------
msg "Connecting to ${IP} and running the CachyOS repository setup"
warn "Follow the prompts. The vendor script may ask about the CachyOS kernel."

ssh -t "${SSH_OPTS[@]}" "${VM_USER}@${IP}" bash -s <<'REMOTE'
set -euo pipefail

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

echo "==> Downloading the CachyOS repository helper"
cd "$workdir"
curl -fLO https://mirror.cachyos.org/cachyos-repo.tar.xz

echo "==> Extracting"
tar xf cachyos-repo.tar.xz

echo "==> Running the vendor script (it needs sudo)"
cd cachyos-repo
sudo ./cachyos-repo.sh

echo
echo "==> Repositories now configured:"
pacman-conf --repo-list 2>/dev/null || grep '^\[' /etc/pacman.conf

echo
echo "==> A full upgrade is recommended now that the mirrors changed:"
echo "      sudo pacman -Syu"
REMOTE

ok "Done. Reconnect and run 'sudo pacman -Syu' inside the guest."
echo
echo "Verify the architecture level in use:"
echo "  ssh ${VM_USER}@${IP} 'pacman-conf --repo-list'"
echo "  ssh ${VM_USER}@${IP} '/lib/ld-linux-x86-64.so.2 --help | grep supported'"
