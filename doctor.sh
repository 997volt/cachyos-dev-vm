#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# doctor.sh — check the whole setup and repair what can be repaired.
#
#   ./doctor.sh            report only (safe, changes nothing)
#   ./doctor.sh --fix      attempt repairs, then re-check
#   ./doctor.sh --quiet    only print warnings and failures
#
# Checks run top to bottom: host kernel/modules, libvirt networking, the domain,
# the guest (provisioning, Docker, DSH), and browser access. Every check here
# exists because it was a real failure while building this: a kernel upgrade that
# removed the running kernel's modules, a partial-upgrade dependency conflict, an
# orphaned package pinning a version, a provisioning script that finished with a
# failed service, and DSH installed but not reachable.
#
# Exit status: 0 if nothing failed, 1 otherwise.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

FIX="false"
QUIET="false"
for arg in "$@"; do
  case "$arg" in
    --fix)   FIX="true" ;;
    --quiet) QUIET="true" ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done

# --- result tally ----------------------------------------------------------
# Only serialise when we might actually change something.
if [[ "$FIX" == "true" ]]; then
  acquire_lock "devvm-doctor-${VM_NAME}"
fi

N_PASS=0; N_WARN=0; N_FAIL=0; N_FIXED=0

section() { [[ "$QUIET" == "true" ]] || { echo; printf '%s== %s%s\n' "$C_BLUE" "$*" "$C_RESET"; }; }
ok()   { N_PASS=$((N_PASS + 1));  [[ "$QUIET" == "true" ]] || printf '  %sPASS %s %s\n'  "$C_GRN" "$C_RESET" "$*"; }
soft() { N_WARN=$((N_WARN + 1));  printf '  %sWARN %s %s\n'  "$C_YEL" "$C_RESET" "$*"; }
bad()  { N_FAIL=$((N_FAIL + 1));  printf '  %sFAIL %s %s\n'  "$C_RED" "$C_RESET" "$*"; }
note() { printf '       %s\n' "$*"; }
fixed(){ N_FIXED=$((N_FIXED + 1)); printf '  %sFIX  %s %s\n' "$C_GRN" "$C_RESET" "$*"; }

# A check is: <predicate> then either ok, or (with --fix) a repair, or bad.
# try_fix <description> <command...>  -> 0 if the command succeeded
# On failure the command's own message is shown: swallowing it once cost real
# debugging time, because "network not active" + a failed repair is otherwise
# indistinguishable from a false alarm.
try_fix() {
  local desc="$1"; shift
  [[ "$FIX" == "true" ]] || return 1
  local out=""
  if out="$("$@" 2>&1)"; then fixed "$desc"; return 0; fi
  if [[ -n "$out" ]]; then
    printf '       (repair failed: %s)\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  fi
  return 1
}

# --- privilege / libvirt path ----------------------------------------------
# Prefer working without sudo at all: if you are in the 'libvirt' group, plain
# virsh is enough. Only ask for a password when we might actually change
# something (--fix) - a read-only check should never prompt.
SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then
    SUDO="sudo"
  elif [[ "$FIX" == "true" && -t 0 ]] && sudo -v 2>/dev/null; then
    SUDO="sudo"
  fi
fi

VIRSH_CMD=(virsh -c qemu:///system)
if ! "${VIRSH_CMD[@]}" version >/dev/null 2>&1; then
  if [[ -n "$SUDO" ]]; then VIRSH_CMD=("$SUDO" virsh -c qemu:///system); fi
fi
vs() { "${VIRSH_CMD[@]}" "$@" 2>/dev/null; }

RUNNING_KERNEL="$(uname -r)"

# Resolve the guest address the same way setup.sh does.
guest_ip() {
  local ip=""
  ip="$(awk -v m="# >>> ${VM_NAME} " '
        index($0, m) == 1 { f = 1; next }
        f && /^[[:space:]]*HostName[[:space:]]/ { print $2; exit }
        f && /^# <<</ { exit }
      ' "${HOME}/.ssh/config" 2>/dev/null || true)"
  printf '%s' "${ip:-$VM_IP}"
}

# Run a command inside the guest. Returns non-zero if the guest is unreachable.

gssh() {
  ssh_opts_for "$(vm_ssh_key)"
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@${GUEST_IP}" "$@" 2>/dev/null
}

# Same, but with root inside the guest (the dev account has passwordless sudo).
gssh_sudo() {
  ssh_opts_for "$(vm_ssh_key)"
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@${GUEST_IP}" "sudo $*" 2>/dev/null
}

# ===========================================================================
# 1. Host: kernel, virtualisation, packages
# ===========================================================================
section "Host"

# The failure that hit twice: an upgraded kernel whose module tree was deleted,
# so no new module (bridge, nf_tables) can load. Only a reboot fixes it.
if [[ -d "/lib/modules/${RUNNING_KERNEL}" ]]; then
  ok "Running kernel ${RUNNING_KERNEL} has its module tree"
else
  bad "Kernel ${RUNNING_KERNEL} has no /lib/modules/${RUNNING_KERNEL}"
  note "No kernel module can be loaded until you reboot. This is what makes"
  note "libvirt fail with 'Unable to create bridge virbr0: Package not installed'."
  note "Installed module trees: $(ls /lib/modules 2>/dev/null | tr '\n' ' ')"
  note "ACTION: reboot, then re-run."
fi

if grep -qE '(^flags.*\b(vmx|svm)\b)' /proc/cpuinfo; then
  ok "CPU exposes virtualisation ($(grep -m1 -oE '\b(vmx|svm)\b' /proc/cpuinfo))"
else
  bad "CPU virtualisation not exposed"
  note "ACTION: enable SVM/AMD-V (or VT-x) in BIOS/UEFI."
fi

if [[ -e /dev/kvm ]]; then
  ok "/dev/kvm present"
else
  if try_fix "loaded KVM modules" ${SUDO:+$SUDO} modprobe kvm_amd && [[ -e /dev/kvm ]]; then :
  elif try_fix "loaded KVM modules" ${SUDO:+$SUDO} modprobe kvm_intel && [[ -e /dev/kvm ]]; then :
  else
    bad "/dev/kvm missing"
    note "Inside a container/sandbox this is expected even when the host has it"
    note "(a domain with type='kvm' proves the host's /dev/kvm works)."
    note "ACTION: enable virtualisation in firmware, and reboot if the kernel changed."
  fi
fi

MISSING=()
for t in virsh virt-install qemu-img cloud-localds; do
  command -v "$t" >/dev/null 2>&1 || MISSING+=("$t")
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
  ok "Host tooling present (virsh, virt-install, qemu-img, cloud-localds)"
else
  if try_fix "installed the virtualisation packages" \
       ${SUDO:+$SUDO} "$HERE/1-setup-host.sh" --yes; then :
  else
    bad "Missing host tools: ${MISSING[*]}"
    note "ACTION: sudo ${HERE}/1-setup-host.sh"
  fi
fi

# A partial upgrade leaves pacman unable to install anything.
ORPHAN_BLOCKERS="$(pacman -Qtdq 2>/dev/null | while read -r p; do
  deps="$(pacman -Qi "$p" 2>/dev/null | sed -n 's/^Depends On *: *//p')"
  for d in $deps; do
    case "$d" in *=*)
      base="${d%%=*}"
      pacman -Qu 2>/dev/null | awk '{print $1}' | grep -x "$base" >/dev/null && echo "$p" ;;
    esac
  done
done | sort -u)"
if [[ -z "$ORPHAN_BLOCKERS" ]]; then
  ok "No orphaned package is pinning a pending upgrade"
else
  soft "Orphaned package(s) pin a version that is pending an upgrade:"
  for b in $ORPHAN_BLOCKERS; do note "  $b"; done
  note "These block 'pacman -Syu' permanently. Remove with:"
  note "  sudo pacman -R $(echo "$ORPHAN_BLOCKERS" | tr '\n' ' ')"
fi

# ===========================================================================
# 2. libvirt and networking
# ===========================================================================
section "libvirt"

if systemctl is-enabled libvirtd.socket >/dev/null 2>&1; then
  ok "libvirtd.socket is enabled"
else
  if try_fix "enabled and started libvirtd" ${SUDO:+$SUDO} systemctl enable --now libvirtd.socket; then :
  else
    bad "libvirtd.socket is not enabled"
    note "ACTION: sudo systemctl enable --now libvirtd.socket"
  fi
fi

if vs version >/dev/null 2>&1 && [[ -n "$(vs version)" ]]; then
  ok "libvirtd responds"
else
  if try_fix "started libvirtd" ${SUDO:+$SUDO} systemctl start libvirtd.socket libvirtd.service; then :
  else
    bad "Cannot talk to libvirtd"
    note "ACTION: sudo systemctl enable --now libvirtd.socket"
    note "If you are not root, log out and back in so the 'libvirt' group applies."
  fi
fi

if [[ -r /etc/libvirt/network.conf ]] && grep -qE '^\s*firewall_backend\s*=\s*"iptables"' /etc/libvirt/network.conf; then
  ok "firewall_backend = \"iptables\" configured"
else
  if try_fix 'set firewall_backend = "iptables"' \
       ${SUDO:+$SUDO} sh -c 'printf "firewall_backend = \"iptables\"\n" >> /etc/libvirt/network.conf'; then :
  else
    bad "libvirt firewall_backend is not set to iptables"
    note 'ACTION: add  firewall_backend = "iptables"  to /etc/libvirt/network.conf'
  fi
fi

if vs net-info "${VM_NETWORK}" | grep '^Active:.*yes' >/dev/null; then
  ok "Network '${VM_NETWORK}' is active"
else
  if try_fix "started network '${VM_NETWORK}'" ${SUDO:+$SUDO} virsh net-start "${VM_NETWORK}"; then :
  else
    bad "Network '${VM_NETWORK}' is not active"
    note "If the error mentions virbr0 or 'Package not installed', the bridge"
    note "module cannot load - see the kernel check above (reboot needed)."
    note "ACTION: sudo virsh net-start ${VM_NETWORK}"
  fi
fi

if vs net-dumpxml "${VM_NETWORK}" | grep "${VM_MAC}" >/dev/null; then
  ok "DHCP reservation for ${VM_IP} present"
else
  if try_fix "added the DHCP reservation for ${VM_IP}" \
       ${SUDO:+$SUDO} virsh net-update "${VM_NETWORK}" add ip-dhcp-host \
         "<host mac='${VM_MAC}' name='${VM_NAME}' ip='${VM_IP}'/>" --live --config; then :
  else
    soft "No DHCP reservation for ${VM_IP}; the guest will still get an address"
    note "ACTION: re-run ${HERE}/1-setup-host.sh"
  fi
fi

# ===========================================================================
# 3. The domain
# ===========================================================================
section "Domain"

if vs dominfo "${VM_NAME}" >/dev/null 2>&1; then
  ok "Domain '${VM_NAME}' exists"
  DOMAIN_EXISTS="true"
else
  DOMAIN_EXISTS="false"
  bad "Domain '${VM_NAME}' does not exist"
  note "ACTION: sudo ${HERE}/2-create-vm.sh   (or just ./setup.sh)"
fi

if [[ "$DOMAIN_EXISTS" == "true" ]]; then
  if [[ "$(vs domstate "${VM_NAME}" | tr -d '[:space:]')" == "running" ]]; then
    ok "Domain is running"
  else
    if try_fix "started '${VM_NAME}'" ${SUDO:+$SUDO} virsh start "${VM_NAME}"; then :
    else
      bad "Domain is not running"
      note "ACTION: ${HERE}/3-vmctl.sh start   (or ./setup.sh)"
    fi
  fi

  for f in "${VM_DIR}/${VM_NAME}.qcow2" "${VM_DIR}/${VM_NAME}-seed.iso"; do
    if [[ -e "$f" ]]; then ok "Present: $(basename "$f")"; else soft "Missing: $f"; fi
  done
fi

# ===========================================================================
# 4. The guest
# ===========================================================================
section "Guest"

GUEST_IP="$(guest_ip)"
if vs domstate "${VM_NAME}" 2>/dev/null | grep running >/dev/null && \
   gssh 'true' >/dev/null 2>&1; then
  ok "Guest reachable at ${GUEST_IP}"
  GUEST_UP="true"
else
  GUEST_UP="false"
  bad "Guest not reachable over SSH at ${GUEST_IP}"
  note "ACTION: ${HERE}/3-vmctl.sh console   (serial console, Ctrl+] to exit)"
fi

if [[ "$GUEST_UP" == "true" ]]; then
  PROVISION_LOG="/var/log/dev-vm-provision.log"
  if gssh "test -f '${PROVISION_MARKER}'" >/dev/null 2>&1; then
    if gssh "test -f '${PROVISION_FAIL_MARKER}'" >/dev/null 2>&1; then
      FAILED_AT="$(gssh "head -1 '${PROVISION_FAIL_MARKER}'" | tr -d '\r')"
      FAIL_SUMMARY="$(gssh "grep '^!!' '${PROVISION_LOG}' 2>/dev/null | head -5")"

      soft "Provisioning finished with errors (marker dated ${FAILED_AT:-unknown})"
      if [[ -n "$FAIL_SUMMARY" ]]; then
        note "Steps that recorded a failure:"
        while IFS= read -r l; do [[ -n "$l" ]] && note "  ${l}"; done <<<"$FAIL_SUMMARY"
      fi

      # A failure marker is permanent, but the failure itself may not be: the
      # Docker failure that this marker records was resolved by rebooting the
      # guest. Check what provisioning is responsible for before crying wolf.
      if gssh 'systemctl is-active docker' | grep '^active' >/dev/null 2>&1 \
         && gssh 'command -v dsh' >/dev/null 2>&1; then
        note "Docker and DSH are both healthy now, so this marker is historical."
        if try_fix "cleared the stale provisioning failure marker" \
             gssh_sudo rm -f "${PROVISION_FAIL_MARKER}"; then :
        else
          note "Clear it with: ssh ${VM_USER}@${GUEST_IP} 'sudo rm -f ${PROVISION_FAIL_MARKER}'"
        fi
      else
        note "The failure may still be real (Docker or DSH is missing)."
        note "ACTION: ssh ${VM_USER}@${GUEST_IP} 'sudo /usr/local/sbin/provision-dev-tools.sh'"
      fi
    else
      ok "Provisioning completed successfully"
    fi
  else
    soft "Provisioning marker absent (still running, or never ran)"
    note "ACTION: ssh ${VM_USER}@${GUEST_IP} 'cloud-init status --long'"
  fi

  # Same kernel trap as the host, but this one IS repairable: reboot the guest.
  if gssh '[ ! -d "/lib/modules/$(uname -r)" ]' >/dev/null 2>&1; then
    if [[ "$FIX" == "true" ]]; then
      gssh 'sudo reboot' >/dev/null 2>&1 || true
      if wait_for_ssh "$GUEST_IP" "$(vm_ssh_key)" 300; then
        fixed "Rebooted the guest so its new kernel's modules load"
      else
        bad "Guest did not come back after a reboot"
      fi
    else
      bad "Guest is running a kernel whose modules were replaced"
      note "Docker and other module-dependent services cannot start."
      note "ACTION: ${HERE}/doctor.sh --fix   (reboots the guest), or ssh ${VM_USER}@${GUEST_IP} 'sudo reboot'"
    fi
  else
    ok "Guest kernel $(gssh 'uname -r') has its modules"
  fi

  if gssh 'systemctl is-active docker' | grep '^active' >/dev/null; then
    ok "Docker is running in the guest"
  else
    if try_fix "started Docker in the guest" gssh_sudo systemctl start docker; then :
    else
      soft "Docker is not running in the guest"
      note "Usually this means the guest kernel was upgraded and it needs a reboot."
      note "ACTION: ssh ${VM_USER}@${GUEST_IP} 'sudo systemctl status docker'"
    fi
  fi

  if gssh 'command -v dsh' >/dev/null 2>&1; then
    ok "DSH installed: $(gssh 'dsh --version' | sed -n 1p)"
  else
    if try_fix "installed the DSH CLI in the guest" gssh_sudo npm install -g @deepseek-ai/dsh; then :
    else
      bad "DSH CLI is not installed in the guest"
      note "ACTION: ssh ${VM_USER}@${GUEST_IP} 'sudo npm install -g @deepseek-ai/dsh'"
    fi
  fi

  if gssh 'command -v pnpm' >/dev/null 2>&1; then
    ok "pnpm present (needed for custom DSH profiles)"
  else
    soft "pnpm is not installed (only needed for custom DSH profiles)"
  fi

  # The one thing a script cannot supply.
  if gssh 'test -s ~/.dsh/.credentials.yaml' >/dev/null 2>&1; then
    ok "DSH credentials present in the guest"
  else
    soft "No DSH credentials yet - the web UI will load but requests will fail"
    note "ACTION: add your API key in the web UI (it persists to ~/.dsh/.credentials.yaml)"
  fi
fi

# ===========================================================================
# 5. Access
# ===========================================================================
section "Access"

if grep -qF "# >>> ${VM_NAME} (managed by cachyos-dev-vm) >>>" "${HOME}/.ssh/config" 2>/dev/null; then
  if grep -A3 -F "# >>> ${VM_NAME} (managed by cachyos-dev-vm) >>>" "${HOME}/.ssh/config" \
       | grep -F "${GUEST_IP}" >/dev/null; then
    ok "SSH alias '${VM_NAME}' points at ${GUEST_IP}"
  else
    soft "SSH alias '${VM_NAME}' exists but its address looks stale"
    note "ACTION: sudo ${HERE}/2-create-vm.sh --adopt"
  fi
else
  soft "No '${VM_NAME}' entry in ~/.ssh/config"
  note "ACTION: sudo ${HERE}/2-create-vm.sh --adopt"
fi

if [[ -e /var/lib/libvirt/images/${VM_NAME}/credentials.txt ]]; then
  ok "credentials.txt present"
else
  soft "credentials.txt missing (holds the console password)"
fi

PORT="${DSH_WEB_PORT:-8090}"

# Restart both halves of the browser access path. `stop` kills the tunnel via
# its PID file, which is required: starting a second tunnel while a stale one
# holds the port fails with "Address already in use".
restart_web_ui() {
  "$HERE/dsh-web.sh" stop >/dev/null 2>&1 || true
  "$HERE/dsh-web.sh" start --no-browser
}

if ss -ltn 2>/dev/null | grep ":${PORT}" >/dev/null; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${PORT}/" 2>/dev/null)"
  CODE="${CODE:-000}"
  if [[ "$CODE" == "401" || "$CODE" == "303" || "$CODE" == "200" ]]; then
    ok "DSH web UI reachable on http://127.0.0.1:${PORT} (HTTP ${CODE})"
  else
    soft "Something is listening on ${PORT} but returned HTTP ${CODE}"
    note "This is the stale-tunnel case: the SSH forward is still alive but the"
    note "DSH server behind it is gone, so nothing answers."
    if [[ "$GUEST_UP" == "true" ]] && try_fix "restarted the DSH web UI (new tunnel + server)" restart_web_ui; then :
    else
      note "ACTION: ${HERE}/dsh-web.sh stop && ${HERE}/dsh-web.sh start"
    fi
  fi
else
  if [[ "$GUEST_UP" == "true" ]] && try_fix "started the DSH web UI" restart_web_ui; then :
  else
    soft "DSH web UI is not running"
    note "ACTION: ${HERE}/dsh-web.sh start"
  fi
fi

if ss -ltn 2>/dev/null | grep ':3080' >/dev/null; then
  ok "Host's own DSH GUI is on 3080 (the VM uses ${PORT} to avoid a clash)"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo
printf '%s----------------------------------------%s\n' "$C_BLUE" "$C_RESET"
printf '  %spassed %d%s   %swarnings %d%s   %sfailed %d%s   %sfixed %d%s\n' \
  "$C_GRN" "$N_PASS" "$C_RESET" \
  "$C_YEL" "$N_WARN" "$C_RESET" \
  "$C_RED" "$N_FAIL" "$C_RESET" \
  "$C_GRN" "$N_FIXED" "$C_RESET"
printf '%s----------------------------------------%s\n' "$C_BLUE" "$C_RESET"

if [[ "$FIX" != "true" && $((N_FAIL + N_WARN)) -gt 0 ]]; then
  echo "Re-run with --fix to repair what can be repaired automatically."
fi

[[ "$N_FAIL" -eq 0 ]]
