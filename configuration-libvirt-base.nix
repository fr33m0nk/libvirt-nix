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
{ config, pkgs, lib, modulesPath, ... }:
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

  # --- virtiofs share: the flake dir, host-mounted (edit on host, rebuild here) -
  # Mirrors Lima's /mnt/nixos-config bind. The mount tag must match domain.xml's
  # <filesystem><target dir='nixos-config'/>. virtiofs needs shared memory in the
  # domain (memoryBacking access=shared) — handled in domain.xml.
  boot.kernelModules = [ "virtiofs" "virtio_balloon" ];
  fileSystems."/mnt/nixos-config" = {
    device = "nixos-config";
    fsType = "virtiofs";
    options = [ "nofail" ];        # don't block boot if the host share is absent
  };

  # --- libvirt guest integration ------------------------------------------
  services.qemuGuest.enable = true;   # IP reporting, graceful shutdown via virsh
  services.cloud-init.enable = true;  # kept from base image (NoCloud cidata ISO)
  # Restrict to NoCloud only — the base image's default datasource list
  # probes AWS/EC2/GCE metadata endpoints that don't exist, adding ~4 min
  # to every boot with timeout spam on the console.
  services.cloud-init.settings = {
    datasource_list = [ "NoCloud" ];
  };

  # --- User ---------------------------------------------------------------
  users.mutableUsers = true;
  users.users.prashantsinha = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    linger = true;
    subUidRanges = [ { startUid = 100000; count = 65536; } ];
    subGidRanges = [ { startGid = 100000; count = 65536; } ];
    openssh.authorizedKeys.keys =
      let f = ./ssh-authorized-key.pub; in
      if builtins.pathExists f
      then lib.filter (s: s != "") (lib.splitString "\n" (builtins.readFile f))
      else throw ''
        libvirt-nix: ./ssh-authorized-key.pub is missing.
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
  networking.useDHCP = false;
  networking.interfaces.enp2s0.ipv4.addresses = [
    { address = "192.168.29.45"; prefixLength = 24; }
  ];
  networking.defaultGateway = "192.168.29.1";
  networking.nameservers = [ "9.9.9.11" "149.112.112.11" "2620:fe::11" "2620:fe::fe:11" ];

  # DNS-over-TLS via Quad9 secured ECS (encrypted, no ISP snooping).
  # systemd-resolved handles the DoT protocol; /etc/resolv.conf points
  # to the local stub resolver (127.0.0.53) which forwards via TLS.
  services.resolved = {
    enable = true;
    settings = {
      "Resolve" = {
        DNS = [ "9.9.9.11#dns11.quad9.net" "149.112.112.11#dns11.quad9.net" ];
        DNSOverTLS = "yes";
        DNSSEC = "true";
        FallbackDNS = [ "9.9.9.11" "149.112.112.11" "2620:fe::11" "2620:fe::fe:11" ];
      };
    };
  };
  networking.firewall.allowedTCPPorts = [ 22 3450 ];

  systemd.services."home-manager-prashantsinha" = {
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
    # Accept Router Advertisements even with forwarding enabled — needed for
    # SLAAC IPv6 on macvtap (the host NIC must also have trustGuestRxFilters).
    "net.ipv6.conf.all.accept_ra" = 2;
    "net.ipv6.conf.default.accept_ra" = 2;
  };

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
  # Requires a Cachix auth token in /mnt/nixos-config/.cachix-token
  # (gitignored, never committed). Without the token, this is a no-op.
  systemd.services.cachix-push = {
    description = "Push new Nix store paths to fr33m0nk.cachix.org";
    after = [ "nix-daemon.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.cachix pkgs.bash ];
    script = ''
      set -euo pipefail
      TOKEN_FILE=/mnt/nixos-config/.cachix-token
      CACHE=fr33m0nk
      if [ ! -f "$TOKEN_FILE" ]; then
        echo "cachix-push: no .cachix-token on virtiofs, skipping push"
        exit 0
      fi
      if ! cachix authtoken check >/dev/null 2>&1; then
        cachix authtoken "$(cat "$TOKEN_FILE")"
      fi
      # Push the current system closure + all its dependencies
      cachix push "$CACHE" /run/current-system
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
  };

  # Trigger cachix-push after a nix-daemon build reveals /run/current-system
  # was updated (i.e., a nixos-rebuild switch completed successfully).
  # The path unit watches the symlink target change.
  systemd.paths.cachix-push = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/run/current-system";
      Unit = "cachix-push.service";
    };
  };

  system.stateVersion = "26.05";
}
