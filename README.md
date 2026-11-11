# system-init

Opinionated Fedora workstation provisioning for software development.

`system-init` installs a development environment, optional desktop productivity
applications, and a managed set of dotfiles. Existing files are backed up before
replacement, and every action can be previewed with `--dry-run`.

**Supported platform:** Fedora Linux 40 or newer

## Requirements

- Fedora Workstation
- An interactive terminal for `sudo`
- Network access for DNF, Flatpak, and pinned downloads

## Quick start

```bash
git clone <repository-url>
cd system-init

# Preview the installation
./install.sh --dry-run

# Install (prompts for a profile)
./install.sh

# Verify the result
./scripts/doctor.sh
```

## Profiles

An interactive install prompts for one of two profiles:

| Profile | Contents |
|---|---|
| `core` | CLI tools, shell, fonts, editors, containers, databases, runtimes |
| `extended` | Everything in core, plus browsers, productivity apps, and virtualization |

Use a profile directly in non-interactive runs:

```bash
./install.sh --profile core
./install.sh --profile extended
```

A non-interactive run without `--profile` or `--module` defaults to `core`.

Profile membership is defined in `config/profiles.conf`.

## Commands

| Command | Description |
|---|---|
| `./install.sh` | Install and prompt for a profile |
| `./install.sh --list` | List modules and package counts |
| `./install.sh --dry-run` | Preview the installation |
| `./install.sh --module NAME` | Install selected modules |
| `./install.sh --no-dotfiles` | Skip user configuration |
| `./scripts/update.sh` | Update packages and runtimes |
| `./scripts/doctor.sh` | Run read-only diagnostics |
| `./scripts/backup.sh` | Back up managed dotfiles |
| `./scripts/restore.sh` | Restore a backup |
| `./uninstall.sh` | Remove managed links |

## Customization

- Add or remove packages in `modules/<name>/packages.fedora`.
- Add modules to `config/modules.conf` and choose profile membership in
  `config/profiles.conf`.
- Change pinned versions in `config/pins.conf` and `config/runtimes.conf`.
- Manage user files through `dotfiles/manifest.tsv`.

See [customization](docs/customization.md) and
[troubleshooting](docs/troubleshooting.md).

## After installation

```bash
exec zsh
./scripts/doctor.sh
```

Log out and back in if the login shell, fonts, or session environment do not
update in existing terminals.

## Safety

- `--dry-run` prints every mutating command without running it.
- Existing dotfiles are backed up to
  `${XDG_STATE_HOME:-$HOME/.local/state}/system-init/backups/`.
- Downloads are verified against pinned SHA-256 checksums.
- No credentials, keys, shell history, or browser profiles are stored in the
  repository.

## License

MIT. See [LICENSE](LICENSE).
