# system-init

An opinionated init script for setting up a Fedora workstation for software development.

It sets up your development environment, installs optional desktop and productivity apps, and manages your dotfiles. Existing files are backed up before being replaced, and you can preview changes with `--dry-run`.

**Supported platform:** Fedora Linux 43 or newer

## Requirements

- Fedora Workstation
- An interactive terminal for `sudo`
- Network access for DNF, Flatpak, and pinned downloads

## Quick start

    git clone <repository-url>
    cd system-init

    # Preview the installation
    ./install.sh --dry-run

    # Install (prompts for a profile and Git identity)
    ./install.sh

    # Verify the installation
    ./scripts/doctor.sh

## Profiles

The installer prompts you to choose between two profiles:

| Profile | Contents |
|---|---|
| `core` | CLI tools, shell, fonts, editors, containers, databases, runtimes, and required packages |
| `extended` | Everything in core, plus browsers, productivity apps, virtualization, and optional desktop applications |

You can also select a profile directly:

    ./install.sh --profile core
    ./install.sh --profile extended

Non-interactive installations default to `core` unless a profile or module is specified.

Profile membership is defined in `config/profiles.conf`.

## Commands

| Command | Description |
|---|---|
| `./install.sh` | Install and prompt for a profile |
| `./install.sh --list` | List available modules and package counts |
| `./install.sh --dry-run` | Preview installation changes |
| `./install.sh --module NAME` | Install selected modules |
| `./install.sh --no-dotfiles` | Skip dotfile setup |
| `./scripts/update.sh` | Update packages and runtimes |
| `./scripts/doctor.sh` | Check the installation |
| `./scripts/backup.sh` | Back up managed dotfiles |
| `./scripts/restore.sh` | Restore a backup |
| `./uninstall.sh` | Remove managed dotfile links |

## Customization

Most of the setup can be customized through the configuration files:

- Add or remove packages in `modules/<name>/packages.fedora`.
- Add modules in `config/modules.conf` and configure profile membership in `config/profiles.conf`.
- Change pinned versions in `config/pins.conf` and `config/runtimes.conf`.
- Manage dotfiles through `dotfiles/manifest.tsv`.
- Configure optional database and virtualization services in `config/settings.conf`.

The extended profile installs optional desktop applications automatically. Direct `--module` installations use `INSTALL_OPTIONAL_APPS` to control them.

See [customization](docs/customization.md) and [troubleshooting](docs/troubleshooting.md) for more details.

## After installation

The installer offers to restart at the end of an interactive run. If you skip it, log out and back in for changes to your login shell, fonts, and session environment to take effect.

The installer also prompts for your Git name and email, which are stored in `~/.gitconfig.local` and included by the managed `.gitconfig`.

For non-interactive installations, set:

    DEV_SETUP_GIT_NAME="Your Name"
    DEV_SETUP_GIT_EMAIL="you@example.com"

You can also configure these manually:

    git config --file ~/.gitconfig.local user.name "Your Name"
    git config --file ~/.gitconfig.local user.email "you@example.com"

## License

MIT. See [LICENSE](LICENSE).
