#!/usr/bin/env bash
# First-time bring-up of the NixOS dev VM under libvirt on the RK3588 host.
#
#   ./setup-libvirt-vm.sh
#
# Flow: build a bootable qcow2 from the flake (two phases — compile the closure on
# all cores, then assemble the image pinned to one cluster; see step 1), stage it
# into libvirt's image dir, create the UEFI nvram, fill domain.xml's @PLACEHOLDERS@,
# then `virsh define` + `virsh start`. Run it WITHOUT an external taskset — it pins
# only the part that needs it. The 1:1 vCPU pinning for the *running* VM lives in
# domain.xml's <cputune> — that's what lets this one VM span both A76+A55 clusters.
#
# After first boot, change config IN PLACE (state preserved) by SSHing in and:
#     sudo nixos-rebuild switch --flake /mnt/nixos-config#libvirt-vm-aarch64
# (the flake dir is virtiofs-shared at /mnt/nixos-config). Re-run THIS script only
# to rebuild the base image from scratch (see --reimage).
set -euo pipefail

# ---- config (edit to taste) ------------------------------------------------
NAME="lc-nix-libvirt"
ARCH="$(uname -m)"                                  # aarch64 | x86_64
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG_DIR="/var/lib/libvirt/images"
DISK="${IMG_DIR}/${NAME}.qcow2"
NVRAM="${IMG_DIR}/${NAME}_VARS.fd"
SHARE_NIXOS_CONFIG="${HERE}"                        # the flake dir, virtiofs-shared
DISK_GROW="${DISK_GROW:-40G}"                       # final disk size
BUILD_PIN="${BUILD_PIN:-4-7}"                       # cores for the pinned image step (A76 cluster)
export LIBVIRT_DEFAULT_URI=qemu:///system

# Host NIC for macvtap — the VM attaches directly onto it and gets a LAN IP, no
# host bridge needed. Auto-detect the device behind the default route; override
# with: NIC=eth0 ./setup-libvirt-vm.sh   (list candidates with `ip -br link`)
NIC="${NIC:-$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')}"
[ -n "$NIC" ] || { echo "could not auto-detect host NIC; set NIC=<dev> (see: ip -br link)"; exit 1; }

# ---- SSH key (kept out of the repo; gitignored) ---------------------------
KEY_FILE="${HERE}/ssh-authorized-key.pub"
if [ ! -s "$KEY_FILE" ]; then
  echo "ERROR: ${KEY_FILE} is missing or empty."
  echo "  Create it with your SSH *public* key (one per line), then re-run."
  echo "  On your laptop:  cat ~/.ssh/id_rsa.pub   (or id_ed25519.pub) — copy that line."
  echo "  Template:        cp ssh-authorized-key.pub.example ssh-authorized-key.pub"
  exit 1
fi

# ---- detect host firmware + emulator --------------------------------------
EMULATOR="$(command -v qemu-system-${ARCH} || true)"
[ -n "$EMULATOR" ] || { echo "qemu-system-${ARCH} not found (apt install qemu-system-arm)"; exit 1; }

# AAVMF (aarch64 UEFI). Debian split CODE/VARS preferred.
for cand in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
  [ -f "$cand" ] && { LOADER="$cand"; break; }
done
NVRAM_TEMPLATE="/usr/share/AAVMF/AAVMF_VARS.fd"
[ -n "${LOADER:-}" ] || { echo "AAVMF firmware not found (apt install qemu-efi-aarch64)"; exit 1; }

# ---- 1. build the qcow2 from the flake (two phases) -----------------------
# Big.LITTLE makes this tricky: make-disk-image boots a brief internal KVM VM to
# install the bootloader, and a floating-vCPU VM crashes on RK3588 ("Failed to put
# registers after init"). But the *compilation* (emacs, clojure-lsp, toolchain) is
# pure CPU with no KVM. So:
#   1a. compile the system closure on ALL cores (fast, no pin) — heavy part.
#   1b. assemble the qcow under `taskset` to ONE cluster — only the short internal
#       VM is pinned; the closure is already cached from 1a.
# `path:` ref (not `.#`) so the untracked ssh-authorized-key.pub is visible.
# NOTE: assumes single-user Nix (taskset reaches the in-process build). For a
# multi-user daemon, pin it instead via nix-daemon.service CPUAffinity=${BUILD_PIN}.
FLAKE="path:${HERE}"
TOPLEVEL="${FLAKE}#nixosConfigurations.libvirt-vm-${ARCH}.config.system.build.toplevel"

echo ">>> [1/2] compiling system closure on all cores: ${TOPLEVEL}"
nix build "$TOPLEVEL" --extra-experimental-features "nix-command flakes" --no-link

echo ">>> [2/2] assembling qcow (pinned to cores ${BUILD_PIN}): ${FLAKE}#packages.${ARCH}-linux.qcow"
OUT="$(taskset -c "$BUILD_PIN" nix build "${FLAKE}#packages.${ARCH}-linux.qcow" \
  --extra-experimental-features "nix-command flakes" --no-link --print-out-paths)"
SRC_QCOW="$(find -L "$OUT" -name '*.qcow2' | head -1)"
[ -n "$SRC_QCOW" ] || { echo "no .qcow2 in build output"; exit 1; }

# ---- 2. stage a writable copy + grow --------------------------------------
echo ">>> staging ${DISK} (+resize to ${DISK_GROW})"
sudo install -d -m 0711 "$IMG_DIR"
sudo cp --reflink=auto "$SRC_QCOW" "$DISK"
sudo chmod u+rw "$DISK"
sudo qemu-img resize "$DISK" "$DISK_GROW"

# ---- 3. fill the domain template ------------------------------------------
DOM="$(mktemp)"
sed -e "s#@EMULATOR@#${EMULATOR}#g" \
    -e "s#@LOADER@#${LOADER}#g" \
    -e "s#@NVRAM_TEMPLATE@#${NVRAM_TEMPLATE}#g" \
    -e "s#@NVRAM@#${NVRAM}#g" \
    -e "s#@DISK@#${DISK}#g" \
    -e "s#@SHARE_NIXOS_CONFIG@#${SHARE_NIXOS_CONFIG}#g" \
    -e "s#@NIC@#${NIC}#g" \
    "${HERE}/domain.xml" > "$DOM"

# ---- 4. define + start -----------------------------------------------------
echo ">>> defining + starting ${NAME}"
virsh destroy  "$NAME" 2>/dev/null || true
virsh undefine --nvram "$NAME" 2>/dev/null || true
virsh define "$DOM"
virsh start "$NAME"
rm -f "$DOM"

echo
echo "Done. '${NAME}' is defined and started."
echo "  console : virsh console ${NAME}        (login: prashantsinha)"
echo "  pins    : virsh vcpupin ${NAME}        (expect 0->0 .. 7->7)"
echo "  IP      : virsh domifaddr ${NAME}      (needs guest-agent up)"
echo
echo "Change config in place (state preserved):"
echo "  ssh prashantsinha@<vm-ip>  then:"
echo "  sudo nixos-rebuild switch --flake path:/mnt/nixos-config#libvirt-vm-${ARCH}"
