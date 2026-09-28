#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lib.sh — shared helpers for the CachyOS development VM scripts.
# This file is *sourced*, never executed directly.
# ---------------------------------------------------------------------------
# shellcheck shell=bash

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm.conf
source "${LIB_DIR}/vm.conf"

# --- locale ----------------------------------------------------------------
# Force C locale for everything these scripts run. libvirt and systemd translate
# their output, so under a non-English LANG checks like
#     virsh net-info default | grep '^Active:.*yes'
#     virsh domstate dev-vm  | grep running
# would silently never match: the labels and the domain-state word are both
# gettext-translated. Parsing any command's human-readable output requires a
# fixed locale.
export LC_ALL=C

# --- pretty output ---------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_YEL=$'\033[1;33m'
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'
else
  C_RESET=""; C_BLUE=""; C_YEL=""; C_RED=""; C_GRN=""
fi

msg()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s ok %s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this script with sudo: sudo ${LIB_DIR}/$(basename -- "${BASH_SOURCE[1]:-$0}")"
}

# Ask a yes/no question. Returns 0 for yes, 1 otherwise.
# Set ASSUME_YES=true to skip the prompt (non-interactive use).
confirm() {
  local reply
  [[ "${ASSUME_YES:-}" == "true" ]] && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Serialise an operation against concurrent runs of itself.
#
# Two `dsh-web.sh start` races produce two SSH tunnels fighting over one port;
# two `setup.sh` races can run virt-install at the same time. The lock is held on
# file descriptor 9 for the lifetime of the process, so it is released
# automatically however the script exits.
#
# If no writable directory is available we proceed unlocked rather than fail:
# a missing lock must never be the reason a script cannot run.
acquire_lock() {
  local name="$1" dir
  for dir in "${XDG_RUNTIME_DIR:-}" /tmp "${TMPDIR:-/tmp}"; do
    [[ -n "$dir" && -d "$dir" && -w "$dir" ]] && break
  done
  [[ -n "$dir" && -d "$dir" && -w "$dir" ]] || return 0

  LOCK_FILE="${dir%/}/${name}.lock"
  command -v flock >/dev/null 2>&1 || { LOCK_FILE=""; return 0; }
  # Create the file first so the `exec` below cannot fail to open it: a failed
  # `exec` redirection terminates a non-interactive shell outright.
  : >>"$LOCK_FILE" 2>/dev/null || { LOCK_FILE=""; return 0; }
  # Do NOT attach extra redirections to this `exec`. Redirections given to `exec`
  # are permanent, so `exec 9>"$LOCK_FILE" 2>/dev/null` would point this shell's
  # stderr at /dev/null for the rest of the run and silently swallow every
  # subsequent warn/die message.
  exec 9>>"$LOCK_FILE"
  if ! flock -n 9; then
    die "Another '${name}' is already running (lock: ${LOCK_FILE})."
  fi
  return 0
}

# --- identity --------------------------------------------------------------
# The account that invoked sudo. It owns the SSH keys and needs to be in the
# libvirt group. Falls back to whoever owns this checkout.
invoking_user() {
  local u="${SUDO_USER:-}"
  if [[ -z "$u" || "$u" == "root" ]]; then
    u="$(stat -c '%U' "${LIB_DIR}")"
  fi
  printf '%s' "$u"
}

home_of() { getent passwd "$1" | cut -d: -f6; }

# Path of the private key used to reach the guest.
vm_ssh_key() { printf '%s' "$(home_of "$(invoking_user)")/.ssh/${VM_NAME}_ed25519"; }

# --- libvirt ---------------------------------------------------------------
virsh_system() { virsh -c qemu:///system "$@"; }

domain_exists() {
  virsh_system dominfo "$VM_NAME" >/dev/null 2>&1
}

domain_running() {
  [[ "$(virsh_system domstate "$VM_NAME" 2>/dev/null | tr -d '[:space:]')" == "running" ]]
}

# Print the guest's IPv4 address, or nothing if it has none yet.
#
# Capturing before parsing is deliberate. Piping virsh into `awk|cut|head -1`
# lets head exit after one line, which SIGPIPEs the upstream stage; under
# `set -o pipefail` that makes the whole substitution non-zero, and every caller
# here runs with `set -e`, so `ip="$(...)"` would abort the script. Reading into
# a variable first removes the pipeline entirely.
vm_ip() {
  local ip="" raw=""

  _first_ipv4() {
    awk '/ipv4/ && $4 !~ /^127\./ { split($4, a, "/"); print a[1]; exit }' <<<"$1"
  }

  # 1. Preferred: ask the qemu-guest-agent running inside the guest.
  raw="$(virsh_system domifaddr "$VM_NAME" --source agent 2>/dev/null || true)"
  ip="$(_first_ipv4 "$raw")"

  # 2. Fallback: the DHCP lease dnsmasq handed out.
  if [[ -z "$ip" ]]; then
    raw="$(virsh_system domifaddr "$VM_NAME" --source lease 2>/dev/null || true)"
    ip="$(_first_ipv4 "$raw")"
  fi

  # 3. Fallback: the address we reserved, if it answers.
  if [[ -z "$ip" ]] && ping -c1 -W1 "$VM_IP" >/dev/null 2>&1; then
    ip="$VM_IP"
  fi

  printf '%s' "$ip"
}

# --- ssh -------------------------------------------------------------------
# ssh_opts_for <private-key>   -> fills the global SSH_OPTS array
#
# DSH_SSH_EXTRA_OPTS is an escape hatch for environments whose system ssh_config
# is unreadable (some sandboxes), where ssh refuses to start at all:
#     DSH_SSH_EXTRA_OPTS="-F /dev/null" ./doctor.sh
# Putting it here rather than in each caller means every helper below honours it.
ssh_opts_for() {
  SSH_OPTS=(
    -i "$1"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=5
    -o LogLevel=ERROR
  )
  local -a extra=()
  read -r -a extra <<<"${DSH_SSH_EXTRA_OPTS:-}"
  if (( ${#extra[@]} > 0 )); then
    SSH_OPTS+=("${extra[@]}")
  fi
}

# wait_for_ssh <ip> <private-key> [timeout-seconds]
wait_for_ssh() {
  local ip="$1" key="$2" timeout="${3:-900}" start now
  ssh_opts_for "$key"
  start="$(date +%s)"
  while :; do
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@${ip}" true >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    (( now - start > timeout )) && return 1
    sleep 5
  done
}

# --- cloud-init rendering --------------------------------------------------
# build_cloud_init <repo-dir> <out-dir> <instance-id> <ssh-pubkey> <password>
#
# Renders cloud-init/user-data.tmpl, cloud-init/meta-data.tmpl and
# guest/provision-dev-tools.sh into <out-dir>, embeds the provision script in
# user-data, and validates the result. Returns non-zero if anything is wrong.
# Kept here (rather than inside 2-create-vm.sh) so it can be tested without
# root - see self-test.sh.
build_cloud_init() {
  local repo="$1" out="$2" instance_id="$3" ssh_pubkey="$4" password="$5"

  [[ -f "${repo}/cloud-init/user-data.tmpl" ]] || { warn "Missing ${repo}/cloud-init/user-data.tmpl"; return 1; }
  [[ -f "${repo}/cloud-init/meta-data.tmpl" ]] || { warn "Missing ${repo}/cloud-init/meta-data.tmpl"; return 1; }
  [[ -f "${repo}/guest/provision-dev-tools.sh" ]] || { warn "Missing ${repo}/guest/provision-dev-tools.sh"; return 1; }

  mkdir -p "$out"

  # Bash functions see the caller's locals, so the placeholders below resolve
  # against the arguments of build_cloud_init.
  _render() {
    sed \
      -e "s|@@VM_NAME@@|${VM_NAME}|g" \
      -e "s|@@VM_HOSTNAME@@|${VM_HOSTNAME}|g" \
      -e "s|@@VM_USER_GECOS@@|${VM_USER_GECOS}|g" \
      -e "s|@@VM_USER@@|${VM_USER}|g" \
      -e "s|@@SSH_PUBKEY@@|${ssh_pubkey}|g" \
      -e "s|@@VM_PASSWORD@@|${password}|g" \
      -e "s|@@INSTANCE_ID@@|${instance_id}|g" \
      -e "s|@@GUEST_DEV_TOOLS@@|${GUEST_DEV_TOOLS}|g" \
      -e "s|@@GUEST_ENABLE_DOCKER@@|${GUEST_ENABLE_DOCKER}|g" \
      -e "s|@@GUEST_ENABLE_PODMAN@@|${GUEST_ENABLE_PODMAN}|g" \
      -e "s|@@GUEST_INSTALL_DSH@@|${GUEST_INSTALL_DSH}|g" \
      -e "s|@@GUEST_INSTALL_PNPM@@|${GUEST_INSTALL_PNPM}|g" \
      -e "s|@@PROVISION_MARKER@@|${PROVISION_MARKER}|g" \
      -e "s|@@PROVISION_FAIL_MARKER@@|${PROVISION_FAIL_MARKER}|g" \
      "$1" > "$2"
  }

  _render "${repo}/guest/provision-dev-tools.sh" "${out}/provision-dev-tools.sh"
  _render "${repo}/cloud-init/meta-data.tmpl"     "${out}/meta-data"

  # user-data embeds the provision script, so it must be indented one level
  # deeper than the `content: |` key it lives under.
  _render "${repo}/cloud-init/user-data.tmpl" "${out}/user-data.raw"
  awk -v script="${out}/provision-dev-tools.sh" '
    /^@@PROVISION_SCRIPT@@$/ {
      while ((getline line < script) > 0) print "      " line
      close(script)
      next
    }
    { print }
  ' "${out}/user-data.raw" > "${out}/user-data"
  rm -f "${out}/user-data.raw"

  if grep -qE '@@[A-Z_]+@@' "${out}/user-data" "${out}/meta-data" "${out}/provision-dev-tools.sh"; then
    warn "Unsubstituted placeholders remain in the rendered files:"
    grep -nE '@@[A-Z_]+@@' "${out}/user-data" "${out}/meta-data" "${out}/provision-dev-tools.sh" >&2 || true
    return 1
  fi

  chmod 0600 "${out}/user-data" "${out}/meta-data"

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    if ! python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "${out}/user-data"; then
      warn "Rendered user-data is not valid YAML."
      return 1
    fi
  fi

  return 0
}

# wait_for_provision <ip> <private-key> [timeout-seconds]
# Waits until the in-guest provisioning script drops its completion marker.
wait_for_provision() {
  local ip="$1" key="$2" timeout="${3:-3600}" start now
  ssh_opts_for "$key"
  start="$(date +%s)"
  while :; do
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@${ip}" \
         "test -f '${PROVISION_MARKER}'" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    (( now - start > timeout )) && return 1
    sleep 10
  done
}

# provision_failed <ip> <private-key>
# Returns 0 if the guest recorded that provisioning finished with errors.
# The completion marker means "the attempt finished", NOT "it succeeded".
provision_failed() {
  local ip="$1" key="$2"
  ssh_opts_for "$key"
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@${ip}" \
      "test -f '${PROVISION_FAIL_MARKER}'" >/dev/null 2>&1
}
