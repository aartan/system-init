# Troubleshooting

## `sudo needs a password, but stdin is not a terminal`

Run `./install.sh` from an interactive terminal. The installer deliberately
refuses to continue when sudo cannot prompt, instead of pretending packages
were installed.

If you use passwordless sudo, the message does not appear. To cache credentials
before a long run:

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
- The Fedora release is older than 40 or the architecture is unsupported.

## DNF repository errors

The installer manages only these third-party repositories:

- Visual Studio Code
- Brave Browser
- Flathub (Flatpak remote)

Repository files live in `platforms/fedora/repos/` and are installed with
GPG checking enabled. If Microsoft or Brave is unreachable, retry later or
temporarily pass `--module` without `editors` or `browsers`. Optional Flatpak
apps only produce warnings.

## Flatpak remote is missing

```bash
flatpak remotes --system
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
```

Then rerun the affected module. Flatpak applications are installed system-wide
by this repository.

## A dotfile is not linked

```bash
ls -l ~/.zshrc
readlink -f ~/.zshrc
./scripts/doctor.sh
```

A path is considered managed only when it is a symlink whose resolved target is
the repository source. Regular files, directories, and broken links are backed
up and replaced on the next run. If a parent directory is itself an unexpected
symlink, inspect it before changing anything.

Restore the original:

```bash
./scripts/restore.sh --list
./scripts/restore.sh --latest
```

## zsh starts slowly or shows a Powerlevel10k warning

Check the shell directly:

```bash
zsh -lic 'exit'
```

The managed `.zshrc` sources `~/.oh-my-zsh/oh-my-zsh.sh`, loads
Powerlevel10k, then activates mise when available. The instant prompt is kept
quiet. If a local file is blocking startup, inspect the first error without
editing the repository copies.

If mise was just installed and `node` is still missing in the current shell:

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

Pins live in `config/runtimes.conf`. Do not change them to `latest`; update the
explicit version and rerun `./install.sh --module development` or
`./scripts/update.sh`.

## Fonts are not visible

```bash
fc-match "JetBrainsMono Nerd Font"
ls ~/.local/share/fonts/JetBrainsMono | head
```

If the directory is missing, run:

```bash
./install.sh --module fonts
fc-cache -f ~/.local/share/fonts/JetBrainsMono
```

Log out and back in if the terminal was already open.

## keyd is not mapping keys

```bash
systemctl status keyd.service
sudo keyd monitor
cat /etc/keyd/default.conf
./scripts/doctor.sh
```

The managed configuration is `platforms/fedora/system/keyd.conf` and is
installed to `/etc/keyd/default.conf`. After a configuration change the
installer restarts the service. Check that the binary version matches the pin:

```bash
/usr/local/bin/keyd --version
```

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

Fedora 44 uses modular libvirt daemons. The legacy `libvirtd.service` is
intentionally not enabled. If `/dev/kvm` is missing, enable AMD-V or Intel VT-x
in firmware. The existing `win11` VM and its images are not migrated.

## A backup restore skipped `/etc/keyd/default.conf`

System paths are skipped by default. Use:

```bash
./scripts/restore.sh --latest --system
```

This prompts for sudo. Restoring a keyd configuration does not restart the
service; restart it explicitly if needed.

## An installation was interrupted

```bash
cat ~/.local/state/system-init/install.in-progress
./scripts/doctor.sh
```

Rerun `./install.sh`. Existing files are backed up, not blindly overwritten.
The marker is removed only after a clean run.

## Package removal during uninstall

`./uninstall.sh --packages` previews the exact Flatpak and DNF packages and asks
for confirmation in an interactive shell. It protects base packages such as
`sudo`, `curl`, `git`, and `flatpak`. Use `--yes` only after reviewing the list.

`./uninstall.sh --system` disables keyd and removes its managed configuration.
It never removes the keyd binary, Oh My Zsh, Powerlevel10k, mise, fonts, or
project files.
