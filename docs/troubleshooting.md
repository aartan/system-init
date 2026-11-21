# Troubleshooting

## `sudo needs a password, but stdin is not a terminal`

Run `./install.sh` from an interactive terminal. The installer refuses to
continue when sudo cannot prompt.

To cache credentials before a long run:

```bash
sudo -v
./install.sh
```

## Preflight fails before anything changes

Run the checks directly:

```bash
./install.sh --list
./scripts/doctor.sh
```

Common causes:

- A required command is missing (`curl`, `tar`, `shasum` on macOS, `sha256sum` on Fedora, and `git`).
- A package manifest row has the wrong number of fields or an unknown flag.
- A dotfile source is missing or resolves outside the repository.
- The repository contains a forbidden sensitive path.
- Fedora is older than 43, macOS is older than 27, or the architecture is
  unsupported. macOS requires Apple Silicon.

## macOS: Homebrew bootstrap verification fails

The installer refuses to execute the Homebrew installer unless all three checks
pass:

- the commit matches `HOMEBREW_INSTALL_COMMIT` in `config/pins.conf`;
- GitHub reports that commit's signature as verified;
- the downloaded file matches `HOMEBREW_INSTALL_SHA256`.

Retry with network access, or update both pins together after independently
reviewing a new upstream installer commit. Never bypass the checksum.

## macOS: Bash 3.2 is detected

macOS ships Bash 3.2 at `/bin/bash`. system-init installs the Homebrew `bash`
formula and re-executes itself under Bash 5. If the installer stops after
mentioning Bash 5, install it manually and rerun:

```bash
brew install bash
/opt/homebrew/bin/bash ./install.sh
```

The system `/bin/bash` is never replaced.

## macOS: Podman machine is missing or stopped

Check the machine state:

```bash
podman machine list
podman machine start default
podman info
```

With `PODMAN_MACHINE_AUTO=1` (the default), the installer creates a machine when
none exists and starts a stopped one. If `podman machine init` fails, confirm
that Apple Hypervisor is available:

```bash
sysctl -n kern.hv_support
```

Set `PODMAN_MACHINE_AUTO=0` to manage machines manually.

## macOS: Alacritty reports a disabled Homebrew cask

Homebrew disables the `alacritty` cask because the upstream app is ad-hoc
signed and fails its Gatekeeper audit. system-init does not bypass that check;
it downloads the official release DMG instead, verifies the pinned SHA-256, and
installs `Alacritty.app`.

Check the installed version:

```bash
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
  /Applications/Alacritty.app/Contents/Info.plist
```

Rerun the terminal module after updating `ALACRITTY_VERSION` and
`ALACRITTY_DMG_SHA256` in `config/pins.conf`:

```bash
./install.sh --module terminal
```

## macOS: Postgres.app does not start

Open it once from Finder or run:

```bash
open -a Postgres.app
/Applications/Postgres.app/Contents/Versions/latest/bin/pg_isready
```

If macOS blocks the app, allow it in System Settings > Privacy & Security.
system-init never disables Gatekeeper and never deletes Postgres.app data.

## macOS: the login shell did not change

The installer uses the system zsh and does not edit `/etc/shells`:

```bash
dscl . -read "/Users/$USER" UserShell
chsh -s /bin/zsh "$USER"
exec zsh
```

macOS may ask for your password when changing your own login shell.

## DNF repository errors

The installer manages these third-party repositories:

- Visual Studio Code
- Brave Browser
- Flathub (Flatpak remote)

Repository files live in `platforms/fedora/repos/`. If Microsoft or Brave is
unreachable, retry later or install without the affected module. Optional
Flatpak applications only produce warnings.

## Flatpak remote is missing

The installer ensures an approved remote before any Flatpak install. If an
existing remote has an unexpected URL, it refuses to overwrite it.

```bash
flatpak remotes --system
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

Flatpak may display the configured remote as `https://dl.flathub.org/repo/`;
both that repository URL and the official `.flatpakrepo` descriptors are
accepted. Then rerun the affected module.

## A dotfile is not linked

```bash
ls -l ~/.zshrc
readlink -f ~/.zshrc
./scripts/doctor.sh
```

A path is managed only when it is a symlink whose resolved target is the
repository source. Regular files, directories, and broken links are backed up
and replaced on the next run.

Restore the original:

```bash
./scripts/restore.sh --list
./scripts/restore.sh --latest
```

`--list` shows `signed`, `unsigned-v2`, `invalid-payload`, `invalid-v2`,
`invalid-signature`, `empty-v2`, `legacy-unverified`, or `legacy-empty`. `signed` means the
signature and every payload hash verified. Legacy v1 snapshots require
`--allow-legacy`; unsigned v2 snapshots require `--allow-unsigned`. Neither flag
bypasses an invalid v2 signature, revoked/expired signer, or payload hash.
Empty snapshots are refused.

If a restore is interrupted or reports a retained journal:

```bash
ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/system-init/journal/"
./scripts/restore.sh --recover-journal PATH
```

Each staging directory is named `.system-init-restore.*` under the affected
destination's parent. `stage/old` holds the previous regular file. Recovery only
moves `old` back when the destination is missing; if the destination exists, or
the state is unresolved/failed, the staging directory and journal are left in
place for manual inspection and the command exits nonzero. Journals are
accepted only from the canonical state journal directory, with current-user
ownership and restrictive permissions; traversal, symlinked journals/staging
directories, directory `stage/old` payloads, symlink `stage/old` payloads, and
destinations outside the managed allowlist are refused. Never delete a staging
directory before checking its `old` file.

## New terminals still use bash

Check the login shell recorded by the system:

```bash
getent passwd "$USER"          # Fedora
dscl . -read "/Users/$USER" UserShell   # macOS
echo "$SHELL"
```

`$SHELL` keeps the value from the current login session even after the login
shell changes. Log out and back in, or run:

```bash
exec zsh
```

Alacritty is configured to start `/bin/zsh` directly. Other terminal emulators
may need a new login session.

## zsh starts slowly or shows a Powerlevel10k warning

```bash
zsh -lic 'exit'
```

The managed `.zshrc` loads Oh My Zsh, Powerlevel10k, and mise on both Fedora and
macOS. macOS uses the same `.p10k.zsh` with the native Apple OS icon. If a local
file is blocking startup, inspect the first error without editing the repository
copies.

If mise was just installed and `node` is missing in the current shell:

```bash
exec zsh
mise current
mise exec -- node --version
```

## mise cannot install a runtime

```bash
~/.local/bin/mise --version
~/.local/bin/mise use --global node@26.13.1
~/.local/bin/mise doctor
```

Fedora pins live in `config/runtimes.conf`; macOS pins live in
`config/runtimes.macos.conf` and contain Node.js LTS only. Update the explicit
version and rerun `./install.sh --module development` or
`./scripts/update.sh`.

## Fonts are not visible

Fedora:

```bash
fc-match "JetBrainsMono Nerd Font"
ls ~/.local/share/fonts/JetBrainsMono | head
fc-cache -f ~/.local/share/fonts/JetBrainsMono
```

macOS:

```bash
ls ~/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf
```

If the directory is missing:

```bash
./install.sh --module fonts
```

Log out and back in if the terminal was already open.

## PostgreSQL or Valkey is not running

Fedora:

```bash
systemctl status postgresql.service
systemctl status valkey.service
sudo journalctl -u postgresql.service -n 50
sudo journalctl -u valkey.service -n 50
```

macOS:

```bash
open -a Postgres.app
/Applications/Postgres.app/Contents/Versions/latest/bin/pg_isready
brew services list
```

On Fedora the installer initializes the PostgreSQL cluster only when
`/var/lib/pgsql/data/PG_VERSION` is absent. It does not change authentication,
passwords, or `pg_hba.conf`. On macOS, PostgreSQL is managed by Postgres.app and
Valkey by Homebrew services.

## Virtual machines cannot start

Fedora:

```bash
ls -l /dev/kvm
systemctl is-active virtqemud.socket virtnetworkd.socket virtstoraged.socket virtlogd.socket
virsh -c qemu:///system net-list --all
```

macOS:

```bash
sysctl -n kern.hv_support
open -a UTM
```

If `/dev/kvm` is missing on Fedora, enable AMD-V or Intel VT-x in firmware. The
legacy `libvirtd.service` is not enabled; the installer uses modular libvirt
sockets. On macOS, UTM uses Apple's Hypervisor framework; `kern.hv_support`
must return `1` for hardware acceleration.

## An installation was interrupted

```bash
cat ~/.local/state/system-init/install.in-progress
./scripts/doctor.sh
```

Rerun `./install.sh`. Existing files are backed up, not overwritten. The marker
is removed only after a clean run.

## Package removal during uninstall

`./uninstall.sh --packages` previews the Flatpak and DNF packages and asks for
confirmation in an interactive shell. It protects base packages such as `sudo`,
`curl`, `git`, and `flatpak`. Use `--yes` only after reviewing the list.

`./uninstall.sh` never removes Oh My Zsh, Powerlevel10k, mise, fonts, or user
project files.
