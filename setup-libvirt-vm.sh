#!/usr/bin/env bash
# First-time bring-up of the NixOS dev VM under libvirt on the RK3588 host.
#
#   ./setup-libvirt-vm.sh
#
# Modes:
#   1. BUILD from source (default) — compile the full toolchain + assemble qcow2.
#      Slow but self-contained; uses the existing configuration.nix + make-disk-image.
#   2. BASE IMAGE (--base-image <qcow2>) — skip the build; use a pre-built
#      nixos-libvirt qcow2 from a release. Fast: just copy, resize, boot, then
#      nixos-rebuild the libvirt-nix config into the running VM.
#   3. REDEFINE (--redefine) — re-apply domain.xml to the EXISTING VM without
#      rebuilding: no image build, no disk re-stage, NVRAM/disk/state preserved.
#      Use this after editing domain.xml (CPU pinning, memory, hugepages, topology).
#      It cold-restarts the VM (memory/vcpu/topology changes need a full boot) and
#      preserves the domain UUID so `virsh define` updates in place.
#
#   ./setup-libvirt-vm.sh --base-image ../nixos-libvirt/release-v0.0.3-images/nixos-libvirt-v0.0.3-aarch64.qcow2
#   ./setup-libvirt-vm.sh --redefine     # apply domain.xml changes to a running VM
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
SECRETS_DIR="${HERE}/secrets"     # virtiofs-mounted into VM (/mnt/nixos-secrets)
DISK_GROW="${DISK_GROW:-150G}"    # final disk size
BUILD_PIN="${BUILD_PIN:-4-7}"      # cores for the pinned image step (A76 cluster)
GUEST_HUGEPAGES=6144               # 12 GiB guest / 2 MiB = pages QEMU needs FREE at start
export LIBVIRT_DEFAULT_URI=qemu:///system

# ---- host tuning pre-flight (a mis-tuned host makes `virsh start` fail) ----
# Checks the big.LITTLE tuning from install-host-deps.sh: performance governor,
# isolated VM cores (2,3,6,7), and enough FREE hugepages to back the 12 GiB guest.
preflight_host () {
  echo ">>> host pre-flight (performance tuning)"
  local gov iso free
  gov="$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_governor 2>/dev/null || true)"
  [ "$gov" = "performance" ] || \
    echo "  WARN: cpu6 governor='${gov:-unknown}', expected 'performance' (see install-host-deps.sh step 6a)."
  iso="$(cat /sys/devices/system/cpu/isolated 2>/dev/null || true)"
  case "$iso" in
    *6-7*) echo "  ok: isolated cores = ${iso}" ;;
    *) echo "  WARN: isolated cores='${iso:-none}', expected '2-3,6-7' — add isolcpus=... to /boot/armbianEnv.txt + reboot." ;;
  esac
  free="$(awk '/HugePages_Free/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "${free:-0}" -lt "$GUEST_HUGEPAGES" ]; then
    echo "  WARN: HugePages_Free=${free:-0} (< ${GUEST_HUGEPAGES} needed for the 12 GiB guest)."
    echo "        'virsh start' will fail with 'unable to map backing store'. Reserve them:"
    echo "        add hugepages=6400 to /boot/armbianEnv.txt + reboot (see install-host-deps.sh step 6b)."
  else
    echo "  ok: HugePages_Free=${free} (>= ${GUEST_HUGEPAGES})"
  fi
}

# ---- print the post-start verification steps for the 2+2 layout ----
print_verify () {
  echo "  # host:"
  echo "  virsh vcpupin ${NAME}          # expect 0->2  1->3  2->6  3->7"
  echo "  virsh iothreadinfo ${NAME}     # iothread 1 -> 0-1 (host cores)"
  echo "  virsh dominfo ${NAME} | grep -i memory       # 12 GiB"
  echo "  grep HugePages_Free /proc/meminfo            # ~256 free after QEMU takes 6144"
  echo "  cat /sys/devices/system/cpu/isolated         # 2-3,6-7"
  echo "  # guest (virsh console ${NAME}, or ssh):"
  echo "  nproc                                        # 4"
  echo "  for c in 0 1 2 3; do printf 'cpu%s ' \$c; cat /sys/devices/system/cpu/cpu\$c/regs/identification/midr_el1; done"
  echo "  #   cpu2,3 end ...d0b.. (A76) ; cpu0,1 end ...d05.. (A55) — if swapped, flip the slice ranges in configuration.nix"
  echo "  systemctl show system.slice user.slice -p AllowedCPUs   # 0-1 and 0-3"
}

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
REDEFINE=false
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
  --redefine)
    REDEFINE=true
    shift
    ;;
  *)
    echo "Usage: $0 [--base-image <qcow2>] [--force] [--redefine]"
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

# ---- SSH key and secrets (kept out of the repo; gitignored) --------------
mkdir -p "$SECRETS_DIR"
KEY_FILE="${SECRETS_DIR}/ssh-authorized-key.pub"
if [ ! -s "$KEY_FILE" ]; then
  echo "ERROR: ${KEY_FILE} is missing or empty."
  echo "  Create it with your SSH *public* key (one per line), then re-run."
  echo "  On your laptop:  cat ~/.ssh/id_rsa.pub   (or id_ed25519.pub) — copy that line."
  exit 1
fi

# Create nixos_user file if missing
USER_FILE="${SECRETS_DIR}/nixos_user"
if [ ! -f "$USER_FILE" ]; then
  echo "${USER_NAME}" > "$USER_FILE"
  echo "Created ${USER_FILE} — edit to change the VM username."
fi
USER_NAME=$(cat "$USER_FILE")

# Ensure nixos_user exists in repo root (flake reads it directly, not via symlink)
if [ ! -f "${HERE}/nixos_user" ]; then
  cp "${USER_FILE}" "${HERE}/nixos_user"
  echo "Created ${HERE}/nixos_user"
fi

# Create host-side symlinks so flake.nix can read from repo root
for f in ssh-authorized-key.pub .cachix-token; do
  if [ -f "${SECRETS_DIR}/${f}" ] && [ ! -e "${HERE}/${f}" ]; then
    ln -sf "${SECRETS_DIR}/${f}" "${HERE}/${f}"
    echo "Linked ${HERE}/${f} -> ${SECRETS_DIR}/${f}"
  fi
done

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

# ---- REDEFINE fast path: re-apply domain.xml, no rebuild ------------------
# Applies domain.xml edits (CPU pinning, memory, hugepages, topology) to the
# existing VM. Preserves disk + NVRAM + guest state. Cold-restarts to apply.
if $REDEFINE; then
  virsh dominfo "$NAME" >/dev/null 2>&1 || {
    echo "ERROR: domain '${NAME}' is not defined yet — run without --redefine first."
    exit 1
  }
  echo ">>> [redefine] re-applying domain.xml to '${NAME}' (no rebuild; disk/nvram preserved)"
  preflight_host

  # Preserve the existing UUID so `virsh define` UPDATES in place. The template
  # carries no <uuid>, so a plain define would try to CREATE and collide:
  #   "domain 'lc-nix-libvirt' already exists with uuid ..."
  UUID="$(virsh domuuid "$NAME")"

  DOM="$(mktemp)"
  sed -e "s#@EMULATOR@#${EMULATOR}#g" \
    -e "s#@LOADER@#${LOADER}#g" \
    -e "s#@NVRAM_TEMPLATE@#${NVRAM_TEMPLATE}#g" \
    -e "s#@NVRAM@#${NVRAM}#g" \
    -e "s#@DISK@#${DISK}#g" \
    -e "s#@SECRETS@#${SECRETS_DIR}#g" \
    -e "s#@NIC@#${NIC}#g" \
    "${HERE}/domain.xml" >"$DOM"
  sed -i "s#<name>${NAME}</name>#<name>${NAME}</name>\n  <uuid>${UUID}</uuid>#" "$DOM"

  # Cold restart — memory/vcpu/topology changes only take effect on a fresh boot.
  if virsh domstate "$NAME" 2>/dev/null | grep -q running; then
    echo ">>> shutting down ${NAME} (cold restart required for CPU/memory changes)"
    virsh shutdown "$NAME" || true
    for _ in $(seq 1 60); do
      virsh domstate "$NAME" 2>/dev/null | grep -q "shut off" && break
      sleep 2
    done
  fi
  virsh define "$DOM"
  rm -f "$DOM"
  virsh start "$NAME"
  echo
  echo ">>> '${NAME}' redefined + started. Verify:"
  print_verify
  exit 0
fi

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
preflight_host   # warn early if governor/isolcpus/hugepages aren't set (start would fail)
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
  echo "  Setting up repo and secrets (git clone + virtiofs mount)..."
  # Mount secrets virtiofs and clone the flake repo
  virsh qemu-agent-command "$NAME" \
    '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/mkdir","arg":["-p","/mnt/nixos-secrets","/mnt/nixos-config"],"capture-output":true}}' > /dev/null 2>&1 || true
  virsh qemu-agent-command "$NAME" \
    '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/modprobe","arg":["virtiofs"],"capture-output":true}}' > /dev/null 2>&1 || true
  sleep 1
  virsh qemu-agent-command "$NAME" \
    '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/mount","arg":["-t","virtiofs","nixos-config/secrets","/mnt/nixos-secrets"],"capture-output":true}}' > /dev/null 2>&1 || true
  sleep 1
  virsh qemu-agent-command "$NAME" \
    '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/git","arg":["clone","https://github.com/fr33m0nk/libvirt-nix","/mnt/nixos-config"],"capture-output":true}}' > /dev/null 2>&1 || true
  sleep 3
  # Mount secrets virtiofs directly into the cloned repo — no symlinks needed
  virsh qemu-agent-command "$NAME" \
    '{"execute":"guest-exec","arguments":{"path":"/run/current-system/sw/bin/mount","arg":["-t","virtiofs","nixos-config/secrets","/mnt/nixos-config/secrets"],"capture-output":true}}' > /dev/null 2>&1 || true

  echo
  echo "=== Base image is booted. To apply the full dev toolchain: ==="
  echo ""
  echo "  echo \"\$NIXOS_USER\"                                    # verify NIXOS_USER is set"
  echo ""
  echo "  # Then run the rebuild:"
  echo "  sudo nixos-rebuild switch --flake path:/mnt/nixos-config#libvirt-vm-\${ARCH}-base"
  echo ""
  echo "  This compiles emacs, clojure-lsp, and the full toolchain (~1-2 hours on RK3588)."
  echo "  After it completes, log out and back in as: ${USER_NAME}"
  echo "  (or run:  exec bash -l  to reload the shell with new aliases)"
  echo "  The VM IP (for SSH from your laptop):"
  echo "    virsh domifaddr ${NAME} --source agent"
  echo "    # or from console: ip -br addr"
fi

echo
echo "Done. '${NAME}' is defined and running."
echo "  console : virsh console ${NAME}        (login: ${USER_NAME})"
echo "  IP      : virsh domifaddr ${NAME}      (needs guest-agent up)"
echo "  verify the 2+2 pinned layout:"
print_verify
echo
if $USE_BASE; then
  echo "The base image was used — the dev toolchain is now applied via nixos-rebuild."
  echo "Built packages are auto-pushed to fr33m0nk.cachix.org on boot."
  echo ""
  echo "Change config in place (state preserved):"
  echo "  ssh \${USER_NAME}@<vm-ip>  then:"
  echo "  sudo nixos-rebuild switch --flake path:/mnt/nixos-config#libvirt-vm-\${ARCH}-base"
else
  echo "Change config in place (state preserved):"
  echo "  ssh \${USER_NAME}@<vm-ip>  then:"
  echo "  sudo nixos-rebuild switch --flake path:/mnt/nixos-config#libvirt-vm-\${ARCH}"
fi
