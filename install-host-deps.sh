#!/usr/bin/env bash
# Host bootstrap for the libvirt NixOS dev VM on Armbian/Debian (RK3588 / OMV).
# Installs libvirt + QEMU + all the device deps we hit during bring-up, plus Nix
# (needed to build the qcow image on the host), and applies the big.LITTLE
# performance tuning (CPU governor + prints the isolcpus/hugepages cmdline to add).
# Idempotent — safe to re-run.
#
#   ./install-host-deps.sh
#
# Run as your normal user (NOT root); it uses sudo where needed. After it finishes,
# log out/in once (for the libvirt/kvm groups + the Nix profile), add the kernel
# cmdline line it prints to /boot/armbianEnv.txt, REBOOT, then run ./setup-libvirt-vm.sh.
set -euo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
NIX_CACHIX_KEY="nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
NIX_FR33M0NK_KEY="fr33m0nk.cachix.org-1:242Y5El6BIU2qbK/6MKJLPDdfHYRu/JVgrcVVkwERDw="

command -v apt-get >/dev/null || { echo "This script targets Debian/Armbian (apt). Aborting."; exit 1; }

echo "==> 1/5  APT packages (libvirt, QEMU, firmware, virtiofsd, option ROMs, ...)"
sudo apt-get update
sudo apt-get install -y \
  qemu-system-arm \
  qemu-utils \
  qemu-efi-aarch64 \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  virtiofsd \
  ipxe-qemu \
  cloud-image-utils \
  acl
#  qemu-system-arm    -> qemu-system-aarch64 (the emulator)
#  qemu-utils         -> qemu-img (stage/resize the disk)
#  qemu-efi-aarch64   -> AAVMF UEFI firmware (/usr/share/AAVMF/AAVMF_{CODE,VARS}.fd)
#  libvirt-daemon-system + libvirt-clients -> libvirtd + virsh/virt-host-validate
#  virtinst           -> virt-install (used by the vcpupin boot test)
#  virtiofsd          -> the virtiofs daemon (fix: "Unable to find a satisfying virtiofsd")
#  ipxe-qemu          -> QEMU option ROMs incl. efi-virtio.rom (fix: "failed to find romfile")
#                        (domain.xml also sets <rom enabled='no'/>, so this is belt-and-suspenders)
#  cloud-image-utils  -> cloud-localds (builds the cloud-init seed for the test rig)
#  acl                -> setfacl (grant libvirt-qemu traverse on a dir, if you keep images outside /var/lib/libvirt)

echo "==> 2/5  Enable libvirtd + group membership"
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$TARGET_USER"

echo "==> 3/5  Sanity check"
[ -e /dev/kvm ] || echo "  WARNING: /dev/kvm missing — KVM not available (check EL2/bootloader)."
sudo virt-host-validate qemu || true   # informational; some checks are advisory

echo "==> 4/5  Nix (multi-user) — needed to build the qcow image on the host"
if command -v nix >/dev/null 2>&1; then
  echo "  nix already installed: $(nix --version 2>/dev/null || true)"
else
  echo "  installing Nix (official multi-user installer; may prompt for confirmation)..."
  sh <(curl -L https://nixos.org/nix/install) --daemon
fi

echo "==> 5/6  Nix config: flakes + nix-community cache + trust this user"
# Append our settings to /etc/nix/nix.conf only if not already present.
NIXCONF=/etc/nix/nix.conf
sudo touch "$NIXCONF"
add_nixconf () {  # add_nixconf <key> <line>
  grep -q "^$1" "$NIXCONF" 2>/dev/null || echo "$2" | sudo tee -a "$NIXCONF" >/dev/null
}
add_nixconf "experimental-features"      "experimental-features = nix-command flakes"
add_nixconf "max-jobs"                   "max-jobs = 1"
add_nixconf "trusted-users"              "trusted-users = root @wheel ${TARGET_USER}"
add_nixconf "extra-substituters"         "extra-substituters = https://nix-community.cachix.org https://fr33m0nk.cachix.org"
add_nixconf "extra-trusted-public-keys"  "extra-trusted-public-keys = ${NIX_CACHIX_KEY} ${NIX_FR33M0NK_KEY}"
sudo systemctl restart nix-daemon 2>/dev/null || true

# Install cachix for binary cache push/pull
nix profile install nixpkgs#cachix 2>/dev/null || echo "  cachix may already be installed"

echo "==> 6/6  Performance tuning (RK3588 big.LITTLE — for the 2+2 pinned VM)"
# See README "Performance tuning". The VM runs 4 vCPUs pinned 1:1 to ISOLATED
# host cores — 2,3 (A55) + 6,7 (A76) — leaving 0,1 + 4,5 for the host. Two levers:

# 6a. Pin the CPU governor to 'performance' so the A76 cluster stays at its ~2.256 GHz
#     ceiling (no clock-down / ramp latency on bursty LSP/compile loads). A oneshot
#     unit re-applies it every boot — cpufrequtils.service is masked on Armbian.
sudo tee /etc/systemd/system/cpu-performance.service >/dev/null <<'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-performance.service
echo "  governor -> performance (persistent via cpu-performance.service)"

# 6b. Kernel cmdline: isolate the VM's cores (2,3,6,7) from the host scheduler so
#     nothing preempts the pinned vCPUs, and reserve hugepages to back the 12 GiB
#     guest (6144 pages needed; reserve 6400 for headroom — an exactly-sized pool
#     fails because the host always has a few pages in use). This edits the
#     bootloader, so it is NOT auto-applied — add it by hand and reboot:
CMDLINE="isolcpus=managed_irq,domain,2,3,6,7 nohz_full=2,3,6,7 rcu_nocbs=2,3,6,7 hugepages=6400"
echo "  ACTION REQUIRED: append to the extraargs= line in /boot/armbianEnv.txt, then reboot:"
echo "      ${CMDLINE}"
echo "  Verify after reboot:"
echo "      cat /sys/devices/system/cpu/isolated   # 2-3,6-7"
echo "      grep HugePages_Total /proc/meminfo     # 6400"
echo "      lscpu -e                               # confirm A55=0-3 (~1800MHz), A76=4-7 (~2256MHz)"

echo
echo "Done. Next:"
echo "  1) Log out and back in (applies the libvirt/kvm groups + loads Nix into your shell)."
echo "     (or this shell only:  . /etc/profile.d/nix.sh  &&  newgrp libvirt)"
echo "  2) Add the isolcpus/hugepages line above to /boot/armbianEnv.txt, then: sudo reboot"
echo "  3) export LIBVIRT_DEFAULT_URI=qemu:///system"
echo "  4) ./setup-libvirt-vm.sh"
