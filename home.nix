# Home Manager config for the NixOS variant, applied as a NixOS module (see
# flake.nix). Same user toolchain as the Ubuntu variant's home.nix, minus the
# things NixOS already handles (no nix-daemon.sh sourcing — NixOS sets PATH;
# no /etc/environment PATH hack — NixOS puts user packages on PATH everywhere).
{ config, pkgs, lib, hmPackage, ... }:
let
  # mosh 1.4.0 supports 24-bit color, but ONLY the semicolon SGR form
  # (ESC[38;2;R;G;Bm). The stock `xterm-direct` terminfo emits the ITU colon
  # form (ESC[38:2::R:G:Bm), which mosh silently drops — so a truecolor Emacs
  # theme over mosh renders as monochrome (this is why the earlier
  # TERM=xterm-direct emacsclient aliases were reverted). This entry is
  # `xterm-direct` with setaf/setab rewritten to the semicolon form.
  # Verified locally: `tput setaf 16744448` -> ESC[38;2;255;128;0m, and the
  # low-16 ANSI colors still fall back to ESC[3Nm.
  xterm-direct-semi-src = pkgs.writeText "xterm-direct-semi.ti" ''
    xterm-direct-semi|xterm direct color, semicolon SGR (mosh-safe),
      use=xterm-direct,
      setaf=\E[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;2;%p1%{65536}%/%d;%p1%{256}%/%{255}%&%d;%p1%{255}%&%d%;m,
      setab=\E[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;2;%p1%{65536}%/%d;%p1%{256}%/%{255}%&%d;%p1%{255}%&%d%;m,
  '';
  xterm-direct-semi = pkgs.runCommand "xterm-direct-semi-terminfo"
    { nativeBuildInputs = [ pkgs.ncurses ]; }
    ''
      mkdir -p "$out/share/terminfo"
      # resolve `use=xterm-direct` from ncurses' bundled terminfo DB
      export TERMINFO_DIRS="${pkgs.ncurses}/share/terminfo"
      tic -x -o "$out/share/terminfo" ${xterm-direct-semi-src}
    '';
in
{
  home.stateVersion = "26.05";

  #   mise tool                  -> nixpkgs attribute
  #   babashka                   -> babashka
  #   clj-kondo                  -> clj-kondo
  #   clojure                    -> clojure
  #   java graalvm-community-25  -> graalvmPackages.graalvm-ce
  #   gcloud                     -> google-cloud-sdk
  #   claude-code                -> claude-code  (unfree; allowed in flake.nix)
  #   python 3.14                -> python314
  #   github:cli/cli (gh)        -> gh
  #   nodejs 26                  -> nodejs_24 (26 not yet in nixpkgs)
  #   just                       -> just
  #   heroku-cli                 -> heroku (overridden to 11.6.0 in flake.nix)
  #   make                       -> gnumake
  home.packages = with pkgs; [
    babashka
    clj-kondo
    clojure
    graalvmPackages.graalvm-ce
    google-cloud-sdk
    claude-code
    python314
    gh
    nodejs_24
    just
    heroku
    gnumake
    git

    # --- Modern CLI tools (Rust) ---------------------------------------------
    # Standalone binaries; they don't shadow system find/grep.
    fd          # faster `find`              -> binary: fd
    ripgrep     # faster `grep`              -> binary: rg
    television  # fuzzy finder (ctrl-R/ctrl-T) -> binary: tv
    bottom      # system monitor            -> binary: btm
    delta       # better git diff pager     -> wired into git below
    bat         # better `cat`              -> aliased below
    eza         # better `ls`               -> aliased below
    typos       # source-code spell checker -> binary: typos
    cachix      # binary cache push/pull
    hmPackage   # home-manager CLI (flake-input build, passed via extraSpecialArgs
                # in flake.nix). NOT `pkgs.home-manager` — the nixpkgs build collides
                # with the flake-input one in the standalone `home-manager switch` path.
    # zoxide (`z`) and yazi (`y`) come from their Home Manager modules below.

    # --- Emacs (master "32", nox) + Spacemacs + Clojure --------------------
    # emacs-git-nox = Emacs 32 master (emacs-overlay). Run as `emacs -nw`.
    # Spacemacs (the distro) is cloned into a writable ~/.emacs.d by the
    # activation script below; it manages its own Elisp (byte- + native-compiled
    # on first run). The .spacemacs dotfile is managed declaratively. We ship the
    # binary + the language servers; the terminal is ghostel (prebuilt module).
    emacs-git-nox
    # LSP servers (Spacemacs `lsp` layer) + Clojure runtime for CIDER:
    clojure-lsp                  # clj/cljs/cljc LSP; bundles clj-kondo
    leiningen                    # alt CIDER nREPL launcher (deps.edn/bb also work)
    basedpyright                 # Python LSP
    ruff                         # Python lint/format
    typescript-language-server   # TS/JS LSP
    # NOTE: no vterm toolchain — the claude-code layer uses the ghostel backend,
    # which auto-downloads a prebuilt aarch64-linux native module (loads under
    # nix-ld; no cmake/gcc/libtool needed).
    imagemagick                  # kitty-graphics: image dimension probe + non-PNG -> PNG
    gnutls                      # TLS for Emacs (package.el, ELPA/MELPA)
    cmake                       # needed by vterm/multi-vterm Emacs packages
    mosh                        # responsive SSH replacement for emacs -nw
    xterm-direct-semi           # mosh-safe truecolor terminfo (see let block)
    herdr                       # terminal workspace manager for AI coding agents
  ];

  # --- Emacs daemon (systemd user service) ----------------------------------
  # Starts emacs --fg-daemon at login. Connect with:
  #   et         → emacsclient -t
  #   eat        → emacsclient -t -a '' (start daemon if not running)
  services.emacs = {
    enable = true;
    startWithUserSession = true;
    socketActivation.enable = false;  # start daemon immediately at login
    package = pkgs.emacs-git-nox;      # use the overlay build, not pkgs.emacs (30.2)
  };

  # `emacsclient -t` creates the tty frame inside the DAEMON, which reads the
  # terminfo DB from the daemon's own environment. systemd user services are NOT
  # populated from hm-session-vars.sh, so home.sessionVariables.TERMINFO_DIRS
  # below does not reach the daemon — set it on the service explicitly so the
  # daemon can resolve TERM=xterm-direct-semi.
  systemd.user.services.emacs.Service.Environment = [
    "TERMINFO_DIRS=${xterm-direct-semi}/share/terminfo:/run/current-system/sw/share/terminfo:/etc/terminfo:/usr/share/terminfo"
  ];

  home.sessionVariables = {
    JAVA_HOME = "${pkgs.graalvmPackages.graalvm-ce}";
    EDITOR = "emacs";   # use with: emacs -nw
    # So ncurses/Emacs (interactive shells + non-daemon `emacs -nw`) find the
    # mosh-safe direct-color entry. The daemon gets it via the service env above.
    TERMINFO_DIRS = lib.concatStringsSep ":" [
      "${config.home.profileDirectory}/share/terminfo"
      "/run/current-system/sw/share/terminfo"
      "/etc/terminfo"
      "/usr/share/terminfo"
    ];
  };

  programs.bash = {
    enable = true;
    initExtra = ''
      # zoxide doctor false-positive under ghostel. ghostel wraps PROMPT_COMMAND
      # (stashing the real one, incl. zoxide's `__zoxide_hook`, in
      # __ghostel_original_prompt_command and setting PROMPT_COMMAND to just its
      # own `__ghostel_wrapped_prompt_command`). zoxide's doctor is a *static*
      # substring check on PROMPT_COMMAND — it special-cases VS Code's wrapper var
      # but knows nothing about ghostel's, so it wrongly warns. The hook still runs
      # every prompt via ghostel's eval of the stashed original, so tracking works;
      # this just quiets the bogus warning. See dakra/ghostel + ajeetdsouza/zoxide.
      export _ZO_DOCTOR=0
      # television: ctrl-R = shell history, ctrl-T = smart autocomplete.
      command -v tv >/dev/null && eval "$(tv init bash)"
      # Spacemacs' catppuccin/spacemacs theme needs 24-bit color. xterm-direct-semi
      # (defined in home.nix's let block) tells Emacs the terminal is truecolor
      # AND emits the semicolon SGR form that mosh 1.4.0 understands — plain
      # xterm-direct emits the ITU colon form, which mosh drops (theme goes
      # monochrome). `-nw` keeps it in the terminal (emacs-nox is terminal-only).
      # TERM_PROGRAM=WezTerm: kitty-graphics.el detects WezTerm's Kitty graphics
      # support via this env var (WezTerm's own env doesn't survive SSH into the
      # VM), so it picks the transmit-once Kitty backend over Sixel (which
      # re-emits the full payload on every scroll). Safe here — this VM is only
      # ever driven from WezTerm.
      alias emacs='TERM=xterm-direct-semi TERM_PROGRAM=WezTerm emacs -nw'
      # Emacs daemon client shortcuts. TERM is set on the client; the daemon
      # resolves the entry via TERMINFO_DIRS on its systemd service (see home.nix).
      alias et='TERM=xterm-direct-semi TERM_PROGRAM=WezTerm emacsclient -t'
      alias eat='TERM=xterm-direct-semi TERM_PROGRAM=WezTerm emacsclient -t -a ""'
      # Rust CLI replacements (interactive shells only; scripts use real ls/cat).
      alias ls='eza --group-directories-first'
      alias ll='eza -lah --group-directories-first'
      alias cat='bat --paging=never'
      # Defensively disable xterm mouse-tracking each time the prompt is drawn.
      # A crashed/killed `emacs -nw' (or ghostel) leaves DECSET 1000-1006 on, which
      # turns trackpad motion into escape-code spam at the shell. This resets it the
      # moment you're back at a prompt; Emacs re-enables mouse on its own at startup.
      if [[ $- == *i* ]]; then
        __reset_mouse() { printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l'; }
        PROMPT_COMMAND="__reset_mouse''${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
      fi
    '';
  };

  programs.git.enable = true;
  # delta as git's diff pager. Moved out of programs.git.delta in recent HM;
  # enableGitIntegration must now be set explicitly.
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
  };

  # Cachix binary cache: configure auth token and cache use from the
  # gitignored file on virtiofs. Idempotent and non-fatal — skips
  # silently if the token file is missing.
  home.activation.configureCachix = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    TOKEN_FILE=/mnt/nixos-config/.cachix-token
    if [ -f "$TOKEN_FILE" ]; then
      if ! ${pkgs.cachix}/bin/cachix authtoken check >/dev/null 2>&1; then
        cat "$TOKEN_FILE" | ${pkgs.cachix}/bin/cachix authtoken --stdin
      fi
      ${pkgs.cachix}/bin/cachix use fr33m0nk >/dev/null 2>&1 || true
    fi
  '';

  # Spacemacs (develop, pinned) cloned into a writable ~/.emacs.d. Idempotent
  # (skips if already present). NON-DESTRUCTIVE + NON-FATAL: clones to a temp dir
  # and only swaps it in on success, and always returns 0 — so a clone failure
  # (e.g. network not up yet at early boot) never aborts the rest of the HM
  # activation (it just retries on the next switch).
  home.activation.installSpacemacs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -d "$HOME/.emacs.d/core" ]; then
      if ${pkgs.git}/bin/git clone --branch develop \
           https://github.com/syl20bnr/spacemacs "$HOME/.emacs.d.tmp" \
         && ${pkgs.git}/bin/git -C "$HOME/.emacs.d.tmp" \
           checkout a34310ecbbb85fa9a125caee8fba227af1f94fcf; then
        rm -rf "$HOME/.emacs.d"
        mv "$HOME/.emacs.d.tmp" "$HOME/.emacs.d"
      else
        rm -rf "$HOME/.emacs.d.tmp"
        echo "WARN: Spacemacs clone failed (network?); will retry next activation" >&2
      fi
    fi
  '';
  # Spacemacs dotfile, managed declaratively (read-only symlink -> ~/.spacemacs).
  home.file.".spacemacs".source = ./dot-spacemacs.el;

  # zoxide -> `z`/`zi` (smarter cd); bash integration on by default.
  programs.zoxide.enable = true;
  # yazi file manager -> `y` wrapper that cd's to the last dir on exit.
  programs.yazi = {
    enable = true;
    enableBashIntegration = true;
  };

  # CLI is installed via `hmPackage` in home.packages above (flake-input build).
  # Leaving this false avoids a second, differently-built home-manager landing in
  # the profile on the standalone `home-manager switch` path (buildEnv conflict).
  # The NixOS-module path never installed the CLI from this option anyway.
  programs.home-manager.enable = false;
}
