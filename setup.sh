#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — ONE command that builds the complete development VM.
#
#   ./setup.sh [--yes]
#
# Runs in order, and is safe to re-run:
#   1/4  host setup      sudo ./1-setup-host.sh   (skipped if already done)
#   2/4  the VM          sudo ./2-create-vm.sh    (or --adopt if it exists)
#   3/4  guest reboot    only if its kernel was upgraded during provisioning
#   4/4  browser access  ./dsh-web.sh start
#
# The only thing it cannot do for you is enter your DSH API key: add that in the
# web UI the first time (DSH stores it in the guest and reuses it after that).
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

ASSUME_YES="false"
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES="true" ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done
export ASSUME_YES

[[ ${EUID} -ne 0 ]] || die "Run this as your normal user - it calls sudo itself. Do not run it with sudo."

# Two concurrent setups could run virt-install against the same domain at once.
acquire_lock "devvm-setup-${VM_NAME}"

SUDO_ARGS=()
[[ "$ASSUME_YES" == "true" ]] && SUDO_ARGS+=(--yes)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Is the host already in a usable state? Checked without touching libvirt, so
# it works before the 'libvirt' group applies to this session.
host_ready() {
  [[ -e /dev/kvm ]] || return 1
  command -v virt-install >/dev/null 2>&1 || return 1
  command -v qemu-img     >/dev/null 2>&1 || return 1
  systemctl is-enabled libvirtd.socket >/dev/null 2>&1 || return 1
  [[ -d /sys/class/net/virbr0 ]] || return 1
  return 0
}

# Root can always talk to libvirt, so this works regardless of group membership.
domain_exists_privileged() {
  sudo virsh -c qemu:///system dominfo "$VM_NAME" >/dev/null 2>&1
}

# The address 2-create-vm.sh settled on, read back from the SSH alias it wrote.
guest_ip() {
  local ip=""
  ip="$(awk -v m="# >>> ${VM_NAME} " '
        index($0, m) == 1 { f = 1; next }
        f && /^[[:space:]]*HostName[[:space:]]/ { print $2; exit }
        f && /^# <<</ { exit }
      ' "${HOME}/.ssh/config" 2>/dev/null || true)"
  printf '%s' "${ip:-$VM_IP}"
}

# True while the running kernel's module tree is gone, i.e. a kernel upgrade is
# pending a reboot. Module-dependent services (Docker) cannot start until then.
guest_needs_reboot() {
  local ip="$1"
  ssh_opts_for "$(vm_ssh_key)"
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@${ip}" \
      '[ ! -d "/lib/modules/$(uname -r)" ]' >/dev/null 2>&1
}

# Cache sudo credentials once so each sub-script does not prompt again.
sudo -v || die "sudo is required for the host-side steps."

# ---------------------------------------------------------------------------
# 1/4 — host
# ---------------------------------------------------------------------------
msg "Step 1/4 - host setup"
if host_ready; then
  ok "Host already configured (KVM, libvirt, NAT network all present)"
else
  if ! sudo "$HERE/1-setup-host.sh" "${SUDO_ARGS[@]}"; then
    warn "Host setup did not complete."
    warn "If it told you to reboot - a kernel upgrade removed the modules for the"
    warn "kernel you are running - reboot and run this script again. It resumes"
    warn "from wherever it stopped."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 2/4 — the VM
# ---------------------------------------------------------------------------
msg "Step 2/4 - the virtual machine"
if domain_exists_privileged; then
  ok "Domain '${VM_NAME}' already exists - finishing its setup rather than rebuilding"
  sudo "$HERE/2-create-vm.sh" --adopt
else
  if ! sudo "$HERE/2-create-vm.sh" "${SUDO_ARGS[@]}"; then
    warn "VM creation did not finish. Re-running this script resumes safely."
    exit 1
  fi
fi

IP="$(guest_ip)"
ok "Guest address: ${IP}"

# ---------------------------------------------------------------------------
# 3/4 — reboot the guest if provisioning upgraded its kernel
# ---------------------------------------------------------------------------
msg "Step 3/4 - checking whether the guest needs a reboot"
if guest_needs_reboot "$IP"; then
  msg "The guest upgraded its kernel during provisioning; rebooting so modules load"
  ssh_opts_for "$(vm_ssh_key)"
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@${IP}" 'sudo reboot' >/dev/null 2>&1 || true
  if wait_for_ssh "$IP" "$(vm_ssh_key)" 300; then
    ok "Guest rebooted and is back"
  else
    warn "The guest did not come back within 5 minutes; continuing anyway."
  fi
else
  ok "No reboot needed"
fi

# ---------------------------------------------------------------------------
# 4/4 — browser access
# ---------------------------------------------------------------------------
msg "Step 4/4 - starting the DSH web UI"
if id -nG 2>/dev/null | tr ' ' '\n' | grep -x libvirt >/dev/null; then
  "$HERE/dsh-web.sh" start
elif command -v sg >/dev/null 2>&1; then
  # Group membership only applies to new sessions. `sg` adopts it immediately,
  # which is what removes the "log out and back in" step from this flow.
  if ! sg libvirt -c "'${HERE}/dsh-web.sh' start"; then
    warn "Could not start the web UI with the 'libvirt' group."
    warn "Log out and back in, then run:  ${HERE}/dsh-web.sh start"
    exit 1
  fi
else
  warn "The 'libvirt' group is not active in this session and 'sg' is missing."
  warn "Log out and back in, then run:  ${HERE}/dsh-web.sh start"
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
msg "Verifying the result"
if ! "$HERE/doctor.sh"; then
  warn "doctor.sh reported problems (see above)."
  warn "Run  ${HERE}/doctor.sh --fix  to repair what can be repaired."
fi

# ---------------------------------------------------------------------------
echo
ok "Setup complete."
echo "One manual step remains: add your DSH API key in the web UI the first time."
echo "DSH stores it in the guest, so you only do this once per VM."
