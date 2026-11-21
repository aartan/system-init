# system-init

An opinionated init script for setting up a development workstation on Fedora
Linux or macOS.

It installs development tools and desktop applications, configures the shell,
manages dotfiles, and verifies the result. Existing files are backed up before
being replaced, and every action can be previewed with `--dry-run`.

**Supported platforms**

- Fedora Linux 43 or newer (`x86_64` or `aarch64`)
- macOS 27 or newer on Apple Silicon (`arm64`) only

## Requirements

Fedora:

- Fedora Workstation
- An interactive terminal for `sudo`
- Network access for DNF, Flatpak, and pinned downloads

macOS:

- macOS 27 on Apple Silicon
- An interactive terminal for the one-time plan confirmation
- Network access for Homebrew, mise, and pinned downloads
- Homebrew at `/opt/homebrew`; it is installed automatically when missing

system-init does not install Firefox on macOS. See
[macOS details](docs/macos.md).

## Quick start

Fedora:

```bash
git clone <repository-url>
cd system-init
./install.sh --dry-run
./install.sh
./scripts/doctor.sh
```

macOS:

```bash
git clone <repository-url>
cd system-init
./install.sh --dry-run --profile extended
./install.sh
./scripts/doctor.sh
```

## Profiles

| Profile | Contents |
|---|---|
| `core` | CLI tools, shell, fonts, editors, containers, databases, runtimes, and required packages |
| `extended` | Everything in core, plus browsers, productivity apps, virtualization, and optional desktop applications |

On Fedora the installer prompts for a profile; non-interactive runs default to
`core`. On macOS the default is `extended` and the profile prompt is skipped.
Use `--profile core` for the minimal macOS set.

You can also select a profile directly:

```bash
./install.sh --profile core
./install.sh --profile extended
```

Profile membership is defined in `config/profiles.conf`.

## Commands

| Command | Description |
|---|---|
| `./install.sh` | Install and prompt for a profile on Fedora |
| `./install.sh --list` | List available modules and package counts |
| `./install.sh --dry-run` | Preview installation changes |
| `./install.sh --module NAME` | Install selected modules |
| `./install.sh --no-dotfiles` | Skip dotfile setup |
| `./install.sh --yes` | Skip the macOS plan confirmation |
| `./install.sh --non-interactive` | Never prompt; implies `--yes` and uses environment/global settings |
| `./scripts/update.sh` | Update packages and runtimes |
| `./scripts/doctor.sh` | Check the installation |
| `./scripts/backup.sh` | Back up managed dotfiles |
| `./scripts/restore.sh` | Restore a backup |
| `./uninstall.sh` | Remove managed dotfile links |

## Customization

- Add Fedora packages in `modules/<name>/packages.fedora`.
- Add macOS formulae and casks in `modules/<name>/packages.macos`.
- Add modules in `config/modules.conf` and configure profile membership in
  `config/profiles.conf`.
- Change pinned versions in `config/pins.conf`, `config/runtimes.conf`, and
  `config/runtimes.macos.conf`.
- Manage dotfiles through `dotfiles/manifest.tsv`.
- Configure database, virtualization, and Podman machine behavior in
  `config/settings.conf`.

The extended profile installs optional desktop applications automatically.
Direct `--module` installations use `INSTALL_OPTIONAL_APPS` to control them.

See [customization](docs/customization.md), [macOS details](docs/macos.md), and
[troubleshooting](docs/troubleshooting.md) for more details.

## After installation

On both platforms the installer prompts for your Git/GitHub identity: the name
and email used for commits. They are stored in `~/.gitconfig.local` and included
by the managed `.gitconfig`.

Fedora offers to restart at the end of an interactive run. If you skip it, log
out and back in for changes to your login shell, fonts, and session environment
to take effect. macOS does not prompt for a restart; open a new terminal to load
the shell configuration and fonts.

For non-interactive installs, provide the identity through the environment:

```bash
DEV_SETUP_GIT_NAME="Your Name" \
DEV_SETUP_GIT_EMAIL="you@example.com" \
./install.sh --profile core --non-interactive
```

You can also configure it manually:

```bash
git config --file ~/.gitconfig.local user.name "Your Name"
git config --file ~/.gitconfig.local user.email "you@example.com"
```

## Tests

```bash
./tests/macos.sh        # macOS arm64 suite
./tests/portability.sh  # shared helper and manifest checks
./tests/security.sh     # Fedora security regression suite
```

## License

MIT. See [LICENSE](LICENSE).
