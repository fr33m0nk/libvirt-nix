{
  description = "NixOS dev VM for libvirt/KVM (RK3588 big.LITTLE via vcpupin) — Clojure toolchain";

  # Same pins as ../nixos. Track the nixpkgs stable release; roll with `nix flake update`.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    herdr = {
      url = "github:fr33m0nk/herdr/3a5e0f96b6b198719ab0f73d95fb73494310cba6";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Emacs 32 (master) → emacs-git-nox. aarch64-linux master isn't cached
    # by the nix-community cache, so it compiles from source on first build.
    # After the first build, cachix-push.service uploads it to
    # fr33m0nk.cachix.org — subsequent fresh VMs download the pre-built binary.
    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, herdr, home-manager, emacs-overlay, ... }:
    let
      lib = nixpkgs.lib;

      unfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

      # heroku 11.6.0 (nixpkgs is stuck at 10.16.0). See ../nixos/flake.nix.
      herokuOverlay = _final: prev: {
        heroku = prev.heroku.overrideAttrs (_: {
          version = "11.6.0";
          src = prev.fetchzip {
            url = "https://cli-assets.heroku.com/versions/11.6.0/12d2375/heroku-v11.6.0-12d2375-linux-x64.tar.xz";
            hash = "sha256-VhW0O8y3oVzrJ8sCnzPOLJIWkwgty+CSY48+9MvRIxE=";
          };
          installPhase = ''
            mkdir -p $out/share/heroku $out/bin
            cp -pr * $out/share/heroku
            makeWrapper ${prev.nodejs}/bin/node $out/bin/heroku \
              --add-flags "$out/share/heroku/bin/run" \
              --set HEROKU_DISABLE_AUTOUPDATE 1
          '';
        });
      };

      # clojure-lsp nightly native-image (the #2313 memory work). Same overlay as
      # ../nixos/flake.nix, including the GraalVM build tuning (heap, thread cap,
      # widened watchdog) so the native-image compile completes — on the RK3588 host
      # with 8 cores / 24 GB this is comfortable. To bump: change version + url and
      # re-prefetch the hash with `nix store prefetch-file --json <url>`.
      clojureLspOverlay = _final: prev: {
        clojure-lsp = prev.clojure-lsp.overrideAttrs (old: {
          version = "2026.06.20-22.20.43-nightly";
          src = prev.fetchurl {
            url = "https://github.com/clojure-lsp/clojure-lsp-dev-builds/releases/download/2026.06.20-22.20.43-nightly/clojure-lsp-standalone.jar";
            hash = "sha256-27VrD35R8ws2cZo5DkMviT6O28BoGZTWTMOQ/83di3U=";
          };
          nativeImageArgs = (old.nativeImageArgs or [ ]) ++ [
            "-J-Xmx8g"
            "-H:DeadlockWatchdogInterval=1200"
          ];
        });
      };

      overlays = [ herokuOverlay clojureLspOverlay emacs-overlay.overlays.default herdr.overlays.default ];

      userName =
        let v = builtins.getEnv "NIXOS_USER";
        in if v == "" then throw "NIXOS_USER environment variable is not set" else v;

      mkSystem = system: lib.nixosSystem {
        inherit system;
        specialArgs = { inherit userName; };
        modules = [
          ./configuration.nix
          {
            nixpkgs.config.allowUnfreePredicate = unfreePredicate;
            nixpkgs.overlays = overlays;
          }
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            # Pass the flake-input home-manager CLI to home.nix. The NixOS module
            # does NOT install the CLI on its own, and `pkgs.home-manager` (nixpkgs)
            # would collide with the flake-input build in the standalone path.
            home-manager.extraSpecialArgs = { hmPackage = home-manager.packages.${system}.home-manager; };
            home-manager.users.${userName} = import ./home.nix;
          }
        ];
      };

      # Variant that targets the nixos-libvirt base image (GRUB, /dev/vda1 /boot).
      # Use this for `nixos-rebuild switch` after booting the pre-built qcow2.
      mkBaseSystem = system: lib.nixosSystem {
        inherit system;
        specialArgs = { inherit userName; };
        modules = [
          ./configuration-libvirt-base.nix
          {
            nixpkgs.config.allowUnfreePredicate = unfreePredicate;
            nixpkgs.overlays = overlays;
          }
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            # See mkSystem: the module doesn't ship the CLI; hand home.nix the
            # flake-input build so it matches the standalone path (no buildEnv clash).
            home-manager.extraSpecialArgs = { hmPackage = home-manager.packages.${system}.home-manager; };
            home-manager.users.${userName} = import ./home.nix;
          }
        ];
      };

      # Build a bootable qcow2 from the SAME nixosConfiguration. partitionTableType
      # "efi" → GPT with an ESP + root (labels ESP/nixos, matching configuration.nix),
      # so the running system can `nixos-rebuild` in place afterwards.
      # VERIFY: make-disk-image's argument names can drift across nixpkgs releases;
      # if `nix build .#qcow` errors on an unknown arg, check
      # <nixpkgs>/nixos/lib/make-disk-image.nix for this pin.
      mkImage = system:
        let nixos = mkSystem system;
        in import "${nixpkgs}/nixos/lib/make-disk-image.nix" {
          inherit lib;
          inherit (nixos) config pkgs;
          format = "qcow2";
          partitionTableType = "efi";
          installBootLoader = true;
          touchEFIVars = false;
          diskSize = "auto";
          additionalSpace = "3G";
          copyChannel = false;
        };
    in {
      nixosConfigurations = {
        "libvirt-vm-aarch64"       = mkSystem "aarch64-linux";
        "libvirt-vm-x86_64"        = mkSystem "x86_64-linux";
        "libvirt-vm-aarch64-base"  = mkBaseSystem "aarch64-linux";
        "libvirt-vm-x86_64-base"   = mkBaseSystem "x86_64-linux";
      };

      # Standalone home-manager configurations (for quick home.nix changes)
      homeConfigurations = {
        "${userName}@libvirt-vm-aarch64-base" = home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = "aarch64-linux";
            config.allowUnfreePredicate = unfreePredicate;
            overlays = overlays;
          };
          # Same flake-input CLI as the NixOS-module path (see mkSystem).
          extraSpecialArgs = { hmPackage = home-manager.packages.aarch64-linux.home-manager; };
          # Standalone HM needs username/homeDirectory set explicitly. As a NixOS
          # module these are auto-injected from the system user, so home.nix omits
          # them — supply them here for the `home-manager switch` path.
          modules = [
            ./home.nix
            {
              home.username = userName;
              home.homeDirectory = "/home/${userName}";
            }
          ];
        };
      };

      packages.aarch64-linux.qcow = mkImage "aarch64-linux";
      packages.x86_64-linux.qcow  = mkImage "x86_64-linux";
      # convenience default
      packages.aarch64-linux.default = self.packages.aarch64-linux.qcow;
      packages.x86_64-linux.default  = self.packages.x86_64-linux.qcow;

      # Heavy toolchain packages — built on CI and pushed to Cachix.
      # Reference the base-image nixosConfiguration's pkgs to inherit
      # the emacs-overlay, clojureLspOverlay, and herokuOverlay.
      packages.aarch64-linux.emacs =
        self.nixosConfigurations."libvirt-vm-aarch64-base".pkgs.emacs-git-nox;
      packages.aarch64-linux.clojure-lsp =
        self.nixosConfigurations."libvirt-vm-aarch64-base".pkgs.clojure-lsp;
      packages.aarch64-linux.heroku =
        self.nixosConfigurations."libvirt-vm-aarch64-base".pkgs.heroku;
      # Toolchain meta-package: builds all three
      packages.aarch64-linux.toolchain =
        self.packages.aarch64-linux.emacs;
    };
}
