#!/usr/bin/env bash
# Build the full NixOS system closure on the host and push it to the fr33m0nk
# Cachix binary cache. After this, any VM using this flake will download the
# pre-built packages instead of compiling emacs/clojure-lsp from source.
#
#   ./push-to-cache.sh
#
# Prerequisites (one-time):
#   1. nix build path:.../. -or- nix develop path:.../. -c true
#      (warm the flake eval cache first)
#   2. cachix authtoken <your-auth-token>
#   3. cachix use fr33m0nk
#
# Run on the RK3588 host (not inside a VM) to use all 8 cores.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="fr33m0nk"
FLAKE="path:${HERE}"

# Check cachix is available and authenticated
command -v cachix >/dev/null 2>&1 || {
  echo "ERROR: cachix not found. Install it: nix profile install nixpkgs#cachix"
  exit 1
}
cachix authtoken check >/dev/null 2>&1 || {
  echo "ERROR: cachix not authenticated. Run: cachix authtoken <your-token>"
  exit 1
}

echo "=== Building full system closure for aarch64-linux ==="
echo "    This compiles emacs, clojure-lsp native-image, and the full toolchain."
echo "    One-time cost: ~1-2 hours on RK3588."
echo ""

# Build the toplevel (system closure) for the base-image config.
# This is the heavy part — everything from kernel to emacs to docker.
TOPLEVEL="${FLAKE}#nixosConfigurations.libvirt-vm-aarch64-base.config.system.build.toplevel"

echo ">>> Building: ${TOPLEVEL}"
nix build "$TOPLEVEL" \
  --extra-experimental-features "nix-command flakes" \
  --impure \
  --print-out-paths \
  --out-link result-toplevel

echo ""
echo "=== Pushing closure to cachix:${CACHE} ==="
echo "    This uploads all store paths that aren't already in the cache."

cachix push "$CACHE" result-toplevel

echo ""
echo "=== Done ==="
echo "The full system closure is now in https://fr33m0nk.cachix.org"
echo ""
echo "Next: add the cache to your VM config so it downloads from the cache:"
echo "  In configuration-libvirt-base.nix, add to nix.settings:"
echo "    extra-substituters = [ ... \"https://fr33m0nk.cachix.org\" ];"
echo "    extra-trusted-public-keys = [ ... \"$(cachix generate-keypair fr33m0nk | tail -1)\" ];"
echo ""
echo "Then on any fresh VM with that config, 'nixos-rebuild switch' will download"
echo "the pre-built closure instead of compiling from source."
rm -f result-toplevel
