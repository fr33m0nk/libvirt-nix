# NixOS system config that targets the nixos-libvirt base image (v0.0.3+).
#
# The base image ships GRUB (efiInstallAsRemovable) with /boot on /dev/vda1 and
# / on /dev/disk/by-label/nixos. This file is a DROP-IN for `nixos-rebuild switch`
# AFTER first boot — it preserves the GRUB boot layout and adds the full dev
# toolchain (Clojure, Emacs, Docker, etc.) from the libvirt-nix config.
#
# Differences from configuration.nix (the make-disk-image / systemd-boot variant):
#   - GRUB bootloader instead of systemd-boot
#   - /boot = /dev/vda1 instead of /dev/disk/by-label/ESP
#   - No boot.growPartition (base image doesn't need it)
#   - Keeps cloud-init enabled (base image has it)
{ config, pkgs, lib, modulesPath, userName, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # --- Boot + disk (GRUB-EFI, matching the nixos-libvirt base image) ---------
  boot.loader.grub = {
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;   # boots from fallback EFI/BOOT path — survives NVRAM loss
  };
  fileSystems."/boot" = {
    device = lib.mkForce "/dev/vda1";
    fsType = "vfat";
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
    options = [ "noatime" "nodiratime" "discard" ];
  };

  # Clone the flake repo from GitHub on first boot, then mount secrets
  # (SSH key, cachix token, nixos_user) at /mnt/nixos-config/secrets/.
  # No separate virtiofs mount needed — secrets overlay inside the clone.
  boot.kernelModules = [ "virtiofs" "virtio_balloon" ];
  systemd.services.clone-nixos-config = {
    description = "Clone libvirt-nix flake repo on first boot";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.git ];
    script = ''
      set -euo pipefail
      REPO_DIR=/mnt/nixos-config
      SECRETS_DIR=/mnt/nixos-secrets
      if [ -d "$REPO_DIR/.git" ]; then
        echo "Repo already cloned, skipping."
        exit 0
      fi
      git clone https://github.com/fr33m0nk/libvirt-nix "$REPO_DIR"
      mkdir -p "$REPO_DIR/secrets"
      mount -t virtiofs nixos-config/secrets "$REPO_DIR/secrets" || true
      for f in ssh-authorized-key.pub .cachix-token; do
        if [ -f "$SECRETS_DIR/$f" ]; then
          ln -sf "$SECRETS_DIR/$f" "$REPO_DIR/$f"
        fi
      done
      if [ -f "$SECRETS_DIR/nixos_user" ] && [ ! -f "$REPO_DIR/nixos_user" ]; then
        cp "$SECRETS_DIR/nixos_user" "$REPO_DIR/nixos_user"
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    wantedBy = [ "multi-user.target" ];
  };

  # --- libvirt guest integration ------------------------------------------
  services.qemuGuest.enable = true;   # IP reporting, graceful shutdown via virsh
  services.cloud-init.enable = true;  # kept from base image; no-op without cidata ISO

  # --- User ---------------------------------------------------------------
  users.mutableUsers = true;
  users.users.${userName} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    linger = true;
    subUidRanges = [ { startUid = 100000; count = 65536; } ];
    subGidRanges = [ { startGid = 100000; count = 65536; } ];
    openssh.authorizedKeys.keys =
      let f = ./secrets/ssh-authorized-key.pub; in
      if builtins.pathExists f
      then lib.filter (s: s != "") (lib.splitString "\n" (builtins.readFile f))
      else throw ''
        libvirt-nix: ./secrets/ssh-authorized-key.pub is missing.
        Create it with your SSH *public* key (one per line) before building, e.g.:
          cp ssh-authorized-key.pub.example ssh-authorized-key.pub   # then edit
        Refusing to build a VM with no SSH access.'';
    initialPassword = "changeme";
  };
  security.sudo.wheelNeedsPassword = false;

  # --- SSH ----------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = lib.mkDefault false;
  };

  # --- Networking ---------------------------------------------------------
  networking.hostName = "lc-nix-libvirt";
  # DHCP — IPv6 SLAAC works reliably with DHCP. For a fixed IP,
  # configure a static DHCP lease on your router (see README).
  networking.useDHCP = true;
  # Static-IP alternative (breaks IPv6 SLAAC on this macvtap setup):
  # networking.useDHCP = false;
  # networking.interfaces.enp2s0.ipv4.addresses = [
  #   { address = "192.168.29.45"; prefixLength = 24; }
  # ];
  # DNS — DHCP-provided by default, but we use Quad9 for malware blocking + DNSSEC
  networking.nameservers = [ "9.9.9.9" "149.112.112.112" "2620:fe::fe" "2620:fe::9" ];

  # Plain DNS (not DoT) — systemd-resolved DoT was causing resolution failures
  networking.firewall.allowedTCPPorts = [ 22 3450 ];
  networking.firewall.allowedUDPPortRanges = [ { from = 60000; to = 61000; } ];  # mosh

  systemd.services."home-manager-${userName}" = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  # --- Rootless Docker -----------------------------------------------------
  virtualisation.docker = {
    enable = false;
    rootless = { enable = true; setSocketVariable = true; };
  };

  # --- nix-ld: foreign ELF loader ------------------------------------------
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [ stdenv.cc.cc.lib zlib fuse icu libsecret e2fsprogs ];
  };
  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 524288;
    # Accept Router Advertisements for SLAAC IPv6. The host-side domain.xml
    # must have trustGuestRxFilters='yes' on the macvtap interface.
    "net.ipv6.conf.all.accept_ra" = 2;
    "net.ipv6.conf.default.accept_ra" = 2;
  };

  # --- big.LITTLE core-preference (2+2 pinned layout) ---------------------
  # The host pins this VM's 4 vCPUs 1:1 onto ISOLATED physical cores:
  #   guest cpu0,1 -> A55 (little)   guest cpu2,3 -> A76 (big)
  # QEMU 'virt' passes no capacity-dmips-mhz, so the guest scheduler treats all
  # cores as equal and would happily run hot threads on the slow A55 pair. We
  # reconstruct big-core PREFERENCE BY EXCLUSION: confine background/system work
  # to the little vCPUs (0-1) so the big cores (2-3) stay idle, and let the
  # interactive user session reach all 4. The scheduler then naturally migrates
  # emacs/clojure-lsp onto the idle big cores, while still able to spill down to
  # 0-1 under heavy load. nix builds are throughput work that SHOULD use the big
  # cores, so nix-daemon is moved into its own top-level slice allowed on 0-3
  # (cgroup v2: a child can't widen beyond its parent, hence the reparent).
  #
  # VERIFY the mapping after boot — guest cpu2,3 MUST be the A76:
  #   for c in 0 1 2 3; do printf 'cpu%s ' $c; \
  #     cat /sys/devices/system/cpu/cpu$c/regs/identification/midr_el1; done
  #   # A76 part = ...d0b.. ; A55 part = ...d05..  If swapped, flip the ranges.
  systemd.slices.system.sliceConfig.AllowedCPUs = "0-1";
  systemd.slices.user.sliceConfig.AllowedCPUs = "0-3";
  systemd.slices.nixbuild.sliceConfig.AllowedCPUs = "0-3";
  systemd.services.nix-daemon.serviceConfig.Slice = "nixbuild.slice";

  # --- Memory headroom -----------------------------------------------------
  zramSwap = { enable = true; memoryPercent = 50; };
  swapDevices = [ { device = "/var/swapfile"; size = 8192; } ];

  # --- Nix ----------------------------------------------------------------
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # Serialize builds: clojure-lsp native-image uses 8 GB heap alone.
  # Running another build concurrently on RK3588 (24 GB) risks OOM.
  nix.settings.max-jobs = 1;
  nix.settings.extra-substituters = [
    "https://nix-community.cachix.org"
    "https://fr33m0nk.cachix.org"
  ];
  nix.settings.extra-trusted-public-keys = [
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    "fr33m0nk.cachix.org-1:242Y5El6BIU2qbK/6MKJLPDdfHYRu/JVgrcVVkwERDw="
  ];

  # --- Kernel -------------------------------------------------------------
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # --- System packages ---------------------------------------------------
  environment.systemPackages = with pkgs; [
    cachix
    iputils  # ping, ping6, tracepath
  ];

  # After nixos-rebuild switch, push new store paths to the fr33m0nk
  # Cachix cache so other VMs / fresh installs download pre-built packages.
  # Requires a Cachix auth token in /mnt/nixos-config/secrets/.cachix-token
  # (gitignored, never committed). Without the token, this is a no-op.
  systemd.services.cachix-push = {
    description = "Push new Nix store paths to fr33m0nk.cachix.org";
    after = [ "nix-daemon.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.cachix pkgs.bash ];
    script = ''
      set -euo pipefail
      TOKEN_FILE=/mnt/nixos-config/secrets/.cachix-token
      CACHE=fr33m0nk
      if [ ! -f "$TOKEN_FILE" ]; then
        echo "cachix-push: no .cachix-token on virtiofs, skipping push"
        exit 0
      fi
      cat "$TOKEN_FILE" | cachix authtoken --stdin
      cachix push "$CACHE" /run/current-system
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
  };

  # Trigger cachix-push after /run/current-system changes
  # (i.e., a nixos-rebuild switch completed successfully).
  # For the FIRST rebuild, run manually after activation:
  #   sudo systemctl start cachix-push.service
  systemd.paths.cachix-push = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/run/current-system";
      Unit = "cachix-push.service";
    };
  };

  system.stateVersion = "26.05";
}
