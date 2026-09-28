#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dsh-web.sh — open the VM's DeepSeek Harness web UI in your host browser.
#
#   ./dsh-web.sh start     start the server + tunnel and print the URL
#   ./dsh-web.sh stop      stop both
#   ./dsh-web.sh status    show whether each side is up
#
# Why a tunnel: `dsh web` refuses to listen on anything except 127.0.0.1, by
# design - "it would expose remote code execution to the network". So this
# forwards a host port to the guest's loopback over SSH.
#
# The guest port defaults to 8090 rather than DSH's own 3080, because 3080 is
# already used by the host's own DSH web GUI.
#
# Requires DEEPSEEK_API_KEY to be set inside the guest (see README).
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

PORT="${DSH_WEB_PORT:-8090}"

# Prefer the runtime dir, but fall back when it is missing or not writable.
pick_state_dir() {
  local d
  for d in "${XDG_RUNTIME_DIR:-}" /tmp "${TMPDIR:-/tmp}"; do
    if [[ -n "$d" && -d "$d" && -w "$d" ]]; then printf '%s' "$d"; return 0; fi
  done
  printf '%s' "/tmp"
}
STATE_DIR="$(pick_state_dir)/dsh-web-${VM_NAME}"
TUNNEL_PID_FILE="${STATE_DIR}/tunnel.pid"
# shellcheck disable=SC2088  # ~ must survive to the REMOTE shell, which expands it
REMOTE_LOG="~/.dsh-web.log"
# DSH's credentials must come from here, NOT from ~/.bashrc: the web server is
# started over a non-interactive SSH command, which does not read shell startup
# files - and Arch's ~/.bashrc returns early even for `bash -lc`.
# shellcheck disable=SC2088  # same: expanded by the remote shell, not here
GUEST_ENV_FILE="~/.config/dsh/env"

# Escape hatch so this can run from odd environments (e.g. a sandbox whose
# system ssh_config is unreadable): DSH_SSH_EXTRA_OPTS="-F /dev/null"
read -r -a EXTRA_SSH_OPTS <<<"${DSH_SSH_EXTRA_OPTS:-}"

# shellcheck disable=SC2029  # client-side expansion into the remote command is intended
vm_ssh() { ssh "${SSH_OPTS[@]}" "${EXTRA_SSH_OPTS[@]}" "$@"; }

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

resolve_target() {
  if ! domain_exists; then
    die "No domain named '${VM_NAME}'. Create it with: sudo ${HERE}/2-create-vm.sh"
  fi
  domain_running || die "'${VM_NAME}' is not running. Start it with: ${HERE}/3-vmctl.sh start"
  IP="$(vm_ip)"
  [[ -n "$IP" ]] || die "Could not determine the guest address."
  ssh_opts_for "$(vm_ssh_key)"
}

guest_key_is_set() {
  # Either mechanism counts:
  #   * the web UI persists credentials to ~/.dsh/.credentials.yaml, or
  #   * a headless setup can export DEEPSEEK_API_KEY via ~/.config/dsh/env.
  vm_ssh "${VM_USER}@${IP}" \
    "if [ -s ~/.dsh/.credentials.yaml ]; then exit 0; fi; if [ -r ${GUEST_ENV_FILE} ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?DEEPSEEK_API_KEY=' ${GUEST_ENV_FILE}; then exit 0; fi; test -n \"\${DEEPSEEK_API_KEY:-}\"" >/dev/null 2>&1
}

tunnel_pid() {
  [[ -f "$TUNNEL_PID_FILE" ]] || return 1
  local pid; pid="$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && { printf '%s' "$pid"; return 0; }
  return 1
}

stop_all() {
  if pid="$(tunnel_pid)"; then
    kill "$pid" 2>/dev/null || true
    ok "Tunnel stopped (pid ${pid})"
  else
    echo "Tunnel: not running"
  fi
  rm -f "$TUNNEL_PID_FILE"
  if domain_running; then
    resolve_target
    vm_ssh "${VM_USER}@${IP}" 'pkill -f "[d]sh web" && echo "stopped" || echo "not running"' 2>/dev/null || true
  fi
}

# Two concurrent runs would race for the same host port and leave one tunnel
# orphaned, so serialise them.
acquire_lock "devvm-dsh-web-${VM_NAME}"

case "${1:-start}" in
  start)
    resolve_target
    mkdir -p "$STATE_DIR"

    if ! guest_key_is_set; then
      warn "No DSH credentials found inside the guest."
      warn "The UI will load, but every request will fail until you add a key."
      warn "Easiest: open the UI and add it there - DSH persists it to"
      warn "    ~/.dsh/.credentials.yaml"
      warn "Or, for a headless setup, create ${GUEST_ENV_FILE} containing:"
      warn "    DEEPSEEK_API_KEY=sk-..."
      echo
    fi

    # Clear anything left from a previous run.
    stop_all >/dev/null 2>&1 || true
    sleep 1

    msg "Starting the DSH web server in the guest (port ${PORT})"
    # Source the guest env file so the key reaches the server; `set -a` exports
    # everything the file defines, so the file needs no `export` keywords.
    vm_ssh "${VM_USER}@${IP}" \
      "mkdir -p ~/.config/dsh; set -a; if [ -r ${GUEST_ENV_FILE} ]; then . ${GUEST_ENV_FILE}; fi; set +a; rm -f ${REMOTE_LOG}; nohup dsh web --port ${PORT} --no-open --trusted-host 127.0.0.1:${PORT} > ${REMOTE_LOG} 2>&1 < /dev/null & echo started"

    URL=""
    for _ in $(seq 1 30); do
      sleep 1
      URL="$(vm_ssh "${VM_USER}@${IP}" "grep -oE 'http://[^ ]+' ${REMOTE_LOG} 2>/dev/null | head -1" 2>/dev/null || true)"
      [[ -n "$URL" ]] && break
    done
    if [[ -z "$URL" ]]; then
      warn "The server did not report a URL. Its log:"
      vm_ssh "${VM_USER}@${IP}" "tail -5 ${REMOTE_LOG}" 2>&1 || true
      die "Could not start the DSH web server."
    fi
    ok "Guest is serving: ${URL}"

    msg "Opening the SSH tunnel 127.0.0.1:${PORT} -> ${IP}:${PORT}"
    # nohup + full stdio detach. Without the detach the backgrounded ssh
    # inherits the caller's stdout and keeps the pipe open, so
    # `./dsh-web.sh start | tee log` (or any pipe) never sees EOF and hangs.
    # nohup keeps the tunnel alive if you close the terminal that started it.
    nohup ssh "${SSH_OPTS[@]}" "${EXTRA_SSH_OPTS[@]}" -N -L "${PORT}:127.0.0.1:${PORT}" \
        "${VM_USER}@${IP}" </dev/null >/dev/null 2>&1 &
    TUNNEL=$!
    echo "$TUNNEL" > "$TUNNEL_PID_FILE"
    sleep 2

    if ! kill -0 "$TUNNEL" 2>/dev/null; then
      die "The SSH tunnel exited immediately (is host port ${PORT} already in use?)."
    fi

    # Reachability check: an unauthenticated request must return 401, which
    # proves we are talking to the UI rather than to nothing.
    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${PORT}/" 2>/dev/null)"
    CODE="${CODE:-000}"
    if [[ "$CODE" == "401" ]]; then
      ok "Tunnel verified (unauthenticated request -> 401, as expected)"
    else
      warn "Unexpected response through the tunnel: HTTP ${CODE}"
    fi

    echo
    printf '%s----------------------------------------------------------------%s\n' "$C_GRN" "$C_RESET"
    echo "  Open this in your browser:"
    echo
    echo "    ${URL}"
    echo
    printf '%s----------------------------------------------------------------%s\n' "$C_GRN" "$C_RESET"
    echo "  Stop with:  ${HERE}/dsh-web.sh stop"
    echo

    if [[ "${2:-}" != "--no-browser" ]] && command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$URL" >/dev/null 2>&1 || true
    fi
    ;;

  stop)   stop_all ;;
  status)
    resolve_target
    printf 'guest : %s\n' "$IP"
    printf 'server: %s\n' "$(vm_ssh "${VM_USER}@${IP}" 'pgrep -f "[d]sh web" >/dev/null && echo running || echo stopped' 2>/dev/null)"
    printf 'tunnel: %s\n' "$(tunnel_pid >/dev/null && echo "running (pid $(tunnel_pid))" || echo stopped)"
    ;;
  -h|--help|help) usage ;;
  *) usage; die "Unknown command: ${1}" ;;
esac
