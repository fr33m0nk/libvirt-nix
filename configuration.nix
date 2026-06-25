# NixOS system config for the libvirt/KVM dev VM (RK3588 big.LITTLE host).
#
# This is the libvirt counterpart of ../nixos/configuration.nix (which targets
# nixos-lima). Differences: NO Lima (no services.lima, no lima user/cidata) — it's
# a plain NixOS guest. The host (Armbian on a Radxa Rock 5 ITX / RK3588) runs it
# under libvirt with per-vCPU pinning (<cputune> in domain.xml) so a single VM can
# span both A76 + A55 clusters — the thing Lima/floating-vCPU could not do (the
# CCSIDR "Failed to put registers after init" crash). VERIFY markers flag things to
# confirm on first boot.
{ config, pkgs, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # --- Boot + disk (standard UEFI NixOS) ----------------------------------
  # The image is built by `nix build .#qcow` (make-disk-image, partitionTableType
  # "efi"), which lays down a GPT disk: ESP labelled "ESP" + root labelled "nixos".
  # Declaring them here (matching that layout) is what lets you `nixos-rebuild` IN
  # PLACE later instead of re-imaging — state is preserved. VERIFY the labels after
  # first boot with `lsblk -f` and adjust if make-disk-image used different ones.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;   # VM has no persistent EFI vars
  # Grow the root PARTITION to fill the (resized) disk at boot; autoResize below
  # then grows the filesystem to fill the partition. Both are needed — without
  # growPartition the disk's extra space never reaches the guest and / fills up.
  boot.growPartition = true;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;                              # grow to fill the resized qcow
    options = [ "noatime" "nodiratime" "discard" ];
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  # --- virtiofs share: the flake dir, host-mounted (edit on host, rebuild here) -
  # Mirrors Lima's /mnt/nixos-config bind. The mount tag must match domain.xml's
  # <filesystem><target dir='nixos-config'/>. virtiofs needs shared memory in the
  # domain (memoryBacking access=shared) — handled in domain.xml.
  fileSystems."/mnt/nixos-config" = {
    device = "nixos-config";
    fsType = "virtiofs";
    options = [ "nofail" ];        # don't block boot if the host share is absent
  };

  # --- libvirt guest integration ------------------------------------------
  services.qemuGuest.enable = true;   # IP reporting, graceful shutdown via virsh

  # --- User ---------------------------------------------------------------
  # Plain NixOS user (no lima ".guest" home suffix). Rootless Docker needs the
  # subordinate id ranges + linger, same as the lima variant.
  users.mutableUsers = true;
  users.users.prashantsinha = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    linger = true;
    subUidRanges = [ { startUid = 100000; count = 65536; } ];
    subGidRanges = [ { startGid = 100000; count = 65536; } ];
    # Console + SSH access. REPLACE the key with your laptop's public key; the
    # initialPassword is only a console fallback (change it / drop it once SSH works).
    # SSH public key(s) read from ./ssh-authorized-key.pub (gitignored — kept OUT
    # of the committed repo). One key per line. A missing file is a HARD ERROR — we
    # won't build a VM with no way in. NOTE: because the file is untracked, the
    # build must use a `path:` flake ref so Nix can see it; setup-libvirt-vm.sh does
    # this, and for in-VM rebuilds use `--flake path:/mnt/nixos-config#...`.
    openssh.authorizedKeys.keys =
      let f = ./ssh-authorized-key.pub; in
      if builtins.pathExists f
      then lib.filter (s: s != "") (lib.splitString "\n" (builtins.readFile f))
      else throw ''
        libvirt-nix: ./ssh-authorized-key.pub is missing.
        Create it with your SSH *public* key (one per line) before building, e.g.:
          cp ssh-authorized-key.pub.example ssh-authorized-key.pub   # then edit
        Refusing to build a VM with no SSH access.'';
    initialPassword = "changeme";   # VERIFY/CHANGE
  };
  security.sudo.wheelNeedsPassword = false;

  # --- SSH ----------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = lib.mkDefault false;  # key-only once set up
  };

  # --- Networking ---------------------------------------------------------
  # Bridged NIC (domain.xml) → the VM gets a real LAN IP, reachable from the
  # laptop directly (cleaner than Lima's port-forwards; no guest-agent mismatch).
  networking.hostName = "lc-nix-libvirt";
  networking.useDHCP = lib.mkDefault true;
  networking.firewall.allowedTCPPorts = [ 22 3450 ];   # ssh + the app port

  # --- Rootless Docker (declarative, same as the lima variant) -------------
  virtualisation.docker = {
    enable = false;
    rootless = { enable = true; setSocketVariable = true; };
  };

  # --- nix-ld: foreign ELF loader (ghostel's prebuilt module, etc.) --------
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [ stdenv.cc.cc.lib zlib fuse icu libsecret e2fsprogs ];
  };
  boot.kernel.sysctl."fs.inotify.max_user_watches" = 524288;

  # --- Memory headroom (zram + overflow swapfile) -------------------------
  zramSwap = { enable = true; memoryPercent = 50; };
  swapDevices = [ { device = "/var/swapfile"; size = 8192; } ];

  # --- Nix ----------------------------------------------------------------
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # emacs-overlay cache (emacs-git still compiles from source on aarch64).
  nix.settings.extra-substituters = [ "https://nix-community.cachix.org" ];
  nix.settings.extra-trusted-public-keys = [
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  ];

  system.stateVersion = "26.05";
}
