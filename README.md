# system-init

**Reproducible workstation provisioning for development and productivity.**

`system-init` is a modular workstation bootstrap project for setting up and maintaining a consistent development environment.

It automates the installation and configuration of essential development tools, terminal utilities, editors, runtimes, container tooling, databases, productivity applications, and system components.

Built around reproducibility, modularity, and safe configuration management, it provides a repeatable way to provision a workstation without manually configuring each component.

**Current platform support:** Fedora 44 Workstation  
**Future platform support:** macOS (planned)

## Features

- **Automated provisioning** — Install and configure a complete development workstation.
- **Modular installation** — Install everything at once or select individual components.
- **Reproducible configuration** — Pinned dependencies and verified downloads.
- **Dotfile management** — Centrally manage and deploy user configurations.
- **Backup and restore** — Protect existing configurations and restore previous states.
- **Safe execution** — Dry-run support, explicit permissions, and conservative system changes.
- **System diagnostics** — Health checks and configuration validation.
- **Maintenance** — Update managed packages, runtimes, and configurations.

## Managed environment

| Category | Components |
|---|---|
| Shell & Terminal | Zsh, Oh My Zsh, Powerlevel10k, Alacritty, btop |
| CLI Tools | eza, fzf, ripgrep, fd, bat, tmux, jq |
| Development | GCC, C++, CMake, Ninja, mise, Node.js, Python, pnpm, Java |
| Editors | VS Code, Neovim, ESLint, Prettier |
| Containers | Podman, Buildah, Skopeo, podman-compose |
| Databases | PostgreSQL, Valkey, DBeaver, pgAdmin |
| Browsers | Firefox, Brave, Google Chrome |
| Productivity | Obsidian, KeePassXC, Proton applications, GitHub Desktop |
| Virtualization | QEMU/KVM, libvirt, virt-manager |
| System | keyd, Fedora system integration |

Some desktop applications and components are optional.

Gaming software is intentionally excluded from the project's scope.

See [docs/inventory.md](docs/inventory.md) for the full software inventory.

## Quick start

\`\`\`bash
git clone <repository-url>
cd system-init

# List available modules
./install.sh --list

# Preview installation
./install.sh --dry-run

# Install the complete workstation
./install.sh
\`\`\`

After installation:

\`\`\`bash
exec zsh
./scripts/doctor.sh
\`\`\`

The installer requests elevated privileges only when required. Downloaded archives are SHA-256 verified, and existing configurations are backed up before replacement.

## Usage

| Command | Description |
|---|---|
| \`./install.sh\` | Install the complete workstation |
| \`./install.sh --list\` | List available modules |
| \`./install.sh --dry-run\` | Preview installation |
| \`./install.sh --no-dotfiles\` | Skip user configuration |
| \`./install.sh --module NAME\` | Install selected modules |
| \`./scripts/update.sh\` | Update managed software |
| \`./scripts/doctor.sh\` | Run system diagnostics |
| \`./scripts/backup.sh\` | Back up managed configurations |
| \`./scripts/restore.sh\` | Restore configuration backups |
| \`./uninstall.sh\` | Remove managed configurations |

## Platform support

| Platform | Status |
|---|---|
| Fedora 44 Workstation | Supported |
| macOS | Planned |

Fedora is the only supported platform in the current release. macOS support is planned but not yet enabled.

## Documentation

- [Architecture](docs/architecture.md)
- [Dotfiles](docs/dotfiles.md)
- [Adding applications](docs/adding-applications.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Software inventory](docs/inventory.md)
- [Security](docs/security.md)
- [Fedora validation](docs/fedora-testing.md)

## License

MIT. See [LICENSE](LICENSE).