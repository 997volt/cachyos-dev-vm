# CachyOS development VM (KVM/QEMU + libvirt + cloud-init)

A repeatable, scripted way to run a headless **Arch-based Linux VM** for software
development on a **CachyOS Linux** host, using hardware-accelerated KVM.

You get a VM that:

* boots **UEFI** on Q35 with `host-passthrough` CPU (so it is as fast as native),
* provisions itself on first boot via **cloud-init** — user, SSH key, dev toolchain,
* is reachable over **SSH** with key-only auth and passwordless sudo,
* has a working **serial console** and a **QEMU guest agent**,
* stores everything in one directory you can delete cleanly.

---

## Why Arch and not a "CachyOS cloud image"?

CachyOS does not publish cloud images. Arch Linux does, and CachyOS is
Arch-based, so the base is the **official Arch Linux cloud image** — which
already ships `cloud-init`, `cloud-guest-utils` (auto disk resize),
`qemu-guest-agent` and `openssh`.

If you want the actual CachyOS packages and kernel, run the optional
[`4-add-cachyos-repos.sh`](4-add-cachyos-repos.sh) afterwards, which applies the
vendor's own repository script inside the guest.

---

## What was verified on this machine

The scripts here were written against facts checked on this host and against the
real image, not assumptions:

| Fact | Value |
|---|---|
| Distribution | CachyOS Linux (rolling), kernel `7.2.3-arch1-3` |
| CPU virtualisation | AMD **SVM** present, `kvm_amd` loaded, `nested=1` |
| RAM / free disk | ~31 GiB / ~540 GiB on `/` |
| `iptables` package | already installed (provides the nft backend libvirt needs) |
| Arch cloud image | 2 GiB virtual, **btrfs** root, GPT |
| Image partitions | 1 MiB BIOS boot, 300 MiB **EFI System**, ~1.7 GiB btrfs root |
| UEFI bootable | yes — ESP contains `\EFI\BOOT\BOOTX64.EFI` (firmware fallback path) |
| Cloud image contents | `cloud-init 26.2`, `cloud-guest-utils 0.33`, `qemu-guest-agent 11.1.1`, `openssh 10.5p1` |
| cloud-init enabled | `cloud-init.target.wants` present in the image |
| Host packages available | `qemu-full`, `virt-manager`, `virt-install`, `libvirt`, `edk2-ovmf`, `dnsmasq`, `cloud-image-utils` |
| Guest packages | all 43 packages in the toolchain verified present in the repos |

> **Note:** the shell used to *write* these scripts runs inside a restricted
> container (`no new privileges`, no `/dev/kvm`, no sudo), so the scripts could
> not be executed end-to-end from there. What *was* executed is
> [`self-test.sh`](self-test.sh) — run it yourself; it needs no root and checks
> syntax, configuration, and does a full render + YAML round-trip of the
> cloud-init data.

---

## Requirements

* CachyOS (or any Arch-based) host with **SVM/AMD-V or VT-x enabled in firmware**.
* ~15 GiB free in `/var/lib/libvirt/images` (the disk is sparse, starts ~1 GiB).
* `sudo` rights.
* If the host is itself a VM, the outer hypervisor must expose nested
  virtualisation.

## Quick start

**One command builds everything:**

```bash
cd cachyos-dev-vm
./setup.sh
```

That runs, in order and safely re-runnable:

| | Step | Skipped when |
|---|---|---|
| 1/4 | Host setup — libvirt/KVM, NAT network, static DHCP lease | already configured |
| 2/4 | The VM — image, disk, cloud-init, boot, toolchain | domain exists → `--adopt` |
| 3/4 | Reboot the guest | its kernel wasn't upgraded |
| 4/4 | Start the DSH web UI in your browser | — |

It calls `sudo` itself, so **do not run it with `sudo`**. Add `--yes` for
unattended runs.

The one thing it cannot do for you is **enter your DSH API key** — add that in
the web UI the first time; DSH stores it in the guest and reuses it.

`setup.sh` finishes by running `doctor.sh` automatically, so you get a health
report rather than a hopeful "done".

### If something is wrong: `doctor.sh`

```bash
./doctor.sh          # check everything, change nothing
./doctor.sh --fix    # attempt repairs
./doctor.sh --quiet  # only show warnings and failures
```

It walks the whole stack — host kernel/modules, libvirt networking, the domain,
the guest (provisioning, kernel, Docker, DSH, credentials) and browser access —
and exits non-zero if anything failed. **Every check exists because it was a real
failure while building this**, including the two that are easy to misdiagnose:

* a **kernel upgrade that deleted the running kernel's modules**, which surfaces
  as the misleading `Unable to create bridge virbr0: Package not installed` on
  the host, or as Docker failing inside the guest with `nf_tables` netlink errors
* an **orphaned package pinning a version**, which blocks `pacman -Syu` forever

`--fix` repairs what is safely automatable: starting libvirtd and the NAT
network, adding the DHCP reservation, setting the firewall backend, rebooting the
guest when its kernel needs it, starting Docker, installing the DSH CLI, and
starting the web UI. It deliberately does **not** try to fix the host kernel case
— that needs a reboot, and it says so.

### Doing it by hand, step by step

The individual scripts remain useful on their own:

```bash
./self-test.sh                 # no root needed: validates templates + rendering
sudo ./1-setup-host.sh         # install + configure libvirt/KVM
#   -> log out and back in so the new group membership applies
sudo ./2-create-vm.sh          # download image, build seed, create and boot the VM
./3-vmctl.sh status            # check it
ssh dev-vm                     # log in
./dsh-web.sh start             # browser UI
```

`2-create-vm.sh` prints the console password at the end and saves it to
`/var/lib/libvirt/images/dev-vm/credentials.txt` (mode `0600`).

---

## Files

```
cachyos-dev-vm/
├── vm.conf                    # all settings: name, CPU/RAM/disk, network, user
├── lib.sh                     # shared helpers (sourced, not run)
├── 1-setup-host.sh            # host: install & configure libvirt/KVM
├── 2-create-vm.sh             # build the disk + seed, define and start the domain
├── 3-vmctl.sh                 # status/start/stop/ssh/console/wait/destroy
├── 4-add-cachyos-repos.sh     # optional: layer CachyOS repos into the guest
├── self-test.sh               # root-free validation of scripts and templates
├── cloud-init/
│   ├── user-data.tmpl         # user, SSH key, password, write_files, runcmd
│   └── meta-data.tmpl         # instance-id / hostname
└── guest/
    └── provision-dev-tools.sh # runs inside the guest on first boot
```

---

## Step 1 — host setup

`sudo ./1-setup-host.sh` performs:

1. Sanity checks: distro, CPU virtualisation flag, whether the host is itself a VM.
2. `pacman -S qemu-full virt-manager virt-install libvirt edk2-ovmf dnsmasq
   swtpm libosinfo cloud-image-utils openbsd-netcat`.
3. Appends `firewall_backend = "iptables"` to `/etc/libvirt/network.conf`
   (CachyOS ships an nftables default that misroutes libvirt's NAT rules;
   this is the vendor-recommended fix).
4. Adds your user to the `libvirt` (and `kvm`, if present) group.
5. `systemctl enable --now libvirtd.socket libvirtd.service`.
6. `virsh net-autostart default` + `virsh net-start default`.
7. Adds a **static DHCP reservation** (`52:54:00:1d:00:01` → `192.168.122.50`)
   so the SSH alias keeps working across reboots.
8. If `ufw` is active, adds `ufw route allow from 192.168.122.0/24`.

**You must start a new session (log out/in, or `newgrp libvirt`) before the group
membership takes effect.**

## Step 2 — create the VM

`sudo ./2-create-vm.sh` performs:

1. Preflight: `/dev/kvm` present, tools present, libvirtd reachable, no existing
   domain with the same name.
2. Generates `~/.ssh/dev-vm_ed25519` (reused if it already exists).
3. Generates a random 20-character console password.
4. Downloads the **published `.SHA256`**, then caches the image **by content
   hash** as `arch-cloudimg-<hash>.qcow2`. This means a newly published
   `latest` image never silently replaces the base of an existing VM.
5. Makes a **self-contained** copy as the VM disk (no backing-file dependency)
   and resizes it to the configured size.
6. Renders the cloud-init files, embeds the provisioning script, **validates the
   result as YAML** and fails loudly on an unsubstituted placeholder.
7. Builds the NoCloud seed ISO with `cloud-localds`.
8. `virt-install` — Q35, UEFI, virtio disk/net, guest-agent channel, virtio-rng,
   `--graphics none`, serial console — and starts it.
9. Waits for SSH, then waits for the in-guest provisioning marker.
10. Adds a `Host dev-vm` block to your `~/.ssh/config` and writes
    `credentials.txt`.

Options: `--skip-provision-wait` (return as soon as SSH is up).

### Disk expansion

The image is 2 GiB. The disk is resized to 120 GiB and **cloud-init grows
partition 3 and the btrfs filesystem automatically** on first boot, because the
image ships `cloud-guest-utils` (`growpart`). No manual `resize2fs` needed.

## Step 3 — using the VM

```bash
./3-vmctl.sh status          # state, address, provisioning status
./3-vmctl.sh ssh             # interactive shell
./3-vmctl.sh ssh 'uptime'    # run one command
ssh dev-vm                   # via the generated SSH alias
./3-vmctl.sh console         # serial console; leave with Ctrl+]
./3-vmctl.sh stop            # graceful ACPI shutdown
./3-vmctl.sh force-stop      # hard power off
./3-vmctl.sh start
./3-vmctl.sh wait            # block until SSH and provisioning are ready
./3-vmctl.sh destroy         # delete domain + disk + SSH alias
```

`virt-manager` also works — pick the `QEMU/KVM` connection and you will see
`dev-vm`. Because `--graphics none` was used there is no graphical screen;
attach one only if you need it (see below).

### Access modes

* **SSH** — key-only (`ssh_pwauth: false`), key at
  `~/.ssh/dev-vm_ed25519`, alias `dev-vm`. Ideal for VS Code Remote-SSH,
  JetBrains Gateway, or just a terminal.
* **Serial console** — `virsh console`, backed by `serial-getty@ttyS0.service`
  which the provisioning enables. Useful when SSH is broken. Log in with the
  `dev` account and the generated password.
* **Graphical console** (optional, if you ever want it):
  ```bash
  virsh -c qemu:///system shutdown dev-vm
  virt-xml dev-vm --add-device --graphics spice,listen=127.0.0.1
  virt-xml dev-vm --add-device --video qxl
  virsh -c qemu:///system start dev-vm
  ```

---

## What gets installed in the guest

`guest/provision-dev-tools.sh` runs on first boot, logs to
`/var/log/dev-vm-provision.log`, and writes `/etc/dev-vm-provision.complete` on
success.

* **Build / VCS** — `base-devel`, `git`, `cmake`, `ninja`, `clang`, `gdb`, `strace`
* **Editors & shell** — `neovim`, `vim`, `tmux`, `zsh`, `direnv`, `git-delta`
* **CLI** — `curl`, `wget`, `rsync`, `jq`, `ripgrep`, `fd`, `fzf`, `tree`,
  `unzip`, `which`, `htop`, `btop`, `less`, `man-db`
* **Languages** — `python` (+ pip, virtualenv), `nodejs` + `npm`, `go`,
  `rustup` (with the stable toolchain fetched)
* **Containers** — `docker` (+ compose, buildx), enabled and the `dev` user
  added to the `docker` group
* **Linting** — `shellcheck`, `shfmt`
* **DeepSeek Harness** — `@deepseek-ai/dsh` (npm global) plus `pnpm`, which DSH
  profiles need. Controlled by `GUEST_INSTALL_DSH` / `GUEST_INSTALL_PNPM`.

The DSH install is deliberately a **plain** `npm install -g`. npm 12 blocks
package install scripts by default, and that is fine here — `node-pty` and
`koffi` ship prebuilt platform binaries, and on linux-x64 `node-pty` has no
separate `spawn-helper` for the blocked postinstall to chmod. This was verified
by spawning a real pty after exactly that install, not merely by checking that
the modules load.

It also locks the image's built-in `arch` account, enables
`qemu-guest-agent`, `sshd` and the serial getty, and runs a full `pacman -Syu`
first (never install into a partially-upgraded rolling release).

The script is **idempotent** — re-run it any time:

```bash
ssh dev-vm 'sudo /usr/local/sbin/provision-dev-tools.sh'
```

To trim or extend the list, edit the `PKGS` array in
[`guest/provision-dev-tools.sh`](guest/provision-dev-tools.sh) and recreate the
VM, or edit it in place and re-run.

Docker group membership needs a fresh login inside the guest to take effect.

---

## Configuration (`vm.conf`)

| Setting | Default | Meaning |
|---|---|---|
| `VM_NAME` | `dev-vm` | libvirt domain name, also the SSH alias |
| `VM_USER` | `dev` | account created inside the guest |
| `VM_VCPUS` | `6` | vCPUs (host has 12 threads) |
| `VM_RAM_MB` | `12288` | 12 GiB (host has ~31 GiB) |
| `VM_DISK_GB` | `120` | virtual disk size, sparse |
| `VM_MAC` / `VM_IP` | `52:54:00:1d:00:01` / `192.168.122.50` | fixed lease |
| `VM_NETWORK` | `default` | libvirt NAT network |
| `GUEST_DEV_TOOLS` | `true` | `false` = bare VM |
| `GUEST_ENABLE_DOCKER` | `true` | install + enable Docker |
| `GUEST_ENABLE_PODMAN` | `false` | also install Podman/Buildah/Skopeo |

Resource changes require recreating the domain (edit `vm.conf`, `3-vmctl.sh
destroy`, `2-create-vm.sh`). CPU/RAM alone can be changed live:

```bash
virsh -c qemu:///system setvcpus dev-vm 8 --config --maximum
virsh -c qemu:///system setvcpus dev-vm 8 --config
virsh -c qemu:///system setmem  dev-vm 16GiB --config
```

---

## Optional: CachyOS repositories in the guest

```bash
./4-add-cachyos-repos.sh
```

Runs the vendor script from `mirror.cachyos.org` over an interactive SSH
session. It replaces many packages with the x86-64-v3/v4 rebuilds and offers the
CachyOS kernel. It is a large, one-way migration (~1–2 GB) — a stock Arch VM is
already fine for development, so this is genuinely optional.

Because the host uses `--cpu host-passthrough`, the guest sees the host's real
instruction set, so the migration script can detect v3/v4 correctly. Check
inside the guest with:

```bash
/lib/ld-linux-x86-64.so.2 --help | grep supported
```

---

## Adding a shared folder

You said you would not need to share anything, so **nothing is shared by
default**. If you change your mind, `virtiofs` is the fast option:

```bash
# 1. define the share on the host
virt-xml dev-vm --add-device \
  --filesystem /home/$USER/Documents/deepseek,mount_tag=hostshare,driver.type=virtiofs

# 2. inside the guest, mount it
ssh dev-vm 'sudo mkdir -p /mnt/hostshare && sudo mount -t virtiofs hostshare /mnt/hostshare'
```

To make it permanent, add it to the guest's `/etc/fstab`:

```
hostshare  /mnt/hostshare  virtiofs  defaults,_netdev  0 0
```

An NFS or SSHFS mount over the libvirt network also works and needs no domain
changes.

---

## Security notes

* The seed ISO (and `seed/user-data`, mode `0600`) contains the console password
  and your public key. It stays attached as a CD-ROM. After the first successful
  boot you can detach it:

  ```bash
  virsh -c qemu:///system change-media dev-vm sda --eject --config
  ```

  (Confirm the target name with `virsh -c qemu:///system domblklist dev-vm`.)
* SSH password authentication is disabled in the guest; the password is only for
  the local/serial console.
* The guest has passwordless `sudo` for `VM_USER`. That is convenient and normal
  for a development VM; tighten it in `cloud-init/user-data.tmpl` if you care.
* The VM sits behind libvirt's NAT. It can reach your LAN and the internet; your
  LAN cannot reach it unless you add port forwards or switch to bridged
  networking.
* `credentials.txt` is root-only (`0600`).

---

## Troubleshooting

**`pacman` fails with `breaks dependency 'X=1.2.3' required by Y`**
This is a *partial upgrade*: Arch is rolling, so new packages expect the whole
system to move together. Two distinct causes, and `1-setup-host.sh` diagnoses
which one you have:

*Your system is simply behind.* The script offers to run `pacman -Syu` first.
Accept it — installing new packages onto an out-of-date system is unsupported.

*An orphan is jamming the upgrade.* A package left behind by a removed stack
(often a `lib32-*` leftover from a deleted Steam/Wine installation) pins an exact
version of something waiting to be upgraded, so `pacman -Syu` can never finish.
The script names the culprit and prints the exact fix. Find them yourself with:

```bash
pacman -Qtdq                                   # all orphaned packages
pacman -Qi <pkg> | grep -E 'Required By|Depends On'
```

If `Required By: None` and the pinned package is upgradeable, removal is safe:

```bash
sudo pacman -R <pkg>
sudo pacman -Syu
```

A package that **no longer exists in any repo** can never be updated again, so it
will block that upgrade forever — removing it is the only fix. Example seen on
this machine: `lib32-libpcap` pinned `libpcap=1.10.6` and had been dropped from
multilib.

*A repository desync.* If the offending package is *not* an orphan, the mirror
is mid-update (a `lib32-*` rebuild often lags its 64-bit counterpart). Wait a few
hours and retry; `sudo pacman -Syyu` first if your databases look stale
(compare `stat -c '%n %y' /var/lib/pacman/sync/*.db`).

**`Unable to create bridge virbr0: Package not installed`**
This is not about a missing package. It is the kernel's `ENOPKG` error surfacing
through libvirt because the `bridge` module **cannot be loaded**. The usual cause
is that `pacman -Syu` upgraded the kernel and removed the module tree for the
kernel you are still running:

```bash
uname -r                          # e.g. 7.2.3-arch1-3
ls /lib/modules/                  # e.g. 7.2.7-arch1-1  7.2.8-1-cachyos
lsmod | grep '^bridge'            # not loaded
modinfo bridge                    # Module not found
```

Check directly:

```bash
[ -d "/lib/modules/$(uname -r)" ] && echo fine || echo "REBOOT NEEDED"
```

**Reboot**, then re-run `1-setup-host.sh`. `1-setup-host.sh` now detects this at
startup, so you get a clear message instead of the misleading libvirt one. No
kernel module can be loaded until you reboot — this also affects anything else
needing a module you have not already loaded.

**`/dev/kvm` missing or `KVM is not available`**
Enable SVM/VT-x in firmware. Check `ls -l /dev/kvm` and `lsmod | grep kvm`.
Inside a VM, enable nested virtualisation on the outer hypervisor.

**`Cannot talk to libvirtd` / permission denied from `3-vmctl.sh`**
Your `libvirt` group membership is not active in this session. Log out and back
in, or run `newgrp libvirt`. Check with `virsh -c qemu:///system version`.

**The VM has no internet**
`1-setup-host.sh` should have configured the backend and ufw. Verify:
```bash
virsh -c qemu:///system net-info default
sudo iptables -t nat -L POSTROUTING -n | head
sudo ufw route allow from 192.168.122.0/24   # only if ufw is active
```

**Cannot find the VM's IP**
```bash
virsh -c qemu:///system domifaddr dev-vm --source agent   # needs the guest agent
virsh -c qemu:///system domifaddr dev-vm --source lease   # needs dnsmasq
./3-vmctl.sh status
```

**SSH times out but the domain is running**
Use the console: `./3-vmctl.sh console` (Ctrl+] to leave). Check
`systemctl status sshd` and `cloud-init status --long` inside the guest.

**Provisioning did not finish**
```bash
ssh dev-vm 'cloud-init status --long; tail -100 /var/log/dev-vm-provision.log'
ssh dev-vm 'sudo /usr/local/sbin/provision-dev-tools.sh'   # re-run it
```
The marker is `/etc/dev-vm-provision.complete`.

**The console shows nothing**
The serial getty is enabled by cloud-init; if provisioning never ran you will
not see a login prompt until the guest finishes booting. `Ctrl+]` detaches.

**Boot drops to the UEFI shell**
The Arch cloud image boots via the firmware fallback path
`\EFI\BOOT\BOOTX64.EFI`, which is present. If you replaced the disk image, make
sure `--boot uefi` with `--machine q35` is still in use.

**`2-create-vm.sh` says the domain already exists**
That is expected and protective — it will not overwrite a running VM. Pick one:

* **Finish the bookkeeping** if a previous run was interrupted (Ctrl+C) after the
  domain came up. This writes the SSH alias and `credentials.txt` without
  touching the VM:
  ```bash
  sudo ./2-create-vm.sh --adopt
  ```
* **Start over**: `./3-vmctl.sh destroy`, then `sudo ./2-create-vm.sh`
  (or pick a different `VM_NAME` in `vm.conf`).

---

## Reproducing this from scratch

This table is deliberately explicit about what is **not** automated, so a rebuild
cannot silently lose something.

| Step | Reproducible? | How |
|---|---|---|
| Host libvirt/KVM stack, ufw, groups | ✅ | `sudo ./1-setup-host.sh` |
| NAT network + static DHCP lease | ✅ | `1-setup-host.sh` |
| VM image, disk, cloud-init seed, domain | ✅ | `sudo ./2-create-vm.sh` |
| Guest toolchain (43 packages + Rust) | ✅ | cloud-init → `provision-dev-tools.sh` |
| Guest Docker | ✅ | enabled at first boot; starts once the guest kernel is loaded |
| Guest DSH CLI + pnpm | ✅ | `GUEST_INSTALL_DSH` / `GUEST_INSTALL_PNPM` |
| SSH key, `~/.ssh/config` alias, `credentials.txt` | ✅ | `2-create-vm.sh` (or `--adopt`) |
| Browser access to the VM's DSH UI | ✅ | `./dsh-web.sh start` |
| **Your DSH API key** | ❌ **manual** | by design — add it in the web UI (persists to the guest's `~/.dsh/.credentials.yaml`), or via `~/.config/dsh/env` |
| **Guest git identity** | ❌ manual | `ssh dev-vm 'git config --global user.name "..." && git config --global user.email "..."'` |
| CachyOS repos + kernel | ⚠️ optional | `./4-add-cachyos-repos.sh` — **written but never executed**, treat as unverified |

A clean rebuild:

```bash
sudo ./1-setup-host.sh
#   log out and back in (libvirt group)
sudo ./2-create-vm.sh          # ~10-15 min: download, boot, provision
ssh dev-vm 'sudo reboot'       # ONLY if the guest upgraded its kernel
./dsh-web.sh start             # browser UI
```

Two things that are **not** reproducible by re-running the scripts, because they
are stateful choices rather than build steps:

* **The API key**, which lives in the guest's credential store. Recreating the VM
  loses it — you re-enter it once.
* **Anything you install or write inside the guest** after provisioning. The
  guest disk is the only copy; the baseline copy described in Troubleshooting is
  what protects it.

## Uninstalling

```bash
./3-vmctl.sh destroy                                    # domain, disk, SSH alias
sudo rm -rf /var/lib/libvirt/images/cloud-images        # cached base images
sudo pacman -Rns qemu-full virt-manager virt-install libvirt \
                 edk2-ovmf dnsmasq swtpm libosinfo cloud-image-utils
sudo usermod -aG libvirt --del $USER 2>/dev/null || sudo gpasswd -d $USER libvirt
```

The generated key `~/.ssh/dev-vm_ed25519` is intentionally left in place.

---

## References

* [CachyOS — QEMU and VMM Setup](https://wiki.cachyos.org/virtualization/qemu_and_vmm_setup)
* [CachyOS — Optimized Repositories](https://wiki.cachyos.org/features/optimized_repos/)
* [Arch Linux cloud images](https://geo.mirror.pkgbuild.com/images/latest/)
* [cloud-init NoCloud datasource](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html)
* [libvirt domain XML format](https://libvirt.org/formatdomain.html)
