#!/usr/bin/env bash
# Host bootstrap for the libvirt NixOS dev VM on Armbian/Debian (RK3588 / OMV).
# Installs libvirt + QEMU + all the device deps we hit during bring-up, plus Nix
# (needed to build the qcow image on the host). Idempotent — safe to re-run.
#
#   ./install-host-deps.sh
#
# Run as your normal user (NOT root); it uses sudo where needed. After it finishes,
# log out/in once (for the libvirt/kvm groups + the Nix profile), then run
# ./setup-libvirt-vm.sh.
set -euo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
NIX_CACHIX_KEY="nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="

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

echo "==> 5/5  Nix config: flakes + nix-community cache + trust this user"
# Append our settings to /etc/nix/nix.conf only if not already present.
NIXCONF=/etc/nix/nix.conf
sudo touch "$NIXCONF"
add_nixconf () {  # add_nixconf <key> <line>
  grep -q "^$1" "$NIXCONF" 2>/dev/null || echo "$2" | sudo tee -a "$NIXCONF" >/dev/null
}
add_nixconf "experimental-features"      "experimental-features = nix-command flakes"
add_nixconf "trusted-users"              "trusted-users = root @wheel ${TARGET_USER}"
add_nixconf "extra-substituters"         "extra-substituters = https://nix-community.cachix.org"
add_nixconf "extra-trusted-public-keys"  "extra-trusted-public-keys = ${NIX_CACHIX_KEY}"
sudo systemctl restart nix-daemon 2>/dev/null || true

echo
echo "Done. Next:"
echo "  1) Log out and back in (applies the libvirt/kvm groups + loads Nix into your shell)."
echo "     (or this shell only:  . /etc/profile.d/nix.sh  &&  newgrp libvirt)"
echo "  2) export LIBVIRT_DEFAULT_URI=qemu:///system"
echo "  3) ./setup-libvirt-vm.sh"
