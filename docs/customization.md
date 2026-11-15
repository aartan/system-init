# Customization

## Packages

Packages are declared per module in `modules/<name>/packages.fedora`:

```text
# manager  package  optional
dnf        git
dnf        some-package  optional
flatpak    md.obsidian.Obsidian  optional
```

Rows are whitespace-delimited. Use one package per line. Mark desktop
applications and non-essential tools as `optional`; a failed optional install is
reported as a warning instead of stopping the run.

Preview changes with:

```bash
./install.sh --module <name> --dry-run
```

## Modules

Create `modules/<name>/module.conf`:

```ini
MODULE_DESCRIPTION="Short description"
MODULE_DEPENDS="core"
```

Add `modules/<name>/packages.fedora` for packages. Add
`modules/<name>/post-install.sh` when configuration or verification is needed:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash

module_post_install() {
  # configure or verify here
}
```

Add the module to `config/modules.conf` in installation order. Then choose
whether it belongs to the core profile:

- Add it to `CORE_MODULES` in `config/profiles.conf` for the core profile.
- Leave it out to make it available only in the extended profile.

The extended profile installs every module in `config/modules.conf`, including
their optional applications. Module dependencies are resolved automatically.

## Dotfiles

`dotfiles/manifest.tsv` maps repository files to paths under `$HOME`:

```text
module  strategy  platforms  source  target
```

- `strategy`: `symlink` or `copy`
- `platforms`: `all`, `fedora`, `macos`, or a comma-separated list
- `source`: repository-relative path
- `target`: path relative to `$HOME`

Only destinations listed in `DOTFILES_ALLOWED_TARGETS` in `lib/dotfiles.sh`
are accepted. This prevents a modified manifest from touching SSH keys, GPG
material, user binaries, autostart entries, or systemd user units. Backup
restore uses the same allowlist, plus the installer-created
`~/.gitconfig.local`; it also requires each payload to live at exactly
`files/<destination>` and refuses directory payloads. To manage a new file:

1. Copy it into `dotfiles/home/` at the same relative path.
2. Add its `$HOME`-relative destination to `DOTFILES_ALLOWED_TARGETS` in
   `lib/dotfiles.sh`.
3. Add one tab-delimited row to `dotfiles/manifest.tsv`.
4. Preview with `./install.sh --module <module> --dry-run`.

Existing targets are backed up before replacement. A second install creates no
new backups when nothing changed. New snapshots are built from process-owned
entries, signed as an exact canonical `manifest.v2` when `BACKUP_SIGNING_KEY`
is configured, and marked complete only after structure, signature, and payload
hashes verify. Empty or incomplete snapshots are not selected by `--latest`.
Legacy v1 snapshots remain restorable only with the explicit `--allow-legacy`
flag; unsigned v2 snapshots require `--allow-unsigned`. Expired and revoked
signing keys are rejected.

## Git identity

An interactive install prompts for a Git name and email and stores them in
`~/.gitconfig.local`. The managed `.gitconfig` includes that file, so the
values stay outside the repository. The identity file is written through a
protected temporary regular file and atomically replaced; a symlinked
`.gitconfig.local` is rejected rather than followed.

For non-interactive installs:

```bash
DEV_SETUP_GIT_NAME="Your Name" \
DEV_SETUP_GIT_EMAIL="you@example.com" \
./install.sh --profile core
```

## Pins and runtimes

- `config/pins.conf`: archive URLs, SHA-256 checksums, Git commits, VS Code
  extension versions, and third-party repository key fingerprints.
- `config/runtimes.conf`: mise-managed Node.js, Python, and pnpm versions.

Fedora repositories for VS Code and Brave use local key copies under
`platforms/fedora/keys/`. The installer verifies each bundle's SHA-256 and
requires every primary fingerprint in the bundle to be present in the explicit
`MICROSOFT_GPG_FINGERPRINTS` or `BRAVE_GPG_FINGERPRINTS` allow-list before
installing it; repository definitions never fetch replacement keys from the
network. Repository definitions are hash-checked even when an installed copy is
already byte-identical.

Update an explicit version, then rerun `./install.sh` or
`./scripts/update.sh`. Do not use `latest` for pinned runtimes.

## Optional system integration

Database and virtualization services are disabled by default. To enable them,
set `ENABLE_DATABASE_SERVICES=1` or `ENABLE_VIRTUALIZATION_SERVICES=1` in
`config/settings.conf` before running the installer.

The extended profile always installs optional desktop applications, including
productivity apps, browsers, and optional development tools. The core profile
always skips them. Direct `--module` runs have no profile, so they install
optional applications only when `INSTALL_OPTIONAL_APPS=1`.
