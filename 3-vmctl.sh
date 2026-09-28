#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 3-vmctl.sh — day-to-day control of the development VM.
#
# Run as your normal user (the one that was added to the 'libvirt' group):
#
#   ./3-vmctl.sh status          show state, address and provision status
#   ./3-vmctl.sh start|stop      boot / graceful shutdown
#   ./3-vmctl.sh force-stop      hard power off
#   ./3-vmctl.sh restart
#   ./3-vmctl.sh ssh [command]   log in over SSH (or run one command)
#   ./3-vmctl.sh console         serial console  (leave with Ctrl+])
#   ./3-vmctl.sh wait            wait for SSH and for provisioning to finish
#   ./3-vmctl.sh ip              print the guest address
#   ./3-vmctl.sh info            libvirt domain summary
#   ./3-vmctl.sh destroy         delete the VM, its disk and its SSH alias
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

SSH_KEY="$(vm_ssh_key)"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

# Fail early with an actionable message when the group membership is missing.
require_libvirt_access() {
  if ! virsh_system version >/dev/null 2>&1; then
    die "Cannot talk to libvirtd as '$(id -un)'.
    You were added to the 'libvirt' group by 1-setup-host.sh, but that only
    applies to new sessions. Log out and back in, or run:  newgrp libvirt"
  fi
}

resolve_ip() {
  local ip
  ip="$(vm_ip)"
  [[ -n "$ip" ]] || die "Could not determine the guest address. Is the VM running?  $0 status"
  printf '%s' "$ip"
}

require_domain() {
  domain_exists || die "No domain named '${VM_NAME}'. Create it with: sudo ${HERE}/2-create-vm.sh"
}

# confirm() is provided by lib.sh.

# Remove the managed block from ~/.ssh/config.
remove_ssh_alias() {
  local user cfg group
  user="$(invoking_user)"
  cfg="$(home_of "$user")/.ssh/config"
  local begin="# >>> ${VM_NAME} (managed by cachyos-dev-vm) >>>"
  local end="# <<< ${VM_NAME} <<<"
  [[ -f "$cfg" ]] || return 0
  if grep -qF "$begin" "$cfg"; then
    local tmp
    tmp="$(mktemp)"
    awk -v b="$begin" -v e="$end" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip   { print }
    ' "$cfg" > "$tmp"
    group="$(id -gn "$user")"
    install -m 0600 -o "$user" -g "$group" "$tmp" "$cfg"
    rm -f "$tmp"
    ok "Removed the '${VM_NAME}' entry from ${cfg}"
  fi
}

command="${1:-status}"
shift || true

case "$command" in
  status)
    require_libvirt_access
    if ! domain_exists; then
      die "No domain named '${VM_NAME}'. Create it with: sudo ${HERE}/2-create-vm.sh"
    fi
    STATE="$(virsh_system domstate "$VM_NAME" | tr -d '[:space:]')"
    printf 'domain      : %s\n' "$VM_NAME"
    printf 'state       : %s\n' "$STATE"
    printf 'vCPUs       : %s\n' "$(virsh_system dominfo "$VM_NAME" | awk -F': +' '/^CPU\(s\)/{print $2}')"
    printf 'memory      : %s\n' "$(virsh_system dominfo "$VM_NAME" | awk -F': +' '/^Max memory/{print $2}')"
    if [[ "$STATE" == "running" ]]; then
      IP="$(vm_ip)"
      printf 'address     : %s\n' "${IP:-<not yet assigned>}"
      if [[ -n "$IP" ]] && ssh_opts_for "$SSH_KEY" && \
         ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@${IP}" \
             "test -f '${PROVISION_MARKER}'" >/dev/null 2>&1; then
        printf 'provisioning: complete\n'
      else
        printf 'provisioning: not finished (or unreachable)\n'
      fi
    fi
    ;;

  ip)        require_libvirt_access; require_domain; resolve_ip; echo ;;
  start)     require_libvirt_access; require_domain
             if domain_running; then ok "'${VM_NAME}' is already running"
             else virsh_system start "$VM_NAME" >/dev/null; ok "Started '${VM_NAME}'"; fi ;;
  stop)      require_libvirt_access; require_domain; domain_running || { ok "'${VM_NAME}' is already stopped"; exit 0; }
             msg "Requesting a graceful shutdown (ACPI power button)"
             virsh_system shutdown "$VM_NAME" >/dev/null
             for _ in $(seq 1 60); do domain_running || break; sleep 1; done
             if domain_running; then
               warn "The guest did not shut down within 60s."
               warn "Force it with:  $0 force-stop"
               exit 1
             fi
             ok "'${VM_NAME}' stopped" ;;
  force-stop) require_libvirt_access; require_domain
             virsh_system destroy "$VM_NAME" >/dev/null; ok "Force-stopped '${VM_NAME}'" ;;
  restart)   require_libvirt_access; require_domain
             virsh_system destroy "$VM_NAME" >/dev/null 2>&1 || true
             virsh_system start "$VM_NAME" >/dev/null; ok "Restarted '${VM_NAME}'" ;;
  ssh)       require_libvirt_access; require_domain
             IP="$(resolve_ip)"
             ssh_opts_for "$SSH_KEY"
             exec ssh "${SSH_OPTS[@]}" "${VM_USER}@${IP}" "$@" ;;
  console)   require_libvirt_access; require_domain
             msg "Attaching to the serial console. Detach with Ctrl+]"
             exec virsh -c qemu:///system console "$VM_NAME" ;;
  wait)      require_libvirt_access; require_domain
             msg "Waiting for SSH"
             IP="$(resolve_ip)"
             if wait_for_ssh "$IP" "$SSH_KEY" 900; then ok "SSH is up at ${IP}"; else die "SSH did not come up."; fi
             msg "Waiting for first-boot provisioning (Ctrl+C to stop waiting)"
             if wait_for_provision "$IP" "$SSH_KEY" 2700; then ok "Provisioning complete"; else die "Provisioning did not report success."; fi ;;
  list)      require_libvirt_access
             virsh_system list --all ;;
  info)      require_libvirt_access; require_domain
             virsh_system dominfo "$VM_NAME" ;;
  destroy)
    require_libvirt_access; require_domain
    warn "This deletes the '${VM_NAME}' domain, its disk (${VM_DIR}) and its SSH alias."
    if confirm "Really destroy '${VM_NAME}'?"; then
      domain_running && virsh_system destroy "$VM_NAME" >/dev/null || true
      # --nvram removes the UEFI variable store created for this domain.
      # --nvram removes the UEFI variable store; fall back for BIOS domains.
      if ! virsh_system undefine "$VM_NAME" --nvram >/dev/null 2>&1; then
        virsh_system undefine "$VM_NAME" >/dev/null
      fi
      rm -rf "$VM_DIR"
      remove_ssh_alias
      ok "Destroyed '${VM_NAME}'"
      echo "The downloaded base image cache in ${VM_IMAGE_CACHE} was kept."
      echo "The SSH key ${SSH_KEY} was kept."
    else
      echo "Aborted."
    fi ;;
  -h|--help|help) usage ;;
  *) usage; die "Unknown command: $command" ;;
esac
