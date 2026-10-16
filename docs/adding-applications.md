# Adding applications

## DNF package

1. Add a row to the appropriate `modules/<name>/packages.fedora`:

   ```text
   dnf package-name
   ```

2. Mark it optional only when the workstation remains useful without it:

   ```text
   dnf package-name optional
   ```

3. Validate:

   ```bash
   ./install.sh --module <name> --dry-run
   ```

Package rows are parsed as three fields. Do not use shell syntax, command
substitution, quotes, or multiple packages on one line.

## Flatpak application

1. Confirm the application ID:

   ```bash
   flatpak search "Application Name"
   flatpak remote-info flathub <application.id>
   ```

2. Add the row to the module:

   ```text
   flatpak <application.id> optional
   ```

3. Ensure the `flathub` remote is available. The installer adds it when a
   selected module declares at least one Flatpak application.

## New module

1. Create `modules/<name>/module.conf`:

   ```ini
   MODULE_DESCRIPTION="Short description"
   MODULE_DEPENDS="core"
   ```

2. Add `packages.fedora` if the module declares packages.
3. Add `post-install.sh` if configuration is required:

   ```bash
   #!/usr/bin/env bash
   # shellcheck shell=bash

   module_post_install() {
     # verify and configure here
   }
   ```

4. Add the module name to `config/modules.conf` in the desired order.
5. Add any dotfile rows whose `module` column matches the new module.
6. Run:

   ```bash
   ./install.sh --list
   ./install.sh --module <name> --dry-run
   ```

The module is selected automatically in a full installation because it is
listed in `modules.conf`.

## Post-install hook rules

- The hook must define `module_post_install`.
- Use `run` or `run_sudo` for mutating commands so dry-run remains genuine.
- Return non-zero on genuine failure.
- Use `record_failure` for hard failures and `record_warning` for optional
  components.
- Verify the result after changing it.
- Never execute downloaded code directly; download, verify a pinned SHA-256,
  then run a local file.
- Never write secrets into the repository or logs.

## System services

If the module needs a systemd unit, add a helper to
`platforms/fedora/system.sh` or use an existing one such as
`fedora_service_enable_now`.

Guidelines:

- Use modular libvirt sockets, not legacy `libvirtd.service`.
- Do not enable `podman.socket` by default.
- Do not modify PostgreSQL authentication or create database users.
- Do not change firewall, SELinux, or kernel settings unless the module is
  explicitly about that change.

## Dotfiles

To add a configuration file:

1. Copy it to the mirrored path under `dotfiles/home/`.
2. Add a manifest row:

   ```text
   editors	symlink	all	dotfiles/home/.config/example/config.toml	.config/example/config.toml
   ```

3. Test with a temporary home if possible:

   ```bash
   mkdir -p /tmp/system-init-home
   DEV_SETUP_TARGET_HOME=/tmp/system-init-home ./install.sh --module editors --dry-run
   ```

4. Run `./scripts/backup.sh` on a real machine before applying.

## Excluding an application from the default install

Mark it `optional` and set `INSTALL_OPTIONAL_APPS=0` in
`config/settings.conf`, or remove the row. A full install still installs every
required package in every selected module; there are no profiles.

## What not to add

- Global npm packages for React, Vite, ESLint, or TypeScript. Keep them
  project-local unless the user explicitly asks for a global tool.
- Docker. Use rootless Podman.
- Browser profile data, VM images, ISO files, or game libraries.
- Credentials, API keys, SSH keys, or personal access tokens.
- `curl | bash` installers or unpinned downloads.
