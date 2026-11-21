# macOS

system-init supports macOS 27 or newer on Apple Silicon only. Intel Macs are
rejected; there are no x86_64 pins or compatibility paths.

## What the installer manages

- Homebrew, bootstrapped from a pinned, GitHub-signature-verified installer
  when it is missing.
- Homebrew Bash 5 as a private runtime dependency. The system `/bin/bash` 3.2
  and `/bin/zsh` are left alone.
- Homebrew formulae and casks listed in `modules/*/packages.macos`.
- Alacritty from the official GitHub release. Homebrew disables its cask
  because the upstream app is ad-hoc signed and fails the Gatekeeper audit, so
  system-init verifies the pinned DMG SHA-256 and installs `Alacritty.app`
  directly.
- Oh My Zsh with `history-substring-search`, plus the Homebrew
  `zsh-autosuggestions` and `zsh-syntax-highlighting` formulae.
  Powerlevel10k is the prompt and uses the same `.p10k.zsh` configuration as
  Fedora. The OS icon is the native macOS icon.
- Nerd Fonts directly in `~/Library/Fonts`.
- Native Podman with a `podman machine` VM. The installer creates a machine
  when none exists and starts an existing stopped machine.
- Postgres.app as the PostgreSQL distribution and Valkey as a Homebrew service.
- UTM for virtualization. libvirt, QEMU, virt-manager, and GNOME Boxes are not
  installed.
- VS Code settings at
  `~/Library/Application Support/Code/User/settings.json`.
- Node.js LTS through mise. No Python, pnpm, Java, Go, or other runtimes are
  installed on macOS.

Firefox is not installed on macOS. Proton Mail, Proton Pass, and Proton VPN are
not installed.

## Requirements

- macOS 27 or newer on Apple Silicon (`arm64`).
- An interactive terminal for the profile and Git identity prompts, plus the
  one-time Homebrew/Bash confirmation if prerequisites are missing.
- Network access for Homebrew, mise, and pinned downloads.
- Homebrew is installed automatically if missing. If it is already present, it
  must be at `/opt/homebrew`.

Homebrew casks may show macOS installer, Gatekeeper, or application-specific
prompts. system-init does not bypass those prompts and never runs Homebrew with
`sudo`.

## Quick start

```bash
git clone <repository-url>
cd system-init
./install.sh --dry-run
./install.sh
./scripts/doctor.sh
```

Like Fedora, an interactive macOS run prompts for the `core` or `extended`
profile and defaults to `core`. Use `--profile extended` for the full
workstation set. `--non-interactive` skips every prompt, uses `core` unless
`--profile` is supplied, and reads or reuses the existing Git identity.

The installer prompts for your Git/GitHub identity name and email and stores
them in `~/.gitconfig.local`, which is included by the managed `.gitconfig`.
Existing values, including your global Git configuration, are offered as
defaults.

For non-interactive installs:

```bash
DEV_SETUP_GIT_NAME="Your Name" \
DEV_SETUP_GIT_EMAIL="you@example.com" \
./install.sh --profile extended --non-interactive
```

## Homebrew bootstrap and verification

When Homebrew is missing, system-init:

1. Downloads the installer from the commit pinned in
   `config/pins.conf#HOMEBREW_INSTALL_COMMIT`.
2. Verifies that GitHub reports the commit signature as valid.
3. Verifies the installer's SHA-256 against `HOMEBREW_INSTALL_SHA256`.
4. Prints the commit and checksum in the installation plan.
5. Executes the verified file with `/bin/bash`, never `curl | bash`.
6. Installs the Homebrew `bash` formula and re-executes the installer under
   Bash 5.

On a fresh Mac, the bootstrap asks the same `core`/`extended` profile question
and confirms the prerequisite installation plan once before making changes.
The selected profile is reused by the main installer, so it is not asked twice.

Verification failure stops the installation before anything is executed.
Homebrew formulae and casks track the current Homebrew versions, matching the
Fedora package policy. The Homebrew installer, Alacritty DMG, mise, the Nerd
Font archive, and the shell framework commits remain pinned.

## Podman machines

Podman on macOS needs a Linux VM. By default `PODMAN_MACHINE_AUTO=1` in
`config/settings.conf`:

- no machine: `podman machine init`, then `podman machine start`;
- existing stopped machine: `podman machine start`;
- running machine: left alone.

Set `PODMAN_MACHINE_AUTO=0` to manage machines yourself. `scripts/doctor.sh`
then warns instead of failing when no machine is running. The machine name is
controlled by `PODMAN_MACHINE_NAME` and defaults to `default`.

## Databases

- `postgres-app` installs `/Applications/Postgres.app`.
- Set `ENABLE_DATABASE_SERVICES=1` to launch Postgres.app and wait for
  `pg_isready`. PostgreSQL is never managed with `brew services`.
- Valkey is started with `brew services start valkey` when database services
  are enabled.
- `uninstall.sh --packages` never removes Postgres.app data under
  `~/Library/Application Support/Postgres`.

## Virtualization

`cask utm` installs UTM, which uses Apple's Hypervisor framework. The installer
checks `sysctl -n kern.hv_support`; there is no libvirt network, socket, or
service to configure.

## Shell

- macOS has used `/bin/zsh` as the default login shell since Catalina; macOS
  27+ therefore already uses it. `/etc/shells` is not modified, and `chsh` only
  runs if the account was explicitly changed to another shell.
- Oh My Zsh provides plugins and is kept at the pinned commit.
- `ZSH_THEME="powerlevel10k/powerlevel10k"` and `~/.p10k.zsh` is shared with
  Fedora. The p10k OS icon is left native, so macOS shows the Apple icon.
- `zsh-autosuggestions` and `zsh-syntax-highlighting` are sourced from
  `$(brew --prefix)/share/...` exactly once. They are not listed in the Oh My
  Zsh `plugins` array.
- Keg-only `openssl@3`, GNU make's `gnubin` directory, and Postgres.app's `bin`
  directory are added to `PATH`.
- Alacritty starts `/bin/zsh`, which exists on both platforms.

## PATH and sudo

The installer uses `/opt/homebrew/bin:/opt/homebrew/sbin` plus the system
directories. Homebrew, mise, fonts, dotfiles, and the login shell are managed
without root. macOS operations do not request `sudo` up front.

## Re-running the installer

Running `./install.sh` again is safe. Existing Homebrew formulae and casks,
fonts, dotfiles, mise runtimes, Alacritty, the Podman machine, and configured
services are detected and skipped. Components that failed previously are
retried. A second run with no changes does not create a new dotfile backup
snapshot. Switching from `extended` to `core` does not uninstall packages; use
`./uninstall.sh --packages` for explicit removal.

## Updates and uninstall

```bash
./scripts/update.sh
./uninstall.sh --dry-run
./uninstall.sh --packages --yes
```

Updates run `brew update`, `brew upgrade --formula`, and
`brew upgrade --cask`. Package removal keeps protected formulae such as
`bash`, `git`, `curl`, and `openssl@3`. Managed dotfile links are removed only
when they still point at this repository.

## Troubleshooting

See [troubleshooting](troubleshooting.md) for Homebrew verification, Bash 3.2,
Podman machine, Postgres.app, Gatekeeper, and login-shell issues.

Run the macOS test suite with:

```bash
./tests/macos.sh
```
