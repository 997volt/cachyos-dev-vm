#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 2-create-vm.sh — build the cloud-init seed image, the VM disk and the
#                  libvirt domain, then wait for the guest to come up.
#
# Run with:  sudo ./2-create-vm.sh [--adopt] [--skip-provision-wait]
#
# Everything is driven by vm.conf. The script is safe to re-run as long as the
# domain does not already exist.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

SKIP_PROVISION_WAIT="false"
ADOPT="false"
for arg in "$@"; do
  case "$arg" in
    --skip-provision-wait) SKIP_PROVISION_WAIT="true" ;;
    --adopt)               ADOPT="true" ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done

require_root

# Concurrent create runs would fight over the same domain and disk image.
acquire_lock "devvm-create-${VM_NAME}"

TARGET_USER="$(invoking_user)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
TARGET_HOME="$(home_of "$TARGET_USER")"
[[ -n "$TARGET_HOME" ]] || die "Cannot resolve the home directory of '${TARGET_USER}'."

SSH_KEY="$(vm_ssh_key)"
SSH_CFG="${TARGET_HOME}/.ssh/config"
CRED_FILE="${VM_DIR}/credentials.txt"
MARK_BEGIN="# >>> ${VM_NAME} (managed by cachyos-dev-vm) >>>"
MARK_END="# <<< ${VM_NAME} <<<"

# --- post-creation bookkeeping --------------------------------------------
# Kept as functions because both the normal path and --adopt need them: if the
# create run is interrupted after the domain is up, --adopt finishes the job.
write_ssh_alias() {
  msg "Writing the SSH alias for ${TARGET_USER}"
  install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_GROUP" "${TARGET_HOME}/.ssh"
  touch "$SSH_CFG"
  if grep -qF "$MARK_BEGIN" "$SSH_CFG"; then
    # Refresh HostName in case the address changed.
    sed -i "/^${MARK_BEGIN//\//\\/}$/,/^${MARK_END//\//\\/}$/ s|^\(\s*HostName\s*\).*|\1${IP}|" "$SSH_CFG"
    ok "Updated the existing '${VM_NAME}' entry in ${SSH_CFG}"
  else
    cat >> "$SSH_CFG" <<EOF

${MARK_BEGIN}
Host ${VM_NAME}
    HostName ${IP}
    User ${VM_USER}
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
${MARK_END}
EOF
    ok "Added 'Host ${VM_NAME}' to ${SSH_CFG}"
  fi
  chown "${TARGET_USER}:${TARGET_GROUP}" "$SSH_CFG"
  chmod 0600 "$SSH_CFG"
}

write_credentials() {
  [[ -n "${VM_PASSWORD:-}" ]] || { warn "No console password known; skipping ${CRED_FILE}."; return 0; }
  cat > "$CRED_FILE" <<EOF
${VM_NAME} - generated $(date -Is)
domain            : ${VM_NAME}
guest address     : ${IP}
guest user        : ${VM_USER}
console password  : ${VM_PASSWORD}
sudo              : passwordless (NOPASSWD)
ssh private key   : ${SSH_KEY}
disk              : ${DISK}
seed image        : ${SEED_ISO}
SSH               : ssh ${VM_USER}@${IP}
EOF
  chmod 0600 "$CRED_FILE"
  ok "Credentials written to ${CRED_FILE}"
}

print_summary() {
  echo
  printf '%s----------------------------------------------------------------%s\n' "$C_GRN" "$C_RESET"
  printf '%s  VM ready%s\n' "$C_GRN" "$C_RESET"
  printf '%s----------------------------------------------------------------%s\n' "$C_GRN" "$C_RESET"
  cat <<EOF
  address      : ${IP}
  user         : ${VM_USER}   (passwordless sudo)
  ssh          : ssh ${VM_USER}@${IP}
  ssh alias    : ssh ${VM_NAME}
  console pw   : ${VM_PASSWORD:-<unknown>}
  credentials  : ${CRED_FILE}
  console      : ${HERE}/3-vmctl.sh console
  stop/start   : ${HERE}/3-vmctl.sh stop | start   (run as ${TARGET_USER}, not root)
  GUI manager  : virt-manager  (select the '${VM_NAME}' connection)

  Shared folders were intentionally not configured, per your request.
  If you want one later, see the README section "Adding a shared folder".
EOF
  echo
}

# --- adopt an existing domain ---------------------------------------------
# Completes the bookkeeping for a VM that was already created, so an
# interrupted create run does not force you to destroy and rebuild.
if [[ "$ADOPT" == "true" ]]; then
  msg "Adopting the existing '${VM_NAME}' domain"
  domain_exists || die "No domain named '${VM_NAME}'. Run without --adopt to create it."
  domain_running || die "'${VM_NAME}' is not running. Start it with: ${HERE}/3-vmctl.sh start"
  [[ -f "$SSH_KEY" ]] || die "SSH key ${SSH_KEY} is missing."

  IP="$(vm_ip)"
  [[ -n "$IP" ]] || die "Could not determine the guest address. Is its network up?"
  ok "Guest address: ${IP}"

  # The console password only ever existed in the seed that built this VM.
  DISK="${VM_DIR}/${VM_NAME}.qcow2"
  SEED_ISO="${VM_DIR}/${VM_NAME}-seed.iso"
  VM_PASSWORD=""
  if [[ -r "${VM_DIR}/seed/user-data" ]]; then
    VM_PASSWORD="$(awk '/^chpasswd:/{f=1} f && /^[[:space:]]*password:/{print $2; exit}' \
                     "${VM_DIR}/seed/user-data" || true)"
  fi
  [[ -n "$VM_PASSWORD" ]] || warn "Could not recover the console password from ${VM_DIR}/seed/user-data."

  write_ssh_alias
  write_credentials
  print_summary
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
msg "Preflight checks"

[[ -e /dev/kvm ]] || die "/dev/kvm does not exist. Run 1-setup-host.sh first and make sure SVM/VT-x is enabled in your firmware."

for tool in qemu-img virt-install cloud-localds ssh-keygen curl awk; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is missing. Run 1-setup-host.sh first."
done

virsh_system version >/dev/null 2>&1 || die "Cannot talk to libvirtd. Try: sudo systemctl enable --now libvirtd.socket"

if domain_exists; then
  die "A domain named '${VM_NAME}' already exists. Remove it with '${HERE}/3-vmctl.sh destroy', or change VM_NAME in vm.conf."
fi

mkdir -p "$VM_IMAGE_CACHE" "$VM_DIR"

AVAIL_KB="$(df -Pk "$VM_POOL_DIR" | awk 'NR==2{print $4}')"
if (( AVAIL_KB < 10 * 1024 * 1024 )); then
  warn "Only $(( AVAIL_KB / 1024 / 1024 )) GiB free in ${VM_POOL_DIR}. The disk is sparse, but the guest will fill it over time."
fi
ok "Preflight OK (host has $(( AVAIL_KB / 1024 / 1024 )) GiB free for VM storage)"

# ---------------------------------------------------------------------------
# SSH key used to reach the guest
# ---------------------------------------------------------------------------
msg "Preparing the SSH key pair"
SSH_KEY="$(vm_ssh_key)"
install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_GROUP" "${TARGET_HOME}/.ssh"
if [[ -f "$SSH_KEY" ]]; then
  ok "Reusing ${SSH_KEY}"
else
  ssh-keygen -q -t ed25519 -N "" -C "${TARGET_USER}@$(hostname)-${VM_NAME}" -f "$SSH_KEY"
  ok "Generated ${SSH_KEY}"
fi
# Fix ownership on every run, not just when generating: ssh-keygen runs as root
# here, and a root-owned private key is unusable by ${TARGET_USER}. Note that
# chown takes OWNER:GROUP as a SINGLE argument - passing them as two arguments
# makes chown treat the group name as a file name.
chown "${TARGET_USER}:${TARGET_GROUP}" "$SSH_KEY" "${SSH_KEY}.pub"
chmod 0600 "$SSH_KEY"
chmod 0644 "${SSH_KEY}.pub"
SSH_PUBKEY="$(cat "${SSH_KEY}.pub")"

# ---------------------------------------------------------------------------
# Console password (SSH stays key-only; this is for the serial/virsh console)
# ---------------------------------------------------------------------------
VM_PASSWORD="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
[[ ${#VM_PASSWORD} -eq 20 ]] || die "Could not generate a console password."

# ---------------------------------------------------------------------------
# Base image: fetch the published checksum, then cache the image by content.
# Caching by hash means a newly published "latest" image never silently
# replaces the base of an existing VM.
# ---------------------------------------------------------------------------
msg "Resolving the current Arch cloud image"
SHA_FILE="${VM_IMAGE_CACHE}/Arch-Linux-x86_64-cloudimg.qcow2.SHA256"
if ! curl -fsSL --retry 3 -o "${SHA_FILE}.part" "${ARCH_CLOUD_IMAGE_URL}.SHA256"; then
  die "Could not download ${ARCH_CLOUD_IMAGE_URL}.SHA256 (network problem?)."
fi
mv "${SHA_FILE}.part" "$SHA_FILE"

EXPECTED_SHA="$(awk 'NR==1{print $1}' "$SHA_FILE")"
[[ ${#EXPECTED_SHA} -eq 64 ]] || die "Unexpected checksum format in ${SHA_FILE}."

BASE_IMAGE="${VM_IMAGE_CACHE}/arch-cloudimg-${EXPECTED_SHA:0:16}.qcow2"
if [[ -f "$BASE_IMAGE" ]]; then
  ok "Base image already cached: $(basename "$BASE_IMAGE")"
else
  msg "Downloading the Arch cloud image (~534 MiB) - one time only"
  if ! curl -fL --retry 3 --progress-bar -o "${BASE_IMAGE}.part" "$ARCH_CLOUD_IMAGE_URL"; then
    rm -f "${BASE_IMAGE}.part"
    die "Download failed."
  fi
  ACTUAL_SHA="$(sha256sum "${BASE_IMAGE}.part" | awk '{print $1}')"
  if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    rm -f "${BASE_IMAGE}.part"
    die "Checksum mismatch! expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}"
  fi
  mv "${BASE_IMAGE}.part" "$BASE_IMAGE"
  ok "SHA-256 verified, cached as $(basename "$BASE_IMAGE")"
fi

# ---------------------------------------------------------------------------
# VM disk
# ---------------------------------------------------------------------------
DISK="${VM_DIR}/${VM_NAME}.qcow2"
msg "Creating the VM disk (${VM_DISK_GB} GiB virtual, sparse)"
rm -f "$DISK"
qemu-img convert -O qcow2 "$BASE_IMAGE" "$DISK"
qemu-img resize "$DISK" "${VM_DISK_GB}G" >/dev/null
ok "Disk ready: ${DISK}"

# ---------------------------------------------------------------------------
# cloud-init seed
# ---------------------------------------------------------------------------
msg "Rendering the cloud-init configuration"
SEED_DIR="${VM_DIR}/seed"
INSTANCE_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

if build_cloud_init "$HERE" "$SEED_DIR" "$INSTANCE_ID" "$SSH_PUBKEY" "$VM_PASSWORD"; then
  ok "Rendered and validated the cloud-init configuration"
else
  die "Could not render the cloud-init configuration (see messages above)."
fi

SEED_ISO="${VM_DIR}/${VM_NAME}-seed.iso"
rm -f "$SEED_ISO"
cloud-localds "$SEED_ISO" "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data"
chmod 0600 "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data"
ok "Seed image built: ${SEED_ISO}"

# ---------------------------------------------------------------------------
# Domain
# ---------------------------------------------------------------------------
msg "Defining and starting the '${VM_NAME}' domain"
virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --description "Arch-based development VM, provisioned by cloud-init" \
  --memory "$VM_RAM_MB" \
  --vcpus "$VM_VCPUS" \
  --cpu host-passthrough \
  --machine q35 \
  --boot uefi \
  --osinfo detect=on,require=off \
  --disk "path=${DISK},format=qcow2,bus=virtio,cache=none,discard=unmap" \
  --disk "path=${SEED_ISO},device=cdrom,readonly=on" \
  --network "network=${VM_NETWORK},model=virtio,mac=${VM_MAC}" \
  --graphics none \
  --console pty,target_type=serial \
  --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
  --rng /dev/urandom \
  --import \
  --noautoconsole

ok "Domain '${VM_NAME}' is running"

# ---------------------------------------------------------------------------
# Wait for SSH
# ---------------------------------------------------------------------------
msg "Waiting for the guest to boot and answer on SSH"
IP=""
START="$(date +%s)"
while :; do
  IP="$(vm_ip)"
  if [[ -n "$IP" ]] && wait_for_ssh "$IP" "$SSH_KEY" 1; then
    break
  fi
  if (( $(date +%s) - START > 900 )); then
    warn "Timed out after 15 minutes waiting for SSH."
    warn "Attach to the console with:  sudo ${HERE}/3-vmctl.sh console"
    warn "The domain is still defined; inspect it with: virsh -c qemu:///system list --all"
    exit 1
  fi
  sleep 5
done
ok "Guest reachable at ${IP}"

# ---------------------------------------------------------------------------
# Wait for first-boot provisioning
# ---------------------------------------------------------------------------
if [[ "$SKIP_PROVISION_WAIT" == "true" ]]; then
  warn "Skipping the provisioning wait (--skip-provision-wait)."
else
  msg "Waiting for cloud-init to install the toolchain (usually 3-10 minutes)"
  if wait_for_provision "$IP" "$SSH_KEY" 2700; then
    if provision_failed "$IP" "$SSH_KEY"; then
      warn "Provisioning finished, but reported errors - the VM is still usable."
      warn "Inspect:  ssh ${VM_USER}@${IP} 'sudo tail -50 /var/log/dev-vm-provision.log'"
      warn "Re-run:   ssh ${VM_USER}@${IP} 'sudo /usr/local/sbin/provision-dev-tools.sh'"
    else
      ok "Provisioning finished successfully"
    fi
  else
    warn "Provisioning did not finish within 45 minutes."
    warn "Check inside the guest:  journalctl -u cloud-final -b  and  /var/log/dev-vm-provision.log"
  fi
fi

# ---------------------------------------------------------------------------
# Host-side ergonomics
# ---------------------------------------------------------------------------
write_ssh_alias
write_credentials
print_summary
