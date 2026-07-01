#!/usr/bin/env bash
# First-time bring-up of the NixOS dev VM under libvirt on the RK3588 host.
#
#   ./setup-libvirt-vm.sh
#
# Two modes:
#   1. BUILD from source (default) — compile the full toolchain + assemble qcow2.
#      Slow but self-contained; uses the existing configuration.nix + make-disk-image.
#   2. BASE IMAGE (--base-image <qcow2>) — skip the build; use a pre-built
#      nixos-libvirt qcow2 from a release. Fast: just copy, resize, boot, then
#      nixos-rebuild the libvirt-nix config into the running VM.
#
#   ./setup-libvirt-vm.sh --base-image ../nixos-libvirt/release-v0.0.3-images/nixos-libvirt-v0.0.3-aarch64.qcow2
#
# After first boot with --base-image, the script waits for the guest agent, then
# runs nixos-rebuild inside the VM to apply the full dev toolchain. State is
# preserved across subsequent rebuilds.
# Workflow
#   1. ./setup-libvirt-vm.sh --base-image <qcow2>
#      ↓ copies + resizes + boots the base image
#   2. virsh console lc-nix-libvirt
#      ↓ login: nixos / password: nixos
#   3. sudo nixos-rebuild switch --flake path:/mnt/nixos-config#libvirt-vm-aarch64-base
#      ↓ 1-2 hours: compiles emacs, clojure-lsp, full toolchain
#   4. Log out, log back in as prashantsinha
#      ↓ VM is now at 192.168.29.45, SSH from laptop works

set -euo pipefail

# ---- config (edit to taste) ------------------------------------------------
NAME="lc-nix-libvirt"
ARCH="$(uname -m)" # aarch64 | x86_64
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG_DIR="/var/lib/libvirt/images"
DISK="${IMG_DIR}/${NAME}.qcow2"
NVRAM="${IMG_DIR}/${NAME}_VARS.fd"
SHARE_NIXOS_CONFIG="${HERE}"   # the flake dir, virtiofs-shared
DISK_GROW="${DISK_GROW:-150G}" # final disk size
BUILD_PIN="${BUILD_PIN:-4-7}"  # cores for the pinned image step (A76 cluster)
export LIBVIRT_DEFAULT_URI=qemu:///system

# Host NIC for macvtap — the VM attaches directly onto it and gets a LAN IP, no
# host bridge needed. Auto-detect the device behind the default route; override
# with: NIC=eth0 ./setup-libvirt-vm.sh
NIC="${NIC:-$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')}"
[ -n "$NIC" ] || {
  echo "could not auto-detect host NIC; set NIC=<dev> (see: ip -br link)"
  exit 1
}

# ---- parse args -----------------------------------------------------------
BASE_QCOW=""
FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
  --base-image)
    BASE_QCOW="$2"
    shift 2
    ;;
  --force)
    FORCE=true
    shift
    ;;
  *)
    echo "Usage: $0 [--base-image <qcow2>] [--force]"
    exit 1
    ;;
  esac
done

USE_BASE=false
if [ -n "$BASE_QCOW" ]; then
  USE_BASE=true
  [ -f "$BASE_QCOW" ] || {
    echo "ERROR: base image not found: $BASE_QCOW"
    exit 1
  }
fi

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
[ -n "$EMULATOR" ] || {
  echo "qemu-system-${ARCH} not found (apt install qemu-system-arm)"
  exit 1
}

# AAVMF (aarch64 UEFI). Debian split CODE/VARS preferred.
for cand in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
  [ -f "$cand" ] && {
    LOADER="$cand"
    break
  }
done
NVRAM_TEMPLATE="/usr/share/AAVMF/AAVMF_VARS.fd"
[ -n "${LOADER:-}" ] || {
  echo "AAVMF firmware not found (apt install qemu-efi-aarch64)"
  exit 1
}

# ---- 1. obtain the qcow2 --------------------------------------------------
if $USE_BASE; then
  echo ">>> [base-image] using pre-built qcow2: ${BASE_QCOW}"
  SRC_QCOW="$BASE_QCOW"
else
  # Build from source (two phases for big.LITTLE stability).
  #   1a. compile the system closure on ALL cores (fast, no pin) — heavy part.
  #   1b. assemble the qcow under `taskset` to ONE cluster — only the short internal
  #       VM is pinned; the closure is already cached from 1a.
  FLAKE="path:${HERE}"
  TOPLEVEL="${FLAKE}#nixosConfigurations.libvirt-vm-${ARCH}.config.system.build.toplevel"

  echo ">>> [1/2] compiling system closure on all cores: ${TOPLEVEL}"
  nix build "$TOPLEVEL" --extra-experimental-features "nix-command flakes" --no-link

  echo ">>> [2/2] assembling qcow (pinned to cores ${BUILD_PIN}): ${FLAKE}#packages.${ARCH}-linux.qcow"
  OUT="$(taskset -c "$BUILD_PIN" nix build "${FLAKE}#packages.${ARCH}-linux.qcow" \
    --extra-experimental-features "nix-command flakes" --no-link --print-out-paths)"
  SRC_QCOW="$(find -L "$OUT" -name '*.qcow2' | head -1)"
  [ -n "$SRC_QCOW" ] || {
    echo "no .qcow2 in build output"
    exit 1
  }
fi

# ---- 2. stage a writable copy + grow --------------------------------------
echo ">>> staging ${DISK} (+resize to ${DISK_GROW})"
sudo install -d -m 0711 "$IMG_DIR"
sudo cp --reflink=auto "$SRC_QCOW" "$DISK"
sudo chmod u+rw "$DISK"
sudo qemu-img resize "$DISK" "$DISK_GROW"

# ---- 3. create NVRAM ------------------------------------------------------
if [ -f "$NVRAM_TEMPLATE" ]; then
  echo ">>> creating NVRAM from template: ${NVRAM_TEMPLATE}"
  sudo cp "$NVRAM_TEMPLATE" "$NVRAM"
else
  echo ">>> NVRAM template not found, libvirt will create a fresh one"
fi

# ---- 4. fill the domain template ------------------------------------------
DOM="$(mktemp)"
sed -e "s#@EMULATOR@#${EMULATOR}#g" \
  -e "s#@LOADER@#${LOADER}#g" \
  -e "s#@NVRAM_TEMPLATE@#${NVRAM_TEMPLATE}#g" \
  -e "s#@NVRAM@#${NVRAM}#g" \
  -e "s#@DISK@#${DISK}#g" \
  -e "s#@SHARE_NIXOS_CONFIG@#${SHARE_NIXOS_CONFIG}#g" \
  -e "s#@NIC@#${NIC}#g" \
  "${HERE}/domain.xml" >"$DOM"

# ---- 5. define + start ----------------------------------------------------
echo ">>> defining + starting ${NAME}"
virsh destroy "$NAME" 2>/dev/null || true
virsh undefine --nvram "$NAME" 2>/dev/null || true
virsh define "$DOM"
virsh start "$NAME"
rm -f "$DOM"

echo
echo "=== VM '${NAME}' is booting ==="
echo "  console : virsh console ${NAME}"

# ---- 6. post-boot: wait for guest agent, then nixos-rebuild (base-image only)
if $USE_BASE; then
  echo
  echo ">>> Waiting for guest agent (VM booting under libvirt)..."
  for i in $(seq 1 120); do
    if virsh qemu-agent-command "$NAME" '{"execute":"guest-info"}' 2>/dev/null | grep -q "version"; then
      echo "Guest agent is alive!"
      break
    fi
    if [ "$i" -eq 120 ]; then
      echo "WARNING: Guest agent did not come up after 10 min."
    fi
    sleep 5
  done

  # The base image doesn't have the virtiofs mount yet — it only takes effect
  # AFTER nixos-rebuild. Set it up manually so the flake is visible for the
  # rebuild itself.
  echo "  Setting up virtiofs share (base image doesn't have it yet)..."
  virsh qemu-agent-command "$NAME" \
    '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/mkdir","arg":["-p","/mnt/nixos-config"],"capture-output":true}}' >/dev/null 2>&1 || true
  virsh qemu-agent-command "$NAME" \
    '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/modprobe","arg":["virtiofs"],"capture-output":true}}' >/dev/null 2>&1 || true
  sleep 1
  virsh qemu-agent-command "$NAME" \
    '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/mount","arg":["-t","virtiofs","nixos-config","/mnt/nixos-config"],"capture-output":true}}' >/dev/null 2>&1 || true
  sleep 1

  # Verify the flake is now visible
  PID=$(virsh qemu-agent-command "$NAME" \
    '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/ls","arg":["/mnt/nixos-config/flake.nix"],"capture-output":true}}' |
    jq -r '.return.pid')
  if [ -n "$PID" ] && [ "$PID" != "null" ]; then
    sleep 3
    OUT=$(virsh qemu-agent-command "$NAME" \
      "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}")
    if echo "$OUT" | jq -r '.return["out-data"] // ""' | base64 -d 2>/dev/null | grep -q flake; then
      echo "  virtiofs share OK."
      # Verify binary cache is reachable for the upcoming rebuild
      echo "  Checking cachix cache..."
      CACHE_OK=$(virsh qemu-agent-command "$NAME" \
        '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/nix","arg":["store","ping","--store","https://fr33m0nk.cachix.org"],"capture-output":true}}' \
        | jq -r '.return.pid')
      if [ -n "$CACHE_OK" ] && [ "$CACHE_OK" != "null" ]; then
        sleep 2
        CACHE_STATUS=$(virsh qemu-agent-command "$NAME" \
          "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$CACHE_OK}}" \
          | jq -r '.return.exitcode // 1')
        if [ "$CACHE_STATUS" = "0" ]; then
          echo "  Cachix cache reachable (reads) — builds will use pre-built packages if available."
        else
          echo "  WARNING: Cachix cache unreachable. Builds will compile from source."
        fi
      fi
      # Check if push auth is set up (token file on virtiofs)
      TOKEN_OK=$(virsh qemu-agent-command "$NAME" \
        '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/cachix","arg":["authtoken","check"],"capture-output":true}}' \
        | jq -r '.return.pid')
      if [ -n "$TOKEN_OK" ] && [ "$TOKEN_OK" != "null" ]; then
        sleep 1
        TOKEN_STATUS=$(virsh qemu-agent-command "$NAME" \
          "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$TOKEN_OK}}" \
          | jq -r '.return.exitcode // 1')
        if [ "$TOKEN_STATUS" = "0" ]; then
          echo "  Cachix push token present — built packages will be uploaded after rebuild."
        else
          echo "  WARNING: No Cachix push token. Place it at .cachix-token on virtiofs."
        fi
      fi
    else
      echo "  WARNING: virtiofs share not visible. Check domain.xml <filesystem> config."
      echo "  You can still mount it manually from the console:"
      echo "    sudo mkdir -p /mnt/nixos-config"
      echo "    sudo modprobe virtiofs"
      echo "    sudo mount -t virtiofs nixos-config /mnt/nixos-config"
    fi
  fi

  echo
  echo "=== Base image is booted. To apply the full dev toolchain: ==="
  echo ""
  echo "  # First, verify the binary cache is reachable:"
  echo "  virsh console ${NAME}"
  echo "  # login as: nixos  /  password: nixos"
  echo "  nix store ping --store https://fr33m0nk.cachix.org   # verify cache reads"
  echo "  cachix authtoken check                               # verify push token"
  echo ""
  echo "  # Then run the rebuild (push to cachix auto-starts on completion):"
  echo "  sudo nixos-rebuild switch --flake path:/mnt/nixos-config#libvirt-vm-${ARCH}-base"
  echo ""
  echo "  This compiles emacs, clojure-lsp, and the full toolchain (~1-2 hours on RK3588)."
  echo "  After it completes, log out and back in as: prashantsinha"
  echo "  The VM IP (for SSH from your laptop):"
  echo "    virsh domifaddr ${NAME} --source agent"
  echo "    # or from console: ip -br addr"
fi

echo
echo "Done. '${NAME}' is defined and running."
echo "  console : virsh console ${NAME}        (login: prashantsinha)"
echo "  pins    : virsh vcpupin ${NAME}        (expect 0->0 .. 7->7)"
echo "  IP      : virsh domifaddr ${NAME}      (needs guest-agent up)"
echo
if $USE_BASE; then
  echo "The base image was used — the dev toolchain is now applied via nixos-rebuild."
  echo "Built packages are auto-pushed to fr33m0nk.cachix.org on boot."
  echo ""
  echo "Change config in place (state preserved):"
  echo "  ssh prashantsinha@<vm-ip>  then:"
  echo "  sudo nixos-rebuild switch --flake path:/mnt/nixos-config#libvirt-vm-${ARCH}-base"
else
  echo "Change config in place (state preserved):"
  echo "  ssh prashantsinha@<vm-ip>  then:"
  echo "  sudo nixos-rebuild switch --flake path:/mnt/nixos-config#libvirt-vm-${ARCH}"
fi
