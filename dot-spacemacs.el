;; -*- mode: emacs-lisp; lexical-binding: t -*-
;; Spacemacs dotfile, managed by Home Manager (read-only symlink -> ~/.spacemacs).
;; Run via `emacs -nw' (WezTerm, truecolor via TERM=xterm-direct). LSP servers
;; come from Nix (clojure-lsp, basedpyright, ruff, typescript-language-server).

(defun dotspacemacs/layers ()
  (setq-default
   dotspacemacs-distribution 'spacemacs
   dotspacemacs-enable-lazy-installation 'unused
   dotspacemacs-ask-for-lazy-installation t
   dotspacemacs-configuration-layer-path '()
   dotspacemacs-configuration-layers
   '(better-defaults
     emacs-lisp
     git
     lsp
     syntax-checking
     auto-completion
     (clojure :variables
              clojure-backend 'lsp          ;; clojure-lsp (CIDER still used for the REPL)
              clojure-enable-linters 'clj-kondo
              clojure-enable-clj-refactor t)
     (python :variables python-backend 'lsp)
     (typescript :variables typescript-backend 'lsp)
     (javascript :variables javascript-backend 'lsp)
     html
     yaml
     markdown
     (shell :variables
            shell-default-shell 'eshell   ;; ghostel is the real terminal (below)
            shell-default-height 30
            shell-default-position 'bottom)
     ;; Claude Code CLI (claude-code-ide.el) with the ghostel terminal backend.
     (claude-code :variables
                  claude-code-ide-terminal-backend 'ghostel))
   ;; ghostel = libghostty terminal emulator; evil-ghostel = evil states in it;
   ;; clipetty = OSC52 clipboard (all on MELPA). kitty-graphics = inline images in
   ;; `emacs -nw' via the Kitty graphics protocol (GitHub; not on MELPA).
   dotspacemacs-additional-packages
   '(clipetty ghostel evil-ghostel
     (kitty-graphics :location (recipe :fetcher github
                                       :repo "cashmeredev/kitty-graphics.el")))
   dotspacemacs-frozen-packages '()
   dotspacemacs-excluded-packages '()
   dotspacemacs-install-packages 'used-only))

(defun dotspacemacs/init ()
  (setq-default
   dotspacemacs-enable-emacs-pdumper nil
   dotspacemacs-gc-cons '(100000000 0.1)
   dotspacemacs-read-process-output-max (* 1024 1024)
   dotspacemacs-use-spacelpa nil
   dotspacemacs-elpa-https t
   dotspacemacs-editing-style 'vim
   dotspacemacs-startup-banner 'official
   dotspacemacs-startup-lists '((recents . 5) (projects . 5))
   dotspacemacs-themes '(spacemacs-dark spacemacs-light)
   dotspacemacs-mode-line-theme 'spacemacs
   dotspacemacs-default-font '("JetBrainsMono Nerd Font" :size 13)
   dotspacemacs-leader-key "SPC"
   dotspacemacs-emacs-command-key "SPC"
   dotspacemacs-ex-command-key ":"
   dotspacemacs-emacs-leader-key "M-m"
   dotspacemacs-major-mode-leader-key ","
   dotspacemacs-distinguish-gui-tab nil
   dotspacemacs-large-file-size 1
   dotspacemacs-auto-save-file-location 'cache
   dotspacemacs-which-key-delay 0.3
   dotspacemacs-loading-progress-bar t
   dotspacemacs-line-numbers nil
   dotspacemacs-smartparens-strict-mode nil
   dotspacemacs-highlight-delimiters 'all
   dotspacemacs-persistent-server nil
   ;; Use ripgrep for project search.
   dotspacemacs-search-tools '("rg" "grep")
   dotspacemacs-whitespace-cleanup nil))

(defun dotspacemacs/user-env ()
  (spacemacs/load-spacemacs-env))

(defun dotspacemacs/user-init ()
  (setq package-archives
      '(("gnu"    . "https://raw.githubusercontent.com/d12frosted/elpa-mirror/master/gnu/")
        ("nongnu" . "https://raw.githubusercontent.com/d12frosted/elpa-mirror/master/nongnu/")
        ("melpa"  . "https://raw.githubusercontent.com/d12frosted/elpa-mirror/master/melpa/")))
  (setq gnutls-algorithm-priority "NORMAL:-VERS-TLS1.3")
  ;; ghostel: auto-download the prebuilt native module on first use (no prompt).
  ;; The aarch64-linux prebuilt loads cleanly under nix-ld; no toolchain needed.
  (setq ghostel-module-auto-install 'download))

(defun dotspacemacs/user-config ()
  ;; OSC52 clipboard for `emacs -nw' over SSH (WezTerm) — copies to Mac clipboard.
  (global-clipetty-mode 1)
  ;; Use the Nix-provided basedpyright as the Python LSP server.
  (with-eval-after-load 'lsp-pyright
    (setq lsp-pyright-langserver-command "basedpyright"))

  ;; Cap clojure-lsp's GraalVM native-image heap (defaults to ~80% of VM RAM).
  ;; -Xmx is consumed by SubstrateVM before clojure-lsp parses args. If a large
  ;; project fails to index / the server keeps restarting, raise this ceiling.
  (setq lsp-clojure-custom-server-command '("clojure-lsp" "-Xmx1g"))

  ;; Forge: Spacemacs only adds forge's default bindings (the `@' forge-dispatch
  ;; menu in magit-status) when editing-style is 'emacs; we use 'vim. forge loads
  ;; lazily (:after magit, on first magit-status) — after user-config — so setting
  ;; this here, before it loads, restores `@'.
  (setq forge-add-default-bindings t)

  ;; Terminal mouse: xterm-mouse-mode is on (wheel events arrive) but unbound, so
  ;; trackpad scroll reports `<wheel-down> is undefined'. Bind the four directions.
  (unless (display-graphic-p)
    (xterm-mouse-mode 1)
    (global-set-key (kbd "<wheel-up>")    (lambda () (interactive) (scroll-down 3)))
    (global-set-key (kbd "<wheel-down>")  (lambda () (interactive) (scroll-up 3)))
    (global-set-key (kbd "<wheel-left>")  (lambda () (interactive) (scroll-right 3)))
    (global-set-key (kbd "<wheel-right>") (lambda () (interactive) (scroll-left 3))))

  ;; Inline images in `emacs -nw' via the Kitty graphics protocol. Video and org
  ;; heading-sizing (both CPU-heavy) stay off — they're nil by default. The mode
  ;; lighter shows the chosen backend: KittyGfx[K] (cheap, transmit-once) vs [S]
  ;; (Sixel, re-emits on scroll). TERM_PROGRAM=WezTerm (set in the emacs alias)
  ;; is what lets it pick [K] over SSH, where WezTerm's own env doesn't reach.
  (when (and (not (display-graphic-p)) (fboundp 'kitty-graphics-mode))
    (kitty-graphics-mode 1))

  ;; --- ghostel extensions (bundled with the ghostel package; just enable) ---
  ;; eshell visual commands (top, less, htop, …) open in a ghostel buffer.
  ;; Deferred via eshell-load-hook + autoload so eshell isn't force-loaded at
  ;; startup (mirrors the evil-ghostel autoload below).
  (autoload 'ghostel-eshell-visual-command-mode "ghostel-eshell" nil t)
  (add-hook 'eshell-load-hook #'ghostel-eshell-visual-command-mode)
  ;; Run all `compile' commands in a ghostel buffer, and replace comint's
  ;; ansi-color-process-output with ghostel's VT parser. These are global modes
  ;; we always want on; user-config runs after after-init, so enable them now.
  (require 'ghostel-compile)
  (ghostel-compile-global-mode)
  (require 'ghostel-comint)
  (ghostel-comint-global-mode)

  ;; --- ghostel terminal: evil integration + Spacemacs-style bindings --------
  ;; Autoload so the hook reliably activates evil-ghostel on the first terminal.
  (autoload 'evil-ghostel-mode "evil-ghostel" "Evil integration for ghostel." t)
  (add-hook 'ghostel-mode-hook #'evil-ghostel-mode)
  (spacemacs/declare-prefix "at" "ghostel-terminal")
  (spacemacs/set-leader-keys
    "'"   'ghostel               ;; SPC '  -> quick terminal
    "att" 'ghostel               ;; SPC a t t -> new/open terminal
    "atp" 'ghostel-project       ;; SPC a t p -> terminal in project root
    "ato" 'ghostel-other         ;; SPC a t o -> next terminal / create
    "atb" 'ghostel-list-buffers)) ;; SPC a t b -> pick a ghostel buffer
