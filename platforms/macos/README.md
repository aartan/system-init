# macOS platform scaffold

macOS is intentionally **not enabled** in this release.

The repository is architected so a macOS adapter can be added without changing the
installer or module manifests:

- `lib/platform.sh` detects Darwin and loads `platforms/macos/platform.conf`.
- `PLATFORM_SUPPORTED=0` causes a clear, early refusal instead of pretending to
  install Fedora packages on macOS.
- Package declarations already use a platform suffix (`packages.fedora`);
  `packages.macos` can be added per module later.
- `installers/brew.sh` provides a Homebrew adapter library, but it is not invoked
  on Fedora and has not been tested on macOS.

Phase 2 work should include:

1. A Homebrew bootstrap that does not run an untrusted remote shell script.
2. `packages.macos` declarations using `brew` formulae and `cask` applications.
3. macOS dotfile overrides in `dotfiles/platform/macos/`.
4. A Homebrew Bash 5 requirement, because macOS ships Bash 3.2.
5. Validation on a real macOS machine before claiming support.
