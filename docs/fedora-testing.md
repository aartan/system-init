# Fedora validation

This document records what has actually been validated on the Fedora target and
what remains unverified. Do not describe the repository as fully installed or
fully validated until every **PENDING** item below has been completed on real
hardware.

Validation date: **2026-11-14**
Target: Fedora Linux 44 Workstation (x86_64), GNOME Shell 50.6 on Wayland.

## Status summary

| Area                                        | Status      | Notes                                                       |
| ------------------------------------------- | ----------- | ----------------------------------------------------------- |
| Bash syntax for every script                | **PASS**    | `bash -n` on all `*.sh`                                     |
| ShellCheck                                  | **PASS**    | ShellCheck 0.11.0, exit 0                                   |
| Installer help and module listing           | **PASS**    | `--help`, `--list`                                          |
| Unknown module handling                     | **PASS**    | exit 2 with a clear error                                   |
| Full dry-run                                | **PASS**    | exit 0; no state, logs, or backups created                  |
| `--module` and `--no-dotfiles` dry-runs     | **PASS**    | exit 0                                                      |
| Dotfile conflict backup                     | **PASS**    | isolated home; six originals backed up                      |
| Dotfile idempotency                         | **PASS**    | repeated install adds no links or snapshots                 |
| Broken-symlink handling                     | **PASS**    | backed up and replaced                                      |
| Dotfile restore                             | **PASS**    | original contents recovered                                 |
| Uninstall link removal                      | **PASS**    | managed links removed, unmanaged files kept                 |
| Pre-install backup filtering                | **PASS**    | snapshots only when targets need replacement                |
| `backup.sh` / `restore.sh` / `--list`       | **PASS**    | isolated home                                               |
| mise binary download and checksum           | **PASS**    | v2026.11.8                                                  |
| mise runtimes                               | **PASS**    | Node 26.13.0, Python 3.14.10, pnpm 12.18.0                  |
| Nerd Fonts archive and font checksum        | **PASS**    | 96 TTF installed in an isolated home                        |
| keyd no-op path                             | **PASS**    | existing v2.6.0 and matching config detected                |
| keyd source build from pin                  | **PENDING** | existing binary already matched; build branch not exercised |
| DNF package installation                    | **PENDING** | needs interactive sudo                                      |
| Flatpak installation                        | **PENDING** | needs interactive sudo                                      |
| Systemd services and PostgreSQL init        | **PENDING** | needs interactive sudo                                      |
| Real-home dotfile migration                 | **PENDING** | live `$HOME` intentionally unchanged                        |
| `doctor.sh` on the installed workstation    | **PENDING** | requires the real installation                              |
| Repeated full installation on real hardware | **PENDING** | idempotency verified only in isolation                      |
| Backup/restore on the real workstation      | **PENDING** | isolated tests only                                         |
| macOS                                       | **N/A**     | scaffold only; `PLATFORM_SUPPORTED=0`                       |

## Static validation

Commands run from the repository root:

```bash
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck -x install.sh uninstall.sh lib/*.sh installers/*.sh \
  platforms/fedora/*.sh modules/*/post-install.sh scripts/*.sh
```

Result: both commands exited 0. ShellCheck 0.11.0 was used from a locally
downloaded Fedora RPM because it is not installed system-wide on the
workstation. `.shellcheckrc` disables only `SC1091`, because runtime library
paths are constructed from `$REPO_ROOT` and cannot be followed statically.

## CLI and dry-run validation

| Command                                    | Result                                         |
| ------------------------------------------ | ---------------------------------------------- |
| `./install.sh --help`                      | exit 0, usage printed                          |
| `./install.sh --list`                      | exit 0, 11 modules and package counts printed  |
| `./install.sh --module nope --dry-run`     | exit 2, `Unknown module: nope`                 |
| `./install.sh --module terminal --dry-run` | exit 0, resolves `core fonts terminal`         |
| `./install.sh --dry-run --no-dotfiles`     | exit 0, prints `Skipping dotfiles`             |
| `./install.sh --dry-run`                   | exit 0, all modules processed without failures |

The full dry-run also confirmed:

- Every package command is displayed, not executed.
- The pre-install backup stage lists the existing dotfile targets that would be
  backed up.
- No `~/.local/state/system-init` directory is created.
- The final message is `Dry-run complete. No changes were made.`

## Isolated home-directory tests

All tests used temporary values for `DEV_SETUP_TARGET_HOME`; the real
`/home/aartan` configuration was not modified. Temporary homes were created
under `/tmp/opencode/` and are disposable.

### Dotfiles

Test scenario:

1. Seed six existing files with known unique contents.
2. Run the dotfile installer.
3. Verify six symlinks point into the repository.
4. Run the installer again and verify no additional snapshot or links.
5. Replace one link with a broken symlink, run again, and verify the broken
   link is backed up and replaced.
6. Restore the first snapshot and verify all original contents return.
7. Reinstall, run `uninstall.sh`, and verify managed links are removed.

Result: **PASS**. The conflict snapshot contained six manifest rows. The
idempotent run created no new snapshot. The broken-symlink run created a new
snapshot. Restore recovered the known original contents. Uninstall removed
only managed paths.

The test also confirmed that `dotfiles_check_status` returns success after a
complete install.

### Pre-install backup

Tested directly with `backup_dotfile_targets`:

- Six unmanaged existing files produced a snapshot with
  `reason=pre-install` and six manifest rows.
- A home with all six targets already correctly linked produced no snapshot.
- An empty home produced no empty snapshot.

Result: **PASS**.

### Backup and restore scripts

Test scenario:

1. Seed six files.
2. Run `./scripts/backup.sh`.
3. Verify `Backed up 6 path(s)` and a six-row manifest.
4. Change a file.
5. Restore the snapshot with `./scripts/restore.sh --snapshot ...`.
6. Verify the original content.
7. Run `./scripts/restore.sh --list` and verify the snapshot metadata and path
   count.

Result: **PASS**.

## Runtime and font tests

### mise

An isolated home installed the pinned mise binary after SHA-256 verification,
then installed all three runtimes from `config/runtimes.conf`. Verification
produced:

```text
node   v26.13.0
python Python 3.14.10
pnpm   12.18.0
```

The resulting `~/.config/mise/config.toml` contained the three explicit pins.
No runtime was installed as a global system npm package.

### Fonts

An isolated home downloaded the pinned Nerd Fonts v3.5.1 archive, verified both
the archive checksum and the Regular font checksum, and installed 96 TTF files
under `~/.local/share/fonts/JetBrainsMono`.

On the real workstation, `fc-match 'JetBrainsMono Nerd Font'` resolves to
`JetBrainsMonoNerdFont-Regular.ttf`. Alacritty rendering was not re-tested as
part of this repository validation.

### keyd

The live workstation already has `/usr/local/bin/keyd` v2.6.0 at commit
`f564288`, `keyd.service` enabled and active, and a configuration identical to
`platforms/fedora/system/keyd.conf`. The installer's idempotent no-op path
passed. Because the installed binary already matched the pin, the source
download, build, and privileged install branch was **not** exercised in this
validation.

## Package metadata checks

The following names were confirmed in Fedora 44 metadata before being added to
module manifests:

- `wget2-wget` 2.3.0
- `bat` 0.26.1
- `fd-find` 10.4.2
- `nmap-ncat` 7.92
- `java-25-openjdk-headless` 25.0.5.0.8
- `podman-compose` 1.6.0
- `shellcheck` 0.11.0
- `zlib-devel` resolves to `zlib-ng-compat-devel` 2.3.3 on Fedora 44
- `md.obsidian.Obsidian` on Flathub

This is metadata validation only. No DNF or Flatpak transaction was performed
during the isolated tests.

## What has not been tested

The following require a real, interactive installation and must not be claimed
as complete until they pass:

1. `./install.sh` with sudo access.
2. DNF repository setup for VS Code and Brave, including GPG key import.
3. Installation of every required DNF package and optional Flatpak app.
4. PostgreSQL cluster detection and `valkey.service` enablement.
5. Modular libvirt socket enablement and the default network check.
6. keyd source build and privileged configuration installation when the
   installed version differs from the pin.
7. Changing the login shell with `chsh`.
8. Cloning the pinned Oh My Zsh, Powerlevel10k, and history-substring-search
   checkouts into the real `$HOME`.
9. Linking the six managed dotfiles into the real `$HOME`, including backups of
   the current live files.
10. `zsh -lic 'exit'` with the real migrated `.zshrc`.
11. `./scripts/doctor.sh` on the installed workstation.
12. A second full installation to confirm idempotency in the real environment.
13. Real backup, restore, and uninstall checks after migration.

## Release gate

Run these in order after the repository is reviewed:

```bash
# 1. Inspect the plan without changing anything.
./install.sh --dry-run

# 2. Apply. This asks for sudo interactively.
./install.sh

# 3. Start a fresh shell and verify runtime activation.
exec zsh
mise current
node --version
python --version
pnpm --version

# 4. Read-only health check.
./scripts/doctor.sh

# 5. Confirm the managed links.
readlink -f ~/.zshrc ~/.p10k.zsh ~/.gitconfig
readlink -f ~/.config/alacritty/alacritty.toml
readlink -f ~/.config/btop/btop.conf
readlink -f ~/.config/Code/User/settings.json

# 6. Confirm a repeated install is idempotent.
./install.sh --dry-run
./install.sh

# 7. Test backups and restore before relying on them.
./scripts/backup.sh
./scripts/restore.sh --list

# 8. Re-run the doctor and record the output in this file.
./scripts/doctor.sh
```

Before the first real run, create a manual safety snapshot:

```bash
./scripts/backup.sh
```

The installer also snapshots real dotfile conflicts automatically, but an
explicit pre-run snapshot is a useful independent copy.

After a successful run, replace the **PENDING** entries above with observed
results, including any package names that were unavailable or any service that
needed manual intervention. Do not mark the Fedora phase complete based only on
dry-run or isolated-home results.
