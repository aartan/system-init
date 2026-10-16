# Discovery baseline

The repository was derived from a read-only inspection of the existing Fedora
workstation on **2026-11-14**. No packages, services, shell files, or user
configuration were modified during discovery. This document records what was
found so later changes can be audited against the original state.

## Host

| Item | Observed value |
|---|---|
| Distribution | Fedora Linux 44 Workstation Edition |
| Architecture | x86_64 |
| Kernel | 7.3.3-200.fc44.x86_64 |
| Desktop | GNOME Shell 50.6 on Wayland |
| CPU | AMD Ryzen 7 7800X3D (8 cores / 16 threads) |
| Memory | 62 GiB |
| `/home` | LUKS mapper, Btrfs subvolume, approximately 1.9 TiB |
| KVM | `/dev/kvm` present |
| Hostname | `ARC26` |

## Shell

| Item | Observed value |
|---|---|
| Login shell | `/usr/bin/zsh` |
| Zsh version | 5.9 |
| Oh My Zsh | `6010fb6260f359e71d99ba25f05f9215809b3ed2` |
| Powerlevel10k | `d05a1b00f9a61f9578bf9dc19b8451942dde8734` |
| history-substring-search | `a0bdb0d47dbaba31dba2db7af8c48a5d9c74049a` |
| Autosuggestions | Fedora `zsh-autosuggestions` 0.7.1 |
| Syntax highlighting | Fedora `zsh-syntax-highlighting` 0.8.0 |
| Factoring | Node.js was managed by `fnm` from `~/.local/share/fnm`; mise was not installed |

The existing `.zshrc` used the `git`, `fzf`, `extract`, and
`history-substring-search` Oh My Zsh plugins. It loaded autosuggestions and
syntax highlighting from `/usr/share`, defined the existing `eza`, `n`/`ninja`,
`c`, `please`, `tb`, `make`, and `ninja` aliases, and sourced `.p10k.zsh`
last. It also contained hard-coded `/home/aartan` paths for local
`opencode` and Stripe CLI binaries.

## Terminal and appearance

| Item | Observed value |
|---|---|
| Terminal | Alacritty 0.17.0 |
| Alacritty config | `~/.config/alacritty/alacritty.toml`, 47 lines |
| Font | JetBrainsMono Nerd Font |
| Font size | 16.0 |
| Font installation | 96 TTF files in `~/.local/share/fonts/JetBrainsMono` |
| Color scheme | Dark `#0C0C0C` background, `#CCCCCC` foreground |
| btop | 1.4.7; `~/.config/btop/btop.conf`, 286 lines |
| Prompt | Powerlevel10k with existing `.p10k.zsh`, 1713 lines |

All terminal appearance settings were copied unchanged. The font package is
pinned to Nerd Fonts v3.5.1 and verified by SHA-256.

## Editors and Git

| Item | Observed value |
|---|---|
| VS Code | 1.146.0 RPM |
| VS Code settings | `~/.config/Code/User/settings.json` |
| VS Code extensions | `dbaeumer.vscode-eslint`, `esbenp.prettier-vscode` |
| Neovim | Not installed, but `EDITOR` and `VISUAL` were already set to `nvim` |
| Git | 2.56.0 with Git LFS filters and a configured user identity |

The VS Code settings file contains preview behavior, format-on-save, and
autosave. It was copied exactly. The repository installs Neovim to satisfy the
existing `EDITOR=nvim` setting but deliberately does not invent a Neovim
configuration.

## Packages and services observed

| Area | Observation |
|---|---|
| PostgreSQL | `postgresql-server` 18.6 installed and enabled/active; data cluster already initialized |
| Valkey | Not installed; `valkey.service` did not exist |
| Containers | Rootless Podman 5.8.9 and skopeo 1.22.3; buildah, podman-compose, and Docker absent |
| Virtualization | QEMU/KVM 10.2.2, libvirt 12.0.0, virt-manager 5.1.0; modular libvirt sockets active |
| Existing VM | `win11`, shut off; its disk image is not migrated |
| Browsers | Firefox 160.0, Brave 1.99.56, Google Chrome Flatpak |
| Flatpak | Flathub system remote present; 14 applications installed |
| keyd | v2.6.0 built from source, binary at `/usr/local/bin/keyd`, service enabled/active |
| keyd config | `/etc/keyd/default.conf` remaps brightness keys and `scale` to Insert |
| Gaming | Steam, Wine, gamemode, gamescope, MangoHud, vkBasalt, goverlay, and LACT were installed |

The keyd binary is not an RPM package. Its version string identifies commit
`f564288`, matching the pin in `config/pins.conf`. The configuration is
root-owned; it is copied rather than symlinked so keyd does not read a
user-writable file.

## Repositories and third-party software

| Source | Observation |
|---|---|
| Flathub | System remote present |
| Microsoft VS Code RPM repository | VS Code RPM installed; repository file was not assumed to be reproducible and is explicitly managed |
| Brave RPM repository | Brave RPM installed; repository file is explicitly managed |
| Flatpak applications | Obsidian, KeePassXC, Proton Mail/Pass/VPN, GitHub Desktop, Flatseal, Extension Manager, DBeaver, pgAdmin, Podman Desktop, Chrome, LACT, qBittorrent |

The repository declares only the curated productivity, development, and
database GUI applications. It does not manage browser profiles or Flatpak app
data.

## Sensitive data found outside the repository

The discovery scan intentionally inspected file names and credential-like
patterns, not credential values. Sensitive material exists on the workstation
and is deliberately excluded from this repository and from its backups:

- `~/.zsh_history`: 16 lines matched credential-like patterns in the
  read-only scan, including database connection URLs and API tokens.
- `~/.config/opencode/service.json`: sensitive service configuration.
- `~/.config/masar/better-auth-secret.bin`: authentication secret material.
- VS Code `Trust Tokens`, `Trust Tokens-journal`, and
  `Partitions/vscode-browser/Trust Tokens`: session trust material.
- `~/.ssh` and `~/.gnupg`.
- Browser profiles, sessions, cookies, and extension storage.
- Shell history files and editor global storage.

No secret value was copied into the repository, logs, or documentation. See
[security.md](security.md) for handling and rotation guidance.

## Migration decisions derived from discovery

| Decision | Reason |
|---|---|
| Replace `fnm` with mise | One runtime manager for Node.js, Python, pnpm, and future tools |
| Keep the existing Zsh/P10k/Alacritty/btop appearance | The workstation configuration is the source of truth |
| Add Neovim package only | `EDITOR=nvim` already existed; no configuration was invented |
| Use rootless Podman, not Docker | Rootless Podman was already present and working |
| Use modular libvirt sockets | Fedora 44 uses `virtqemud`, `virtnetworkd`, and related services, not legacy `libvirtd` |
| Add Valkey | The service was not installed, but the workstation's intended database scope includes it |
| Manage keyd from source | The existing installation is a source build at the pinned commit |
| Exclude gaming software | The target repository is a development/professional workstation setup |
| Exclude the `win11` VM | VM images and libvirt XML are machine state, not reproducible configuration |

## State at the end of discovery

- Original home-directory files remained untouched.
- The repository contains copies of the managed dotfiles plus the keyd
  configuration.
- The only changed shell file is the repository copy
  `dotfiles/home/.zshrc`; the live `~/.zshrc` was not edited.
- Git was not initialized in the repository during discovery.
- Full package and system installation still requires an interactive
  `./install.sh` run with sudo.
