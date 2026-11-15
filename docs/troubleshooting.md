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

- A required command is missing (`curl`, `tar`, `sha256sum`, `git`).
- A package manifest row has the wrong number of fields or an unknown flag.
- A dotfile source is missing or resolves outside the repository.
- The repository contains a forbidden sensitive path.
- The Fedora release is older than 43 or the architecture is unsupported.

## DNF repository errors

The installer manages these third-party repositories:

- Visual Studio Code
- Brave Browser
- Flathub (Flatpak remote)

Repository files live in `platforms/fedora/repos/`. If Microsoft or Brave is
unreachable, retry later or install without the affected module. Optional
Flatpak applications only produce warnings.

## Flatpak remote is missing

```bash
flatpak remotes --system
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

Flatpak may display the configured remote as `https://dl.flathub.org/repo/`;
both that repository URL and the official `.flatpakrepo` descriptors are
accepted. The installer refuses unapproved URLs rather than replacing an
existing remote. Then rerun the affected module.

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
getent passwd "$USER"
echo "$SHELL"
```

`$SHELL` keeps the value from the current login session even after the login
shell changes. Log out and back in, or run:

```bash
exec zsh
```

Alacritty is configured to start `/usr/bin/zsh` directly. Other terminal
emulators may need a new login session.

## zsh starts slowly or shows a Powerlevel10k warning

```bash
zsh -lic 'exit'
```

The managed `.zshrc` loads Oh My Zsh, Powerlevel10k, and mise when available. If
a local file is blocking startup, inspect the first error without editing the
repository copies.

If mise was just installed and `node` is missing in the current shell:

```bash
exec zsh
mise current
mise exec -- node --version
```

## mise cannot install a runtime

```bash
~/.local/bin/mise --version
~/.local/bin/mise use --global node@26.13.0
~/.local/bin/mise doctor
```

Pins live in `config/runtimes.conf`. Update the explicit version and rerun
`./install.sh --module development` or `./scripts/update.sh`.

## Fonts are not visible

```bash
fc-match "JetBrainsMono Nerd Font"
ls ~/.local/share/fonts/JetBrainsMono | head
```

If the directory is missing:

```bash
./install.sh --module fonts
fc-cache -f ~/.local/share/fonts/JetBrainsMono
```

Log out and back in if the terminal was already open.

## PostgreSQL or Valkey is not running

```bash
systemctl status postgresql.service
systemctl status valkey.service
sudo journalctl -u postgresql.service -n 50
sudo journalctl -u valkey.service -n 50
```

The installer initializes the PostgreSQL cluster only when
`/var/lib/pgsql/data/PG_VERSION` is absent. It does not change authentication,
passwords, or `pg_hba.conf`.

## Virtual machines cannot start

```bash
ls -l /dev/kvm
systemctl is-active virtqemud.socket virtnetworkd.socket virtstoraged.socket virtlogd.socket
virsh -c qemu:///system net-list --all
```

If `/dev/kvm` is missing, enable AMD-V or Intel VT-x in firmware. The legacy
`libvirtd.service` is not enabled; the installer uses modular libvirt sockets.

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
