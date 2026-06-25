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

## Files
| File | Role |
|---|---|
| `flake.nix` | nixosConfigurations + a `qcow` image output (`make-disk-image`). Carries the heroku + tuned clojure-lsp overlays. |
| `configuration.nix` | NixOS system: UEFI boot, user, sshd, DHCP, virtiofs mount, rootless docker, nix-ld, qemu-guest-agent. |
| `home.nix`, `dot-spacemacs.el` | user toolchain (copied from `../nixos`, unchanged). |
| `ssh-authorized-key.pub` | your SSH **public** key(s), read at build time — **gitignored** (create from `.example`). |
| `domain.xml` | libvirt domain: **`<cputune>` 1:1 vcpupin**, host-passthrough CPU, virtiofs, macvtap NIC, UEFI, console, guest-agent. `@PLACEHOLDERS@` filled by the script. |
| `install-host-deps.sh` | one-shot host bootstrap: apt deps (libvirt/QEMU/AAVMF/virtiofsd/ipxe-qemu/…) + Nix + groups + nix.conf. |
| `setup-libvirt-vm.sh` | build image → stage disk/nvram → fill template → `virsh define`/`start`. |

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
1. **Create `ssh-authorized-key.pub`** with your SSH *public* key (one per line) —
   it's gitignored, kept out of the repo. The build **halts with an error** if it's
   missing.
   ```bash
   cp ssh-authorized-key.pub.example ssh-authorized-key.pub
   # then paste your key, or on your laptop:  cat ~/.ssh/id_rsa.pub
   ```
2. **Verify the core map** matches `domain.xml`'s `<cputune>`: `lscpu -e` (A76 ≈ 2.2–2.4 GHz). 1:1 across `0-7` is the requirement; the cpuset numbers just need to be every physical core.
3. Run it (no `taskset` — libvirt does the pinning via `<cputune>`):
   ```bash
   cd libvirt-nix
   ./setup-libvirt-vm.sh
   ```
4. Verify:
   ```bash
   virsh vcpupin lc-nix-libvirt              # 0->0 .. 7->7
   virsh console lc-nix-libvirt              # login, then: nproc → 8, df -h /
   virsh domifaddr lc-nix-libvirt --source agent   # the LAN IP (see below)
   ```

## Finding the VM's IP (to SSH from your laptop)
With **macvtap** the DHCP lease comes from your LAN router, so libvirt's default
`--source lease` shows **nothing**. Use the guest agent or the host ARP table:
```bash
export LIBVIRT_DEFAULT_URI=qemu:///system

virsh domifaddr lc-nix-libvirt --source agent   # via qemu-guest-agent (needs VM booted + agent up)
virsh domifaddr lc-nix-libvirt --source arp     # via the host ARP table (fallback)
```
Most reliable — read it from inside the guest via the console:
```bash
virsh console lc-nix-libvirt        # login as prashantsinha
ip -br addr                         # shows the interface + its 192.168.x.x LAN IP
#   leave console: Ctrl + ]
```
Then SSH from your Mac (your default key is already authorized):
```bash
ssh prashantsinha@<that-ip>
```
Note: the **OMV host itself can't** SSH the VM over macvtap (kernel limitation) —
use `virsh console` from the host; your laptop and other LAN machines are fine.

## Changing config later (in place — state preserved)
The flake dir is virtiofs-shared at `/mnt/nixos-config`, so edit the `.nix` files on
the host and rebuild inside the VM:
```bash
ssh prashantsinha@<vm-ip>
sudo nixos-rebuild switch --flake path:/mnt/nixos-config#libvirt-vm-aarch64
```
(`path:` — not `.#` — so the untracked `ssh-authorized-key.pub` is visible to the
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
  **Caveat:** the OMV host itself can't reach the VM over macvtap (kernel
  limitation); other LAN machines can. Manage it from the host via `virsh console`.
- **Alternative A — host bridge** (host *can* reach the VM): create the bridge in the
  OMV web UI (Network → Interfaces → Bridge), then swap `domain.xml` to the
  `type='bridge'` block.
- **Alternative B — libvirt NAT**: swap to the `network='default'` block and
  `virsh net-start default` (define it first if missing). Reach via host/portForward.

## VERIFY checklist (things I couldn't test from the dev machine)
- [ ] `make-disk-image` arg names match this nixpkgs pin (if `nix build .#qcow`
      errors on an unknown arg, check `<nixpkgs>/nixos/lib/make-disk-image.nix`).
- [ ] Disk labels: after first boot `lsblk -f` — root should be `nixos`, ESP `ESP`;
      adjust `configuration.nix` `fileSystems` if make-disk-image used others.
- [ ] AAVMF paths exist (`/usr/share/AAVMF/AAVMF_{CODE,VARS}.fd`); the script falls
      back to `qemu-efi-aarch64/QEMU_EFI.fd` (which may not split VARS — adjust).
- [ ] macvtap NIC auto-detected correctly (`ip -br link`); the host won't be able to
      SSH the VM over macvtap (use `virsh console`) — switch to an OMV bridge if you
      need host→VM access.
- [ ] vcpupin holds + guest is **stable under 8-way load** (`stress-ng --cpu 8`),
      not just at idle — the register issue is at init, but confirm cross-cluster
      scheduling doesn't wobble under real builds.
- [ ] qemu runs the disk OK from `/var/lib/libvirt/images` (avoid `$HOME` — the
      `libvirt-qemu` user can't traverse a `700` home dir).

## What's gained vs the Lima variant
- All 8 cores in one VM (vs Lima's single-cluster `taskset -c 4-7`).
- No lima-guestagent → the host↔guest version-mismatch problem disappears.
- macvtap NIC → real LAN IP, no port-forward gymnastics, no host bridge to build.
- Trade-off: you maintain the libvirt domain + image build yourself instead of
  Lima's one-command lifecycle.
