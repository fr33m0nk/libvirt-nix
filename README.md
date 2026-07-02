# libvirt-nix — NixOS dev VM under libvirt/KVM (RK3588 big.LITTLE)

The **libvirt** variant of the dev VM, for the Armbian/Debian host on a Radxa Rock 5
ITX (RK3588). It exists for one reason Lima can't satisfy: **one KVM guest spanning
all 8 cores** (4× A76 + 4× A55). Lima lets vCPU threads float, which crashes on
RK3588 with `Failed to put registers after init` (the per-vCPU CCSIDR cache register
can't be set when a thread migrates between clusters). libvirt fixes this by applying
**1:1 `vcpupin`** during its paused (`-S`) startup, *before* register init — proven
working in the `virt-install` boot test (8 vCPUs, no crash).

Same Clojure/Emacs toolchain as `../nixos` (`home.nix` + `dot-spacemacs.el` are
copied verbatim). The difference is all in the host/boot layer: **no Lima, no
nixos-lima** — it's a plain NixOS guest plus a libvirt domain.

## Prerequisites

### Required: `NIXOS_USER` environment variable
All scripts and the flake require `NIXOS_USER` to be set. This is the username
created inside the VM — no default, no fallback. Set it in your shell profile:
```bash
export NIXOS_USER=prashantsinha
```
Without this, `nix build`, `nixos-rebuild`, and `./setup-libvirt-vm.sh` will
exit with an error immediately.

### Two build modes
The flake supports two configurations:
- **`libvirt-vm-aarch64`** — Full image built from scratch via `make-disk-image`
  (systemd-boot). Use with `./setup-libvirt-vm.sh` (no `--base-image` flag).
- **`libvirt-vm-aarch64-base`** — Targets the pre-built nixos-libvirt qcow2
  (GRUB, `/dev/vda1` /boot). Use with `./setup-libvirt-vm.sh --base-image <qcow2>`.
  This is the recommended path — skip the heavy image build, boot immediately.

## Files
| File | Role |
|---|---|
| `flake.nix` | nixosConfigurations + a `qcow` image output (`make-disk-image`). Carries the heroku + tuned clojure-lsp overlays. |
| `configuration.nix` | NixOS system (systemd-boot variant): user, sshd, DHCP, virtiofs, docker, nix-ld. |
| `configuration-libvirt-base.nix` | NixOS system (GRUB variant): targets nixos-libvirt base image. Same packages, different boot layout. |
| `home.nix`, `dot-spacemacs.el` | user toolchain (emacs-git-nox, clojure-lsp, docker, Spacemacs). |
| `ssh-authorized-key.pub` | your SSH **public** key(s), read at build time — **gitignored** (create from `.example`). |
| `domain.xml` | libvirt domain: **`<cputune>` 1:1 vcpupin**, host-passthrough CPU, virtiofs, macvtap NIC, UEFI, console, guest-agent, memballoon. `@PLACEHOLDERS@` filled by the script. |
| `install-host-deps.sh` | one-shot host bootstrap: apt deps (libvirt/QEMU/AAVMF/virtiofsd/cachix) + Nix + groups + nix.conf with Cachix substituters. |
| `setup-libvirt-vm.sh` | Build or copy image → stage disk/nvram → fill template → `virsh define`/`start` → post-boot checks (virtiofs, Cachix cache reachability). |
| `push-to-cache.sh` | Build the full system closure on the host and push to `fr33m0nk.cachix.org`. One-time 1-2 hour build. |
| `.cachix-token` | Cachix auth token with write scope — **gitignored**, read by the VM via virtiofs for auto-push after rebuilds. |

## Prerequisites (host)

### 0. Put the Nix store on the data disk — do this FIRST
The SBC's root filesystem is small, but the Nix store is large (system closure +
emacs build + clojure-lsp native-image). Bind-mount `/nix` onto the big OMV data
disk **before** installing Nix, so the store lands there:
```bash
DATA=/srv/dev-disk-by-uuid-235804a3-605d-49e1-877d-4b4dd8f07f06   # your data disk

sudo mkdir -p /nix "$DATA/nix"
sudo chown root:root "$DATA/nix"

# persist the bind mount (ordered AFTER the data disk is mounted), then activate it:
echo "$DATA/nix  /nix  none  bind,x-systemd.requires-mounts-for=$DATA  0  0" \
  | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /nix
findmnt /nix                  # confirm /nix is a bind mount onto the data disk
```
Notes on the commands (vs. common copy-paste mistakes): `chown` needs an owner
(`root:root`); `tee -a` takes content on **stdin** (`echo … | sudo tee -a`), not as
an argument; and the live `sudo mount /nix` is required — without it the Nix
installer would populate `/nix` on the small root fs. The
`x-systemd.requires-mounts-for` option keeps the bind from racing the data disk at
boot (so `nix-daemon` never starts on an empty `/nix`).

### 1. Install everything
One script installs the rest — libvirt, QEMU, AAVMF firmware, `virtiofsd`,
`ipxe-qemu`, `cloud-image-utils`, `acl`, **and Nix** (needed to build the image on
the host) — and wires up groups + flakes + the nix-community cache:
```bash
./install-host-deps.sh
# then log out/in (for the libvirt/kvm groups + Nix profile)
export LIBVIRT_DEFAULT_URI=qemu:///system
```

Verify the store really landed on the data disk:
```bash
df -h /nix                                                  # should show the data disk
nix --extra-experimental-features nix-command config show | grep -i '^store'
```
No host bridge needed — the default networking is **macvtap** onto the host NIC
(the VM gets a real LAN IP directly). See Networking below for the trade-off and the
bridge/NAT alternatives.

## First-time bring-up

### Base image mode (recommended — fast, no compilation)
Uses the pre-built nixos-libvirt qcow2 as the boot disk. The VM boots in ~30s.
Then `nixos-rebuild` applies the full dev toolchain (~1-2h on RK3588, one-time).

0. **Set `NIXOS_USER`** (required, no default):
   ```bash
   export NIXOS_USER=prashantsinha
   ```
1. **Install host deps** (run once):
   ```bash
   cd libvirt-nix
   ./install-host-deps.sh
   # log out/in to apply groups + Nix profile
   ```
2. **Create `ssh-authorized-key.pub`** with your SSH *public* key (one per line) —
   it's gitignored. The build **halts with an error** if missing.
   ```bash
   cp ssh-authorized-key.pub.example ssh-authorized-key.pub
   ```
3. **Add your Cachix push token** (optional — enables binary cache uploads):
   ```bash
   echo "<your-cachix-write-token>" > .cachix-token
   ```
4. **Run the setup** with a pre-built qcow2:
   ```bash
   ./setup-libvirt-vm.sh --base-image ../nixos-libvirt/release-v0.0.3-images/nixos-libvirt-v0.0.3-aarch64.qcow2
   ```
   The script: copies + resizes the qcow2 → boots the VM → sets up virtiofs /
   verifies Cachix → prints `nixos-rebuild` instructions.
5. **Follow the on-screen instructions** to `virsh console` in, verify Cachix,
   and run `nixos-rebuild switch` (1-2h, one-time).
6. **After rebuild**: built packages are auto-pushed to Cachix on subsequent
   switches. For the first build, run manually:
   ```bash
   sudo systemctl start cachix-push.service
   ```

### Build-from-source mode
Builds the qcow2 from scratch using `make-disk-image` (requires KVM).
Slow but self-contained.

1. **Verify the core map** matches `domain.xml`'s `<cputune>`: `lscpu -e`.
2. Run it:
   ```bash
   export NIXOS_USER=prashantsinha
   cd libvirt-nix
   ./setup-libvirt-vm.sh
   ```
3. Verify:
   ```bash
   virsh vcpupin lc-nix-libvirt              # 0->0 .. 7->7
   virsh console lc-nix-libvirt              # login, then: nproc → 8, df -h /
   virsh domifaddr lc-nix-libvirt --source agent   # the LAN IP (see below)
   ```

## Finding the VM's IP (to SSH from your laptop)
`configuration.nix` assigns a **static IP** (default `192.168.29.45` on `enp2s0`,
gateway `192.168.29.1`, DNS `192.168.29.240`), so you normally just:
```bash
ssh username@192.168.29.45
```
**Adjust those values for your LAN** (IP/gateway/DNS, and the interface name if the
NIC enumerates differently — `ip -br link`). If you'd rather use DHCP, set
`networking.useDHCP = true` and drop the static block; then discover the address —
with **macvtap** the lease comes from your router, so libvirt's default
`--source lease` shows **nothing**, and you use the guest agent or host ARP table:
```bash
export LIBVIRT_DEFAULT_URI=qemu:///system

virsh domifaddr lc-nix-libvirt --source agent   # via qemu-guest-agent (needs VM booted + agent up)
virsh domifaddr lc-nix-libvirt --source arp     # via the host ARP table (fallback)
```
Most reliable — read it from inside the guest via the console:
```bash
virsh console lc-nix-libvirt        # login as username
ip -br addr                         # shows the interface + its 192.168.x.x LAN IP
#   leave console: Ctrl + ]
```
Then SSH from your Mac (your default key is already authorized):
```bash
ssh username@<that-ip>
```
Note: the **OMV host itself can't** SSH the VM over macvtap (kernel limitation) —
use `virsh console` from the host; your laptop and other LAN machines are fine.

## Changing config later (in place — state preserved)
The flake dir is virtiofs-shared at `/mnt/nixos-config`, so edit the `.nix` files on
the host and rebuild inside the VM:
```bash
ssh ${NIXOS_USER:-username}@<vm-ip>
sudo NIXOS_USER=prashantsinha nixos-rebuild switch --impure --flake path:/mnt/nixos-config#libvirt-vm-aarch64-base
```
(`NIXOS_USER=` is passed inline — `sudo -E` doesn't forward custom variables on NixOS.
`--impure` is required so Nix can read `NIXOS_USER` from the environment.
`path:` — not `.#` — so the untracked `ssh-authorized-key.pub` is visible to the
rebuild; a plain git flake ref would exclude it and the build would error.)
Re-run `setup-libvirt-vm.sh` only to rebuild the base image from scratch (wipes VM
state — projects, ~/.emacs.d, docker images).

## Stopping / deleting the VM
`export LIBVIRT_DEFAULT_URI=qemu:///system` first.

**Just stop it** (keep the disk; restart later with `virsh start lc-nix-libvirt`):
```bash
virsh shutdown lc-nix-libvirt      # graceful (ACPI/guest-agent)
virsh destroy  lc-nix-libvirt      # or force, if it won't respond
```

**Fully delete it** (stop + remove definition, nvram, and disk):
```bash
virsh destroy  lc-nix-libvirt 2>/dev/null            # must be off before undefine
virsh undefine --nvram lc-nix-libvirt                # remove domain + UEFI varstore
sudo rm -f /var/lib/libvirt/images/lc-nix-libvirt.qcow2
sudo rm -f /var/lib/libvirt/images/lc-nix-libvirt_VARS.fd   # if --nvram left it
virsh list --all                                     # confirm it's gone
```
One-shot alternative for the disk: `virsh undefine --nvram --remove-all-storage
lc-nix-libvirt` (removes the attached disk too, if libvirt tracks it as a pool
volume). Paths match the script's `${IMG_DIR}/${NAME}.qcow2` — adjust if you
overrode them. This touches only the VM + its disk, not the `libvirt-nix/` files or
the Nix store; re-run `setup-libvirt-vm.sh` to recreate it fresh.

## Networking
- **Default = macvtap** (`<interface type='direct'>` onto the host NIC): the VM gets
  a real LAN IP from your router, reachable from the laptop, with **no host bridge**
  — nothing for OpenMediaVault's network management to clash with. The script
  auto-detects the NIC (override `NIC=eth0 ./setup-libvirt-vm.sh`).
  **Caveat 1:** the OMV host itself can't reach the VM over macvtap (kernel
  limitation); other LAN machines can. Manage it from the host via `virsh console`.
  **Caveat 2:** IPv6 is **permanently disabled** in the guest — it resolves AAAA
  records but cannot route TCP through this macvtap (verified: `curl -6` fails
  with "Network is unreachable" to all destinations). IPv4-only.
- **Alternative A — host bridge** (host *can* reach the VM): create the bridge in the
  OMV web UI (Network → Interfaces → Bridge), then swap `domain.xml` to the
  `type='bridge'` block.
- **Alternative B — libvirt NAT**: swap to the `network='default'` block and
  `virsh net-start default` (define it first if missing). Reach via host/portForward.

## Cachix binary cache
Heavy packages (emacs, clojure-lsp native-image) are built on GitHub Actions
(`nixos-libvirt` repo, `toolchain-cache` branch) and pushed to
`https://fr33m0nk.cachix.org`. The VM's Nix config includes this cache as a
substituter — `nixos-rebuild` will **download** pre-built binaries instead of
compiling them (~5 min instead of 1-2 hours).

First-time cache priming:
```bash
./push-to-cache.sh   # builds full closure on the host, pushes to Cachix
```

Subsequent rebuilds push automatically via `cachix-push.service` (runs after
every `nixos-rebuild switch`). Requires `.cachix-token` with write scope on
virtiofs (gitignored).

## VERIFY checklist (build-from-source mode only)
- `make-disk-image` arg names match this nixpkgs pin — if `nix build .#qcow`
  errors, check `<nixpkgs>/nixos/lib/make-disk-image.nix`.
- Disk labels: after first boot `lsblk -f` — root should be `nixos`, ESP `ESP`;
  adjust `configuration.nix` `fileSystems` if make-disk-image used others.
- AAVMF paths exist (`/usr/share/AAVMF/AAVMF_{CODE,VARS}.fd`); the script falls
  back to `qemu-efi-aarch64/QEMU_EFI.fd`.
- macvtap NIC auto-detected correctly (`ip -br link`).
- Static IP in `configuration.nix` (`enp2s0` at `192.168.29.45`) matches your
  LAN — a wrong name leaves the VM with no network (recover via `virsh console`).
- vcpupin holds + guest is **stable under 8-way load** (`stress-ng --cpu 8`).
- qemu runs the disk OK from `/var/lib/libvirt/images` (avoid `$HOME` — the
  `libvirt-qemu` user can't traverse a `700` home dir).
- Cachix: `nix store info --store https://fr33m0nk.cachix.org` from inside the VM.
