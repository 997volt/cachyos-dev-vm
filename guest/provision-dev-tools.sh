#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# provision-dev-tools.sh — runs INSIDE the guest on first boot, invoked by
# cloud-init's runcmd. It is copied to /usr/local/sbin/provision-dev-tools.sh
# and is safe to re-run by hand at any time:
#
#     sudo /usr/local/sbin/provision-dev-tools.sh
#
# Values wrapped in doubled at-signs are substituted by 2-create-vm.sh using
# the settings in vm.conf.
# ---------------------------------------------------------------------------
set -uo pipefail

VM_USER="@@VM_USER@@"
ENABLE_DEV_TOOLS="@@GUEST_DEV_TOOLS@@"
ENABLE_DOCKER="@@GUEST_ENABLE_DOCKER@@"
ENABLE_PODMAN="@@GUEST_ENABLE_PODMAN@@"
ENABLE_DSH="@@GUEST_INSTALL_DSH@@"
ENABLE_PNPM="@@GUEST_INSTALL_PNPM@@"

MARKER="@@PROVISION_MARKER@@"
FAIL_MARKER="@@PROVISION_FAIL_MARKER@@"
LOG="/var/log/dev-vm-provision.log"
FAILED=0

# Mirror everything into a log file while still letting cloud-init capture it
# in /var/log/cloud-init-output.log.
exec > >(tee -a "$LOG") 2>&1

echo "=== dev-vm provisioning started: $(date -Is) ==="

# ---------------------------------------------------------------------------
# 0. Lock the cloud image's built-in 'arch' account.
#    cloud-init creates the account we asked for; if the image's default
#    account also exists, make sure it cannot be logged into.
# ---------------------------------------------------------------------------
if id arch >/dev/null 2>&1; then
  passwd -l arch >/dev/null 2>&1 && echo "locked the default 'arch' account"
fi

# ---------------------------------------------------------------------------
# 1. Full system upgrade.
#    Arch is rolling: installing anything without a full upgrade first risks a
#    partial upgrade, which is unsupported and breaks systems.
# ---------------------------------------------------------------------------
echo "--- upgrading the system (this takes a few minutes)"
if ! pacman -Syu --noconfirm; then
  echo "!! system upgrade failed"
  FAILED=1
fi

# The upgrade above may have replaced the kernel. If it did, the module tree for
# the kernel we are still running is gone and NO new kernel module can be loaded
# until this VM is rebooted. Services that need modules - notably Docker, whose
# nftables/iptables NAT setup needs nf_tables - will fail if started now.
REBOOT_NEEDED=0
if [[ ! -d "/lib/modules/$(uname -r)" ]]; then
  REBOOT_NEEDED=1
  echo "--- the kernel was upgraded: /lib/modules/$(uname -r) no longer exists"
  echo "    Module-dependent services cannot start until this VM reboots."
  echo "    Installed module trees: $(ls /lib/modules 2>/dev/null | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 2. Development toolchain.
# ---------------------------------------------------------------------------
if [[ "$ENABLE_DEV_TOOLS" == "true" ]]; then
  PKGS=(
    # build essentials
    base-devel git
    # editors / shell / terminal tooling
    neovim vim tmux htop btop less man-db zsh direnv git-delta
    # core CLI utilities
    curl wget rsync jq ripgrep fd fzf tree unzip which
    # language runtimes
    python python-pip python-virtualenv
    nodejs npm
    go rustup
    # C/C++ toolchain and debugging
    cmake ninja clang gdb strace
    # linting
    shellcheck shfmt
  )

  [[ "$ENABLE_DOCKER" == "true" ]] && PKGS+=(docker docker-compose docker-buildx)
  [[ "$ENABLE_PODMAN" == "true" ]] && PKGS+=(podman buildah skopeo)

  echo "--- installing ${#PKGS[@]} development packages"
  if ! pacman -S --needed --noconfirm "${PKGS[@]}"; then
    echo "!! some development packages failed to install"
    FAILED=1
  fi

  # --- services -----------------------------------------------------------
  if [[ "$ENABLE_DOCKER" == "true" ]]; then
    echo "--- enabling Docker"
    # Enable unconditionally so it comes up on the next boot, but only start it
    # now if the kernel is usable: starting dockerd without kernel modules makes
    # it fail and hit its start-limit, and that is not a provisioning error.
    if ! systemctl enable docker.service; then
      echo "!! could not enable docker"
      FAILED=1
    elif (( REBOOT_NEEDED )); then
      echo "    docker.service enabled but not started (reboot required first)"
    elif ! systemctl start docker.service; then
      echo "!! docker.service failed to start"
      FAILED=1
    else
      echo "    docker.service is running"
    fi
    # Lets $VM_USER run docker without sudo (takes effect on next login).
    usermod -aG docker "$VM_USER" || true
  fi

  # --- Rust toolchain -----------------------------------------------------
  # rustup ships no toolchain; fetch the default one for the dev user.
  # This is the slowest step of first boot (a few hundred MB).
  if command -v rustup >/dev/null 2>&1; then
    echo "--- installing the Rust stable toolchain for ${VM_USER}"
    if ! runuser -u "$VM_USER" -- rustup default stable; then
      echo "!! rustup default stable failed; run it manually as ${VM_USER}"
      FAILED=1
    fi
  fi
else
  echo "--- GUEST_DEV_TOOLS is not 'true'; skipping the toolchain install"
fi

# ---------------------------------------------------------------------------
# 2b. Node-based tooling (DeepSeek Harness CLI)
# ---------------------------------------------------------------------------
if [[ "$ENABLE_DSH" == "true" || "$ENABLE_PNPM" == "true" ]]; then
  if ! command -v npm >/dev/null 2>&1; then
    echo "!! npm is not installed; skipping the Node-based tooling."
    echo "   (set GUEST_DEV_TOOLS=true, or install npm, then re-run this script)"
  else
    if [[ "$ENABLE_DSH" == "true" ]]; then
      echo "--- installing the DeepSeek Harness CLI (@deepseek-ai/dsh)"
      # Deliberately a PLAIN install. npm 12 blocks package install scripts by
      # default, and that is fine here: node-pty and koffi ship prebuilt
      # platform binaries, and on linux-x64 node-pty has no separate
      # spawn-helper for the blocked postinstall to chmod. Verified by spawning
      # a real pty after exactly this install (see README).
      if ! npm install -g @deepseek-ai/dsh; then
        echo "!! could not install @deepseek-ai/dsh"
        FAILED=1
      elif ! command -v dsh >/dev/null 2>&1; then
        echo "!! dsh was installed but is not on PATH"
        FAILED=1
      else
        echo "    dsh $(dsh --version 2>/dev/null | sed -n 1p) installed"
      fi
    fi

    if [[ "$ENABLE_PNPM" == "true" ]]; then
      # DSH profiles are pnpm workspaces, so custom profiles need pnpm.
      # Installed via npm rather than pacman to avoid another system upgrade
      # (and therefore another kernel-swap reboot) inside the guest.
      echo "--- installing pnpm"
      if ! npm install -g pnpm; then
        echo "!! could not install pnpm"
        FAILED=1
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3. Report
# ---------------------------------------------------------------------------
# The completion marker is written on EVERY exit, success or failure: it means
# "the provisioning attempt has finished", not "everything worked". 2-create-vm.sh
# waits on it, and one failing optional service must not make that wait burn its
# whole timeout. The failure marker records that something went wrong.
touch "$MARKER"

if [[ "$FAILED" -eq 0 ]]; then
  rm -f "$FAIL_MARKER"
  echo "=== dev-vm provisioning finished successfully: $(date -Is) ==="
else
  date -Is > "$FAIL_MARKER"
  echo "=== dev-vm provisioning finished WITH ERRORS: $(date -Is) ==="
  echo "    Review $LOG inside the guest and re-run: sudo /usr/local/sbin/provision-dev-tools.sh"
fi

if (( REBOOT_NEEDED )); then
  echo "=== NOTE: reboot this VM so the newly installed kernel's modules load ==="
fi

exit "$FAILED"
