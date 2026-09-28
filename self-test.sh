#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# self-test.sh — validate the templates and scripts without root, /dev/kvm or
#                a running libvirt.
#
#   ./self-test.sh
#
# It syntax-checks every script, renders the cloud-init configuration with
# synthetic values, and asserts that the embedded provisioning script survives
# the YAML indentation round-trip byte-for-byte.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

FAILURES=0
pass() { printf '%s  PASS%s  %s\n' "$C_GRN" "$C_RESET" "$*"; }
fail() { printf '%s  FAIL%s  %s\n' "$C_RED" "$C_RESET" "$*"; FAILURES=$((FAILURES + 1)); }

echo "== 1. bash syntax =="
for f in "${HERE}"/*.sh "${HERE}"/guest/*.sh; do
  [[ -e "$f" ]] || continue
  if bash -n "$f" 2>/dev/null; then
    pass "syntax ok: ${f#"${HERE}"/}"
  else
    fail "syntax error in ${f#"${HERE}"/}"
    bash -n "$f" || true
  fi
done

echo
echo "== 2. configuration =="
for var in VM_NAME VM_HOSTNAME VM_USER VM_VCPUS VM_RAM_MB VM_DISK_GB VM_MAC VM_IP \
           VM_NETWORK VM_POOL_DIR ARCH_CLOUD_IMAGE_URL PROVISION_MARKER; do
  if [[ -n "${!var:-}" ]]; then
    pass "vm.conf defines ${var}"
  else
    fail "vm.conf is missing ${var}"
  fi
done
if [[ "${ARCH_CLOUD_IMAGE_URL}" == https://* ]]; then
  pass "cloud image URL uses https"
else
  fail "cloud image URL is not https"
fi

echo
echo "== 3. render cloud-init =="
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

FAKE_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYTESTKEYTESTKEYTESTKEYTESTKEYUSER test@example"
FAKE_PW="TestPassword12345678"

if build_cloud_init "$HERE" "${TMPDIR_TEST}" "test-instance-1" "$FAKE_KEY" "$FAKE_PW"; then
  pass "build_cloud_init succeeded"
else
  fail "build_cloud_init failed"
fi

# The rendered provisioning script must itself be valid bash.
if bash -n "${TMPDIR_TEST}/provision-dev-tools.sh" 2>/dev/null; then
  pass "rendered provision script is valid bash"
else
  fail "rendered provision script has a syntax error"
  bash -n "${TMPDIR_TEST}/provision-dev-tools.sh" || true
fi

echo
echo "== 4. YAML structure and round-trip =="
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 - "$TMPDIR_TEST" "$VM_USER" "$FAKE_KEY" "$FAKE_PW" <<'PY'
import sys, os, yaml

out, vm_user, fake_key, fake_pw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
failures = []

def check(cond, msg):
    if cond:
        print(f"\033[1;32m  PASS\033[0m  {msg}")
    else:
        print(f"\033[1;31m  FAIL\033[0m  {msg}")
        failures.append(msg)

raw = open(os.path.join(out, "user-data")).read()
check(raw.startswith("#cloud-config"),
      "user-data begins with the required #cloud-config header")

d = yaml.safe_load(raw)

check(d.get("hostname"), "hostname is set")
check(d.get("ssh_pwauth") is False, "ssh_pwauth is false (key-only SSH)")

users = d.get("users") or []
check(len(users) == 1, "exactly one user is declared")
if users:
    u = users[0]
    check(u.get("name") == vm_user, f"user name is '{vm_user}'")
    check("wheel" in (u.get("groups") or []), "user is in the wheel group")
    check(any("NOPASSWD" in s for s in (u.get("sudo") or [])), "user has passwordless sudo")
    keys = u.get("ssh_authorized_keys") or []
    check(keys == [fake_key], "the generated SSH public key is authorised")
    check(u.get("lock_passwd") is False, "password login is unlocked for the console")

cp = (d.get("chpasswd") or {}).get("users") or []
check(len(cp) == 1 and cp[0].get("password") == fake_pw,
      "console password is set via chpasswd")

wf = d.get("write_files") or []
paths = [f.get("path") for f in wf]
check("/usr/local/sbin/provision-dev-tools.sh" in paths,
      "provision script is installed via write_files")

# The critical assertion: the script embedded in YAML must equal the source
# file exactly, i.e. the indentation round-trip is lossless.
embedded = next((f["content"] for f in wf
                 if f.get("path") == "/usr/local/sbin/provision-dev-tools.sh"), None)
source = open(os.path.join(out, "provision-dev-tools.sh")).read()
check(embedded == source, "embedded provision script matches the source byte-for-byte")

runcmd = d.get("runcmd") or []
flat = " ".join(str(x) for x in runcmd)
check("provision-dev-tools.sh" in flat, "runcmd invokes the provision script")
check("sshd.service" in flat, "runcmd enables sshd")
check("qemu-guest-agent.service" in flat, "runcmd enables the QEMU guest agent")
check("serial-getty@ttyS0.service" in flat, "runcmd enables the serial console getty")

meta = yaml.safe_load(open(os.path.join(out, "meta-data")).read())
check(str(meta.get("instance-id", "")).endswith("test-instance-1"),
      "meta-data carries a unique instance-id")

if failures:
    sys.exit(1)
PY
  if [[ $? -ne 0 ]]; then
    fail "one or more YAML assertions failed"
  fi
else
  fail "python3 with PyYAML is required for the structural checks"
fi

echo
echo "== 5. help output =="
# The help text is extracted with a hard-coded line range, which silently
# breaks when the header comment grows: assert it never leaks shell code.
for script in setup.sh doctor.sh 1-setup-host.sh 2-create-vm.sh 3-vmctl.sh 4-add-cachyos-repos.sh dsh-web.sh; do
  [[ -x "${HERE}/${script}" ]] || continue
  HELP_OUT="$("${HERE}/${script}" --help 2>&1 || true)"
  if [[ -z "$HELP_OUT" ]]; then
    fail "${script} --help produced no output"
  elif grep -qE '^[[:space:]]*(set -|source |HERE=)' <<<"$HELP_OUT"; then
    fail "${script} --help leaks shell code: $(grep -nE '^[[:space:]]*(set -|source |HERE=)' <<<"$HELP_OUT" | sed -n 1p)"
  else
    pass "${script} --help prints only documentation"
  fi
done

echo
echo "== 6. static lint =="
# chown takes OWNER:GROUP as a SINGLE argument. Writing
#     chown "$owner" "$group" "$file"
# makes chown treat the group name as just another file name: it fails with
# "cannot access '<group>': No such file or directory" and, under set -e, aborts
# the script. That bug shipped once; this keeps it from coming back.
# The bug is specifically `chown "<owner>" "<group>" ...` - a first quoted
# argument with NO colon, immediately followed by another quoted argument.
# `chown "<owner>:<group>" "<file>"` is correct and must not be flagged, and
# neither may comment lines that merely document the pattern.
CHOWN_BUGS="$(grep -rnE 'chown[[:space:]]+"[^":]+"[[:space:]]+"[^"]+"' \
                "${HERE}"/*.sh "${HERE}"/guest/*.sh 2>/dev/null \
              | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
if [[ -n "$CHOWN_BUGS" ]]; then
  fail "chown called with separate owner and group arguments (use OWNER:GROUP):"
  printf '%s\n' "$CHOWN_BUGS" >&2
else
  pass "no chown calls pass owner and group as separate arguments"
fi

echo
echo "== 7. pipefail hazards =="
# `grep -q` exits on the first match, which SIGPIPEs the upstream stage. Under
# `set -o pipefail` that turns a successful match into a failed pipeline, so the
# check silently reports the opposite of the truth. This shipped once and caused
# a false "network is not active" while the network was fine.
GREPQ="$(grep -rnE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' \
           "${HERE}"/*.sh "${HERE}"/guest/*.sh 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
if [[ -n "$GREPQ" ]]; then
  fail "grep -q used in a pipeline (SIGPIPE + pipefail makes it unreliable):"
  printf '%s\n' "$GREPQ" >&2
else
  pass "no 'grep -q' in pipelines"
fi

# `| head` has the same shape. It is only safe when the producer is a herestring
# or a remote shell (no local process to SIGPIPE), so this is informational.
# Remote invocations (gssh/vm_ssh) run head inside the guest, where there is no
# local pipefail, so they are not hazards.
HEADP="$(grep -rnE '\|[[:space:]]*head' "${HERE}"/*.sh "${HERE}"/guest/*.sh 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' \
         | grep -vE 'gssh |vm_ssh ' || true)"
if [[ -n "$HEADP" ]]; then
  printf '  %sNOTE%s  local pipe-to-head - verify the producer cannot SIGPIPE:\n' "$C_YEL" "$C_RESET"
  printf '%s\n' "$HEADP" | sed 's/^/         /'
else
  pass "no local pipe-to-head constructs"
fi

echo
echo "== 8. vm.conf sanity =="
# A typo here costs a 15-minute build before it surfaces.
for v in VM_VCPUS VM_RAM_MB VM_DISK_GB; do
  if [[ "${!v}" =~ ^[0-9]+$ ]] && (( ${!v} > 0 )); then
    pass "${v}=${!v} is a positive integer"
  else
    fail "${v}='${!v}' is not a positive integer"
  fi
done
if [[ "$VM_MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
  pass "VM_MAC is a well-formed MAC address"
else
  fail "VM_MAC='${VM_MAC}' is not a MAC address"
fi
if [[ "$VM_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  pass "VM_IP is a well-formed IPv4 address"
else
  fail "VM_IP='${VM_IP}' is not an IPv4 address"
fi
for v in VM_NAME VM_USER; do
  if [[ "${!v}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    pass "${v}='${!v}' is a safe identifier"
  else
    fail "${v}='${!v}' is not a safe identifier"
  fi
done

echo
echo "== 9. shell-integrity lint =="
# Redirections given to `exec` are PERMANENT. `exec 9>lock 2>/dev/null` looks
# like it only guards the exec, but it repoints this shell's stderr at
# /dev/null for the entire rest of the run - silently swallowing every later
# warning and error message. That shipped once; the lock still refused, but
# said nothing, which is worse than failing loudly.
EXECB="$(grep -rnE 'exec[[:space:]]+[0-9]+>.*(&[12]|[12]>)' \
          "${HERE}"/*.sh "${HERE}"/guest/*.sh 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
if [[ -n "$EXECB" ]]; then
  fail "exec used with extra redirections (redirections on exec are permanent):"
  printf '%s\n' "$EXECB" >&2
else
  pass "no 'exec' calls with extra redirections"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
  printf '%sAll checks passed.%s\n' "$C_GRN" "$C_RESET"
  exit 0
fi
printf '%s%d check(s) failed.%s\n' "$C_RED" "$FAILURES" "$C_RESET"
exit 1
