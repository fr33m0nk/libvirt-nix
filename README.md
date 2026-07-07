# libvirt-nix — NixOS dev VM under libvirt/KVM (RK3588 big.LITTLE)

The **libvirt** variant of the dev VM, for the Armbian/Debian host on a Radxa Rock 5
ITX (RK3588). It exists for one reason Lima can't satisfy: **a KVM guest with vCPUs
pinned across both clusters** (A76 + A55). Lima lets vCPU threads float, which crashes
on RK3588 with `Failed to put registers after init` (the per-vCPU CCSIDR cache register
can't be set when a thread migrates between clusters). libvirt fixes this by applying
**1:1 `vcpupin`** during its paused (`-S`) startup, *before* register init.

The tuned layout is a **2+2 dedicated-core split**: the VM gets 4 vCPUs pinned 1:1 to
*isolated* host cores — 2 little (A55) + 2 big (A76) — while the host keeps the other
4 cores for itself (ZFS/NAS/Docker) and QEMU's emulator/IO threads. See
[Performance tuning](#performance-tuning-rk3588-biglittle) for the full rationale and
the host setup it depends on (governor, `isolcpus`, hugepages, guest core-preference).

Same Clojure/Emacs toolchain as `../nixos` (`home.nix` + `dot-spacemacs.el` are
copied verbatim). The difference is all in the host/boot layer: **no Lima, no
nixos-lima** — it's a plain NixOS guest plus a libvirt domain.

## Prerequisites



created inside the VM — no default, no fallback. Set it in your shell profile:
```bash

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
| `secrets/ssh-authorized-key.pub` | your SSH **public** key(s), read at build time — **gitignored** (create from `.example`). |
| `domain.xml` | libvirt domain: **`<cputune>` 2+2 1:1 vcpupin** (vcpu0,1→A55 cores 2,3; vcpu2,3→A76 cores 6,7; emulator+IOThread on host cores 0-1; 2-cluster topology; 12 GiB backed by 2 MiB hugepages; FIFO `vcpusched` commented — see Phase 2), host-passthrough CPU, virtiofs, macvtap NIC, UEFI, console, guest-agent, memballoon. `@PLACEHOLDERS@` filled by the script. |
| `install-host-deps.sh` | one-shot host bootstrap: apt deps (libvirt/QEMU/AAVMF/virtiofsd/cachix) + Nix + groups + nix.conf with Cachix substituters + **big.LITTLE tuning** (CPU governor unit; prints the `isolcpus`/`hugepages` cmdline to add). |
| `setup-libvirt-vm.sh` | Build or copy image → stage disk/nvram → fill template → host pre-flight → `virsh define`/`start` → post-boot checks. `--redefine` re-applies `domain.xml` to an existing VM (no rebuild, state preserved). |
| `push-to-cache.sh` | Build the full system closure on the host and push to `fr33m0nk.cachix.org`. One-time 1-2 hour build. |
| `secrets/.cachix-token` | Cachix auth token with write scope — **gitignored**, read by the VM via virtiofs for auto-push after rebuilds. |

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

## Performance tuning (RK3588 big.LITTLE)

The VM is tuned as a **2+2 dedicated-core split**. The RK3588 is big.LITTLE —
A55 (little) = host `cpu0-3`, A76 (big) = host `cpu4-7`:

```
                cpu0  cpu1  cpu2  cpu3   cpu4  cpu5  cpu6  cpu7
cluster          A55   A55   A55   A55    A76   A76   A76   A76
owner           host  host   VM    VM    host  host   VM    VM
guest vcpu        -     -    0     1      -     -     2     3
```

The 4 VM cores (2,3,6,7) are **isolated from the host scheduler** (`isolcpus`) so
nothing on the host (ZFS/NAS/Docker) can preempt the pinned vCPUs. The host keeps
cpu0,1 + cpu4,5 for itself *and* for QEMU's emulator/IO threads (pinned to 0-1).
Four independent levers make this work:

1. **CPU governor → `performance`** (host). Keeps the A76 cluster at its ~2.256 GHz
   ceiling instead of clocking down on bursty LSP/compile loads. Applied by
   `install-host-deps.sh` (a `cpu-performance.service` oneshot re-runs it every boot;
   `cpufrequtils.service` is masked on Armbian).
2. **Core isolation** (`isolcpus=managed_irq,domain,2,3,6,7 nohz_full=2,3,6,7
   rcu_nocbs=2,3,6,7`, host kernel cmdline). Removes the VM cores from host load
   balancing. Set in the `extraargs=` line of `/boot/armbianEnv.txt`; needs a reboot.
   Note: `isolcpus` also pushes ZFS/kernel threads OFF these cores — stronger than a
   cgroup `AllowedCPUs` cpuset (which can't govern kernel threads).
3. **Hugepages** (host). The 12 GiB guest RAM is backed by 2 MiB hugepages to cut
   JVM/clojure-lsp TLB misses. Reserve on the kernel cmdline in the same `extraargs=`
   line: **`hugepages=6400`**. Reserve *more* than the exact guest size (6144 pages =
   12 GiB) — QEMU needs all 6144 **free at once** and the host always has a few in
   use, so an exactly-sized pool fails with *"unable to map backing store … Cannot
   allocate memory"*. 6400 gives ~256 pages of headroom. Reserving on the cmdline
   (vs `sysctl`) allocates early at boot before RAM fragments. Do **not** also set
   `vm.nr_hugepages` in `sysctl.d` — a sysctl runs *after* the cmdline and, if it
   disagrees, shrinks the pool back.
4. **Guest big-core preference by exclusion** (`configuration.nix`). QEMU `virt`
   passes no `capacity-dmips-mhz`, so the guest scheduler treats all 4 vCPUs as equal
   and would run hot threads on the slow A55 pair. Instead of exposing capacity, the
   guest confines background/system work to the little vCPUs (`system.slice`
   `AllowedCPUs=0-1`) and lets the interactive session reach all 4 (`user.slice`
   `AllowedCPUs=0-3`). The big cores (guest cpu2,3) stay idle, so the scheduler
   naturally migrates emacs/clojure-lsp onto them — while still able to spill down
   under load. nix builds are throughput work that *should* use the big cores, so
   `nix-daemon` is reparented into `nixbuild.slice` (`AllowedCPUs=0-3`) — cgroup v2
   won't let a child of the restricted `system.slice` widen back to the big cores.

**Full setup order** (levers 1-3 are host-side, one-time):
```bash
./install-host-deps.sh                       # installs the governor unit; prints the cmdline
# add the printed isolcpus/hugepages line to /boot/armbianEnv.txt, then:
sudo reboot
# verify the host is tuned:
cat /sys/devices/system/cpu/isolated         # 2-3,6-7
grep HugePages_Total /proc/meminfo           # 6400
lscpu -e                                      # A55=0-3 (~1800MHz), A76=4-7 (~2256MHz)
```
Lever 4 ships in `configuration.nix` / `configuration-libvirt-base.nix` and applies
on the next `nixos-rebuild switch` inside the guest.

**Applying `domain.xml` changes later** (CPU pinning, memory, hugepages, topology)
*without* rebuilding the image — preserves disk + NVRAM + guest state:
```bash
./setup-libvirt-vm.sh --redefine
```
This runs the host pre-flight, preserves the domain UUID (so `virsh define` updates
in place instead of colliding), cold-restarts the VM (memory/vcpu/topology changes
need a full boot), and prints the verification steps.

**Verify the VM layout** after start:
```bash
virsh vcpupin lc-nix-libvirt                 # 0->2  1->3  2->6  3->7
virsh iothreadinfo lc-nix-libvirt            # iothread 1 -> 0-1
virsh dominfo lc-nix-libvirt | grep -i memory   # 12 GiB
# in the guest — cpu2,3 MUST be the A76 (else flip the ranges in configuration.nix):
for c in 0 1 2 3; do printf 'cpu%s ' $c; \
  cat /sys/devices/system/cpu/cpu$c/regs/identification/midr_el1; done
#   cpu2,3 end ...d0b.. (A76) ; cpu0,1 end ...d05.. (A55)
systemctl show system.slice user.slice -p AllowedCPUs   # 0-1 and 0-3
```

### Phase 2 (optional, off by default): FIFO scheduling
`domain.xml` carries a commented `<vcpusched vcpus="2-3" scheduler="fifo"
priority="1"/>` for the A76 vCPUs — real-time scheduling to trim residual jitter.
It's **off** because it requires running QEMU as `root` (for `CAP_SYS_NICE`) and
dropping the `cpu` cgroup controller in `/etc/libvirt/qemu.conf` — a security
downgrade (loses the QEMU sandbox) for a small gain once the cores are already
isolated. Enable only if you still see latency spikes under load; steps are inline
in `domain.xml`.

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
2. **Create `secrets/ssh-authorized-key.pub`** with your SSH *public* key (one per line) —
   it's gitignored. The build **halts with an error** if missing.
   ```bash
   cp secrets/ssh-authorized-key.pub.example secrets/ssh-authorized-key.pub
   ```
3. **Add your Cachix push token** (optional — enables binary cache uploads):
   ```bash
   echo "<your-cachix-write-token>" > secrets/.cachix-token
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

1. **Verify the core map** matches `domain.xml`'s `<cputune>`: `lscpu -e`
   (A55=0-3, A76=4-7). Host tuning (governor/isolcpus/hugepages) must be in place
   first — see [Performance tuning](#performance-tuning-rk3588-biglittle).
2. Run it:
   ```bash
   export NIXOS_USER=prashantsinha
   cd libvirt-nix
   ./setup-libvirt-vm.sh
   ```
3. Verify:
   ```bash
   virsh vcpupin lc-nix-libvirt              # 0->2  1->3  2->6  3->7
   virsh iothreadinfo lc-nix-libvirt        # iothread 1 pinned to 0-1 (host cores)
   virsh console lc-nix-libvirt              # login, then: nproc → 4, df -h /
   virsh domifaddr lc-nix-libvirt --source agent   # the LAN IP (see below)
## Finding the VM's IP (to SSH from your laptop)
The VM uses **DHCP**, so the IP comes from your router. Static IP was not
possible — it broke IPv6 SLAAC on this macvtap setup. Find the address:
```bash
export LIBVIRT_DEFAULT_URI=qemu:///system

virsh domifaddr lc-nix-libvirt --source agent   # via qemu-guest-agent
virsh domifaddr lc-nix-libvirt --source arp     # via host ARP table (fallback)
```
or from inside the guest via console:
```bash
virsh console lc-nix-libvirt        # login as your user
ip -br addr                         # shows the LAN IP
```
Then connect from your laptop:
```bash
ssh username@<that-ip>
# or for a faster Emacs experience (predictive echo, roaming):
mosh --predict=experimental devenv -- bash -lic 'et'
```
Fish users — use functions (not aliases):
```fish
# ~/.config/fish/config.fish
function et
    mosh --predict=experimental devenv -- bash -lic 'et'
end
function eat
    mosh --predict=experimental devenv -- bash -lic 'et'
end

function heat
    mosh --predict=experimental devenv -- bash -lic 'eat'
end
```
For a **fixed IP**, configure a static DHCP lease on your router.
Static IP config is preserved in comments in the config files.
Note: the **OMV host itself can't** SSH the VM over macvtap (kernel limitation) —
use `virsh console` from the host; your laptop and other LAN machines are fine.

## Changing config later (in place — state preserved)
The flake dir is virtiofs-shared at `/mnt/nixos-config`, so edit the `.nix` files on
the host and rebuild inside the VM.

**Home-manager only** (dot-spacemacs.el, shell aliases, home packages):
```bash
ssh ${NIXOS_USER:-username}@<vm-ip>
home-manager switch --flake path:/mnt/nixos-config#prashantsinha@libvirt-vm-aarch64-base
```
Seconds — only rebuilds the user environment.

**Full system rebuild** (configuration.nix, new packages, kernel changes):
```bash
ssh ${NIXOS_USER:-username}@<vm-ip>
sudo nixos-rebuild switch --flake path:/mnt/nixos-config#libvirt-vm-aarch64-base
```
Fast when packages are cached via Cachix.
(`NIXOS_USER=` is passed inline — `sudo -E` doesn't forward custom variables on NixOS.
`--impure` is required so Nix can read `NIXOS_USER` from the environment.
`path:` — not `.#` — so the untracked `secrets/ssh-authorized-key.pub` is visible to the
rebuild.)
**Host-side domain changes** (`domain.xml`: CPU pinning, memory, hugepages, topology)
apply with `./setup-libvirt-vm.sh --redefine` — re-defines + cold-restarts the VM,
preserving disk/NVRAM/state (see
[Performance tuning](#performance-tuning-rk3588-biglittle)).

Re-run `setup-libvirt-vm.sh` (no flag / `--base-image`) only to rebuild the base image
from scratch (wipes VM state — projects, ~/.emacs.d, docker images).

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
every `nixos-rebuild switch`). Requires `secrets/.cachix-token` with write scope on
virtiofs (gitignored).

## VERIFY checklist (build-from-source mode only)
- `make-disk-image` arg names match this nixpkgs pin — if `nix build .#qcow`
  errors, check `<nixpkgs>/nixos/lib/make-disk-image.nix`.
- Disk labels: after first boot `lsblk -f` — root should be `nixos`, ESP `ESP`;
  adjust `configuration.nix` `fileSystems` if make-disk-image used others.
- AAVMF paths exist (`/usr/share/AAVMF/AAVMF_{CODE,VARS}.fd`); the script falls
  back to `qemu-efi-aarch64/QEMU_EFI.fd`.
- macvtap NIC auto-detected correctly (`ip -br link`).
- vcpupin holds (`0->2 1->3 2->6 3->7`) + guest is **stable under 4-way load**
  (`stress-ng --cpu 4`); host cores 2,3,6,7 driven ~only by the guest.
- qemu runs the disk OK from `/var/lib/libvirt/images` (avoid `$HOME` — the
  `libvirt-qemu` user can't traverse a `700` home dir).
- Cachix: `nix store info --store https://fr33m0nk.cachix.org` from inside the VM.
