#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 1-setup-host.sh — install and configure the KVM/QEMU + libvirt stack on
#                   the CachyOS host so it can run virtual machines.
#
# Run with:  sudo ./1-setup-host.sh [--yes]
#
# Follows the official CachyOS QEMU/VMM guidance:
#   https://wiki.cachyos.org/virtualization/qemu_and_vmm_setup
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

# --- arguments -------------------------------------------------------------
ASSUME_YES="false"
for arg in "$@"; do
  case "$arg" in
    -y|--yes)  ASSUME_YES="true" ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "Unknown option: $arg" ;;
  esac
done

# --- must be root ----------------------------------------------------------
require_root

# The human who invoked sudo owns the SSH keys and needs the group membership.
TARGET_USER="$(invoking_user)"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  die "Could not determine the invoking user. Run via 'sudo ./1-setup-host.sh' from your normal account."
fi
TARGET_HOME="$(home_of "${TARGET_USER}")"
[[ -n "${TARGET_HOME}" ]] || die "Could not resolve home directory for user '${TARGET_USER}'."
msg "Configuring the VM host for user ${TARGET_USER} (${TARGET_HOME})"

# --- sanity checks ---------------------------------------------------------
msg "Checking distribution"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *cachyos*|*arch*) ok "Detected ${PRETTY_NAME:-unknown}" ;;
    *) warn "This does not look like CachyOS/Arch (ID=${ID:-?}). Continuing anyway." ;;
  esac
else
  warn "/etc/os-release is missing; cannot verify the distribution."
fi

msg "Checking CPU virtualisation support"
if grep -qE '(^flags.*\b(vmx|svm)\b)' /proc/cpuinfo; then
  VENDOR="$(grep -m1 -oE '\b(vmx|svm)\b' /proc/cpuinfo)"
  if [[ "${VENDOR}" == "svm" ]]; then ok "AMD-V (svm) present"; else ok "Intel VT-x (vmx) present"; fi
else
  die "CPU virtualisation is not exposed. Enable 'SVM Mode'/'AMD-V' (or VT-x) in your BIOS/UEFI firmware, then re-run."
fi

if command -v systemd-detect-virt >/dev/null 2>&1; then
  DETECTED_VIRT="$(systemd-detect-virt || true)"
  if [[ -n "${DETECTED_VIRT}" && "${DETECTED_VIRT}" != "none" ]]; then
    warn "systemd-detect-virt reports '${DETECTED_VIRT}'. If this host is itself a VM, nested virtualisation must be enabled by the outer hypervisor."
  fi
fi

# A running kernel whose module tree has been replaced (the kernel package was
# upgraded, but the machine has not been rebooted) cannot load ANY new module.
# That surfaces much later as a confusing, unrelated-looking error:
#   virsh net-start default
#   error: Unable to create bridge virbr0: Package not installed
# because 'bridge' cannot be loaded (the kernel returns ENOPKG). Catch it now.
msg "Checking that the running kernel still has its modules"
RUNNING_KERNEL="$(uname -r)"
if [[ -d "/lib/modules/${RUNNING_KERNEL}" ]]; then
  ok "Module tree for ${RUNNING_KERNEL} is present"
else
  warn "The running kernel is ${RUNNING_KERNEL}, but /lib/modules/${RUNNING_KERNEL}"
  warn "does not exist. A kernel upgrade has removed the modules for the kernel"
  warn "you are still running, so no new kernel module can be loaded."
  warn "This breaks libvirt's NAT network with:"
  warn "    Unable to create bridge virbr0: Package not installed"
  warn "Module trees currently installed:"
  ls -1 /lib/modules 2>/dev/null | sed 's/^/    /' >&2 || true
  die "Reboot into the new kernel, then re-run this script."
fi

# --- packages --------------------------------------------------------------
# qemu-full      : QEMU with KVM acceleration, incl. qemu-img
# virt-manager   : graphical manager
# virt-install   : CLI VM creator (pulls libisoburn/xorriso + libosinfo)
# libvirt        : daemon/API; its optdep dnsmasq provides DHCP for the NAT net
# edk2-ovmf      : UEFI firmware for the guest
# swtpm          : software TPM (not needed for Arch guests, kept for Windows)
# cloud-image-utils : cloud-localds, used to build the cloud-init seed ISO
PKGS=(
  qemu-full
  virt-manager
  virt-install
  libvirt
  edk2-ovmf
  dnsmasq
  swtpm
  libosinfo
  cloud-image-utils
  openbsd-netcat
)

# Arch is a rolling release: installing new packages on top of an out-of-date
# system is a "partial upgrade", which Arch does not support. It fails with
# errors like:
#   installing gstreamer (1.28.7-2.1) breaks dependency 'gstreamer=1.28.7-1'
#   required by gst-libav
# because the new packages pull in a newer gstreamer than the installed gst-*
# plugins were built against. Upgrade the whole system first.
# Turn a cryptic pacman "breaks dependency" error into an actionable fix.
# A common cause on a rolling release: an orphaned package left behind by a
# removed stack (often a lib32-* leftover) pins an exact version of a package
# that is waiting to be upgraded, so 'pacman -Syu' can never complete.
diagnose_dependency_blockers() {
  local orphan deps dep base upgradable found
  upgradable="$(pacman -Qu 2>/dev/null | awk '{print $1}')"
  found=""

  while read -r orphan; do
    [[ -n "$orphan" ]] || continue
    deps="$(pacman -Qi "$orphan" 2>/dev/null | sed -n 's/^Depends On *: *//p')"
    for dep in $deps; do
      case "$dep" in
        *=*)
          base="${dep%%=*}"
          if grep -qxF "$base" <<<"$upgradable"; then
            found+="${orphan} (pins ${dep})"$'\n'
          fi
          ;;
      esac
    done
  done < <(pacman -Qtdq 2>/dev/null)

  if [[ -n "$found" ]]; then
    warn "Diagnosis: these installed packages are ORPHANS - nothing requires them -"
    warn "but each pins an exact version of a package that is waiting to be upgraded,"
    warn "which blocks the upgrade permanently:"
    while read -r line; do
      [[ -n "$line" ]] && warn "    ${line}"
    done <<<"$found"
    warn "Remove them (pacman already reports nothing depends on them), then re-run:"
    warn "    sudo pacman -R $(awk '{print $1}' <<<"$found" | sort -u | xargs)"
  else
    warn "Could not attribute this to an orphaned package."
    warn "A temporary repository desync (e.g. a multilib package awaiting a rebuild)"
    warn "usually resolves within a few hours. Re-run 'sudo pacman -Syu' later."
  fi
}

UPGRADABLE="$(pacman -Qu 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]' || true)"
UPGRADABLE="${UPGRADABLE:-0}"
if (( UPGRADABLE > 0 )); then
  warn "Your system has ${UPGRADABLE} pending package upgrade(s)."
  warn "Installing new packages now would create a partial upgrade, which Arch"
  warn "does not support - it fails with 'breaks dependency' errors."
  if ! confirm "Run a full system upgrade now (pacman -Syu) and continue?"; then
    die "Aborted. Run 'sudo pacman -Syu' yourself, then re-run this script."
  fi
  msg "Upgrading the system (pacman -Syu)"
  if ! pacman -Syu --noconfirm; then
    diagnose_dependency_blockers
    die "The system upgrade failed. Resolve it, then re-run this script."
  fi
  ok "System upgraded"
else
  ok "No pending upgrades; the package databases are in sync"
fi

msg "Installing packages: ${PKGS[*]}"
if ! pacman -S --needed --noconfirm "${PKGS[@]}"; then
  warn "The package transaction failed."
  diagnose_dependency_blockers
  die "Could not install the virtualisation packages."
fi
ok "Packages installed"

# `iptables` on current Arch already provides the nft backend that libvirt's
# NAT networking expects; make sure something provides it.
if command -v iptables >/dev/null 2>&1; then
  ok "iptables present ($(iptables --version | sed -n 1p))"
else
  warn "No iptables binary found. libvirt's default NAT network needs one."
fi

# --- libvirt network backend ----------------------------------------------
# CachyOS ships libvirt configured for nftables; the project's own guidance is
# to force the iptables backend so NAT rules are applied correctly.
msg "Configuring libvirt firewall backend"
install -d -m 0755 /etc/libvirt
touch /etc/libvirt/network.conf
if grep -qE '^\s*firewall_backend' /etc/libvirt/network.conf; then
  ok "firewall_backend already set"
else
  printf 'firewall_backend = "iptables"\n' >> /etc/libvirt/network.conf
  ok 'Added firewall_backend = "iptables" to /etc/libvirt/network.conf'
fi

# --- group membership ------------------------------------------------------
msg "Adding ${TARGET_USER} to the libvirt group"
usermod -aG libvirt "${TARGET_USER}"
# Some libvirt builds point /dev/kvm at group kvm.
if getent group kvm >/dev/null 2>&1; then
  usermod -aG kvm "${TARGET_USER}"
  ok "Added ${TARGET_USER} to libvirt and kvm groups"
else
  ok "Added ${TARGET_USER} to libvirt group"
fi

# --- services --------------------------------------------------------------
msg "Enabling libvirt services"
systemctl enable --now libvirtd.socket
systemctl enable --now libvirtd.service
ok "libvirtd.socket and libvirtd.service enabled"

# Give the daemon a moment to come up on first start.
for _ in $(seq 1 20); do
  virsh -c qemu:///system version >/dev/null 2>&1 && break
  sleep 0.5
done
virsh -c qemu:///system version >/dev/null 2>&1 || die "libvirtd is not responding. Check: systemctl status libvirtd.service"
ok "libvirtd responds (running hypervisor: $(virsh -c qemu:///system version | awk -F': ' '/Running hypervisor/{print $2}'))"

# --- default NAT network ---------------------------------------------------
msg "Starting the '${VM_NETWORK}' network"
virsh net-autostart "${VM_NETWORK}" >/dev/null
if virsh net-info "${VM_NETWORK}" | awk '/^Active/{print $2}' | grep yes >/dev/null; then
  ok "'${VM_NETWORK}' already active"
else
  if ! virsh net-start "${VM_NETWORK}"; then
    warn "Could not start the '${VM_NETWORK}' network."
    # The most common cause is a missing kernel module, which libvirt reports
    # as the easily-misread 'Package not installed' (kernel errno ENOPKG).
    if ! lsmod | grep '^bridge' >/dev/null; then
      warn "The 'bridge' kernel module is not loaded."
      if [[ -d "/lib/modules/$(uname -r)" ]]; then
        warn "Try:  sudo modprobe bridge  &&  sudo virsh net-start ${VM_NETWORK}"
      else
        warn "Your running kernel is $(uname -r) but /lib/modules/$(uname -r) is gone,"
        warn "so no module can be loaded. A kernel upgrade is pending a reboot."
        warn "Reboot, then re-run this script."
      fi
    fi
    die "The '${VM_NETWORK}' network did not start."
  fi
  ok "'${VM_NETWORK}' started"
fi

# --- stable DHCP lease -----------------------------------------------------
# Pin the VM's MAC to a fixed address so SSH config stays valid across reboots.
msg "Reserving ${VM_IP} for ${VM_MAC} in the '${VM_NETWORK}' network"
if virsh net-dumpxml "${VM_NETWORK}" | grep "${VM_MAC}" >/dev/null; then
  ok "DHCP reservation already present"
else
  if virsh net-update "${VM_NETWORK}" add ip-dhcp-host \
       "<host mac='${VM_MAC}' name='${VM_NAME}' ip='${VM_IP}'/>" --live --config >/dev/null 2>&1; then
    ok "Reserved ${VM_IP} for ${VM_NAME}"
  else
    warn "Could not add the DHCP reservation. The VM will still get an address by DHCP;"
    warn "3-vmctl.sh will discover it automatically at runtime."
  fi
fi

# --- host firewall ---------------------------------------------------------
# If ufw is in use, allow the VM subnet to route outbound through the host.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -i '^Status: active' >/dev/null; then
  msg "ufw is active; allowing routing from the VM subnet"
  if ufw route allow from 192.168.122.0/24 >/dev/null 2>&1; then
    ok "ufw route rule added"
  else
    warn "Could not add a ufw route rule automatically. If the VM has no internet, run:"
    warn "  sudo ufw route allow from 192.168.122.0/24"
  fi
fi

# --- final report ----------------------------------------------------------
echo
ok "Host setup complete."
echo
echo "Next steps:"
echo "  1. Log out and back in (or run 'newgrp libvirt') so the libvirt group applies."
echo "  2. Create the VM:   sudo ${HERE}/2-create-vm.sh"
echo
echo "Sanity checks:"
echo "  ls -l /dev/kvm                                  # hardware acceleration available"
echo "  virsh -c qemu:///system net-info ${VM_NETWORK}              # NAT network active"
echo "  virsh -c qemu:///system capabilities | grep -A2 '<domain>'  # host virtualisation type"
