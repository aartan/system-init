# Inventory

This is the complete inventory of what `system-init` manages, what it
intentionally leaves alone, and what was observed on the source workstation.
Fedora is the only enabled platform.

## Package modules

### Required DNF packages

| Module                 | Packages                                                                                                                                                                                                                                                                                                                                       |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **core** (29)          | `git`, `git-lfs`, `curl`, `wget2-wget`, `jq`, `zip`, `unzip`, `tar`, `xz`, `gzip`, `ca-certificates`, `gnupg2`, `openssl`, `sudo`, `gcc`, `gcc-c++`, `make`, `cmake`, `ninja-build`, `pkgconf-pkg-config`, `openssl-devel`, `readline-devel`, `zlib-devel`, `sqlite-devel`, `libffi-devel`, `bzip2-devel`, `xz-devel`, `shellcheck`, `flatpak` |
| **terminal** (12)      | `zsh`, `tmux`, `fzf`, `ripgrep`, `fd-find`, `bat`, `eza`, `btop`, `nmap-ncat`, `alacritty`, `zsh-autosuggestions`, `zsh-syntax-highlighting`                                                                                                                                                                                                   |
| **development** (2)    | `java-25-openjdk-headless`, `python3-pip`                                                                                                                                                                                                                                                                                                      |
| **editors** (2)        | `neovim`, `code`                                                                                                                                                                                                                                                                                                                               |
| **containers** (7)     | `podman`, `podman-compose`, `buildah`, `skopeo`, `passt`, `slirp4netns`, `fuse-overlayfs`                                                                                                                                                                                                                                                      |
| **databases** (5)      | `postgresql`, `postgresql-server`, `postgresql-contrib`, `valkey`, `valkey-compat-redis`                                                                                                                                                                                                                                                       |
| **browsers** (2)       | `firefox`, `brave-browser`                                                                                                                                                                                                                                                                                                                     |
| **virtualization** (9) | `virt-manager`, `qemu-kvm`, `libvirt-client`, `libvirt-daemon-kvm`, `libvirt-daemon-config-network`, `libvirt-daemon-config-nwfilter`, `virt-install`, `edk2-ovmf`, `swtpm`                                                                                                                                                                    |

`system` and `fonts` have no DNF package declarations; they use pinned
downloads and source builds.

### Optional Flatpak applications

Optional apps are installed only when `INSTALL_OPTIONAL_APPS=1` in
`config/settings.conf` (the default). A failed optional install is recorded as
a warning, not a fatal error.

| Module           | Application IDs                                                                                                                                                                                                            |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **containers**   | `io.podman_desktop.PodmanDesktop`                                                                                                                                                                                          |
| **databases**    | `io.dbeaver.DBeaverCommunity`, `org.pgadmin.pgadmin4`                                                                                                                                                                      |
| **browsers**     | `com.google.Chrome`                                                                                                                                                                                                        |
| **productivity** | `md.obsidian.Obsidian`, `org.keepassxc.KeePassXC`, `me.proton.Mail`, `me.proton.Pass`, `com.protonvpn.www`, `io.github.shiftey.Desktop` (GitHub Desktop), `com.github.tchx84.Flatseal`, `com.mattjakeman.ExtensionManager` |

All Flatpak applications use the `flathub` system remote. The installer adds
the remote only when a selected module declares Flatpak applications.

## Pinned external components

All downloaded archives are verified before use. Git checkouts are pinned by
commit for the shell framework and keyd.

| Component                | Pin                                        | Verification                                                  |
| ------------------------ | ------------------------------------------ | ------------------------------------------------------------- |
| mise                     | `2026.11.8`                                | SHA-256 of `mise-v2026.11.8-linux-x64.tar.xz`                 |
| Nerd Fonts JetBrainsMono | `3.5.1`                                    | SHA-256 of archive and of `JetBrainsMonoNerdFont-Regular.ttf` |
| keyd                     | `2.6.0`, commit `f564288`                  | SHA-256 of source archive; version checked after build        |
| Oh My Zsh                | `6010fb6260f359e71d99ba25f05f9215809b3ed2` | Git commit                                                    |
| Powerlevel10k            | `d05a1b00f9a61f9578bf9dc19b8451942dde8734` | Git commit                                                    |
| history-substring-search | `a0bdb0d47dbaba31dba2db7af8c48a5d9c74049a` | Git commit                                                    |

The exact URLs and checksums are in `config/pins.conf`.

## mise-managed runtimes

| Runtime | Version   |
| ------- | --------- |
| Node.js | `26.13.0` |
| Python  | `3.14.10` |
| pnpm    | `12.18.0` |

The runtimes are declared in `config/runtimes.conf`. Java 25 is installed from
Fedora DNF and is not managed by mise.

## Managed dotfiles

All six user files use the `symlink` strategy. Their source copies were audited
against the live workstation; five are byte-for-byte identical, and `.zshrc`
has only the documented migration changes.

| Target                               | Source                                           | SHA-256                                                            |
| ------------------------------------ | ------------------------------------------------ | ------------------------------------------------------------------ |
| `~/.gitconfig`                       | `dotfiles/home/.gitconfig`                       | `a36d5a2e06f29a316c3f5e81e0a53e90db5164eed1fec3d86a74e023b7b68588` |
| `~/.zshrc`                           | `dotfiles/home/.zshrc`                           | `b1ff383d792ceedec3c35f22a282ee9b5a436452e6fa8034d3bb50e605d73f5e` |
| `~/.p10k.zsh`                        | `dotfiles/home/.p10k.zsh`                        | `5c051a85b690d38110c2990f9238a1b3b8431dd893664f9ef18fe7d83fc34973` |
| `~/.config/alacritty/alacritty.toml` | `dotfiles/home/.config/alacritty/alacritty.toml` | `adec5ac1c4b572056b4730109a58e8d552dd6c1cbf93021e00230f5f2f685e71` |
| `~/.config/btop/btop.conf`           | `dotfiles/home/.config/btop/btop.conf`           | `b766a1ed708b04a05ac8d841f33745f4ed3026bfd58a4efb41932b50ad4ba8f6` |
| `~/.config/Code/User/settings.json`  | `dotfiles/home/.config/Code/User/settings.json`  | `ccb4651a55189351d76097ba947edaa151495bedd977de4fa1edad8296e17418` |

The `.zshrc` differences from the source workstation are:

- `fnm` initialization removed
- `~/.local/bin` added to `PATH`
- guarded `mise activate zsh` added
- hard-coded `/home/aartan` paths replaced with `$HOME`

See [dotfiles.md](dotfiles.md) for the manifest format and conflict behavior.

## System configuration

| Item                     | Managed behavior                                                                                               |
| ------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `/etc/keyd/default.conf` | Copied from `platforms/fedora/system/keyd.conf`; root-owned; backed up before replacement                      |
| `keyd.service`           | Enabled and started; restarted after a configuration change                                                    |
| VS Code RPM repository   | Installed from `platforms/fedora/repos/vscode.repo`                                                            |
| Brave RPM repository     | Installed from `platforms/fedora/repos/brave-browser.repo`                                                     |
| Flathub                  | System remote ensured when Flatpak packages are selected                                                       |
| PostgreSQL               | Cluster initialized only if absent; `postgresql.service` enabled and started                                   |
| Valkey                   | `valkey.service` enabled and started                                                                           |
| libvirt                  | Modular sockets enabled: `virtqemud`, `virtnetworkd`, `virtstoraged`, `virtlogd`, `virtlockd`, `virtnwfilterd` |
| libvirt default network  | Started and set to autostart when it already exists                                                            |

The legacy `libvirtd.service` is intentionally not used. No PostgreSQL
authentication, `pg_hba.conf`, password, database, or role changes are made.
No firewall, SELinux, kernel, or bootloader settings are changed.

## Deliberately excluded

These items are not installed, modified, or removed by this repository.

### Gaming

Steam, Wine and its subpackages, Lutris, qBittorrent, LACT, MangoHud,
vkBasalt, goverlay, gamemode, gamescope, and winetricks. Existing gaming
packages, prefixes, and data remain untouched.

### Applications and integrations

- Docker (rootless Podman is used instead)
- PyCharm and other JetBrains IDEs
- Claude Code
- Global npm packages for React, Vite, ESLint, or TypeScript
- GNOME extension installation or `gsettings` automation
- Browser profiles, sessions, cookies, extensions, and sync data
- Obsidian vaults
- The existing `win11` VM, its disk images, ISOs, and libvirt XML
- Unmanaged Flatpak applications such as LACT and qBittorrent
- The local `opencode` and Stripe CLI binaries; `.zshrc` preserves their
  existing `PATH` entries but does not install or configure them
- Neovim configuration files (only the `neovim` package is installed)

### Sensitive material

- `~/.ssh` and `~/.gnupg`
- `~/.zsh_history` and `~/.bash_history`
- `~/.config/opencode/service.json`
- `~/.config/masar/`
- VS Code Trust Tokens, global storage, workspace storage, chat model data
- `~/.config/stripe/`
- Any API keys, database URLs with credentials, tokens, or certificates

## Source workstation versus repository

| Area                     | Source workstation     | Repository behavior                              |
| ------------------------ | ---------------------- | ------------------------------------------------ |
| Node.js                  | fnm-managed            | mise-managed Node.js `26.13.0`                   |
| Python                   | Fedora Python 3.14.10  | mise-managed Python `3.14.10`                    |
| pnpm                     | Absent                 | mise-managed pnpm `12.18.0`                      |
| Neovim                   | Absent                 | Package installed, no config                     |
| Valkey                   | Absent                 | Package installed and service enabled            |
| buildah / podman-compose | Absent                 | Installed                                        |
| keyd                     | Source build at v2.6.0 | Rebuilt from pinned source if version mismatches |
| Gaming                   | Installed              | Not managed, not removed                         |
| Docker                   | Absent                 | Not installed                                    |
| `win11` VM               | Present, shut off      | Not migrated                                     |
| Shell history secrets    | Present                | Excluded from repository and backups             |
