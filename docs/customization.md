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

The extended profile installs every module in `config/modules.conf`. Module
dependencies are resolved automatically.

## Dotfiles

`dotfiles/manifest.tsv` maps repository files to paths under `$HOME`:

```text
module  strategy  platforms  source  target
```

- `strategy`: `symlink` or `copy`
- `platforms`: `all`, `fedora`, `macos`, or a comma-separated list
- `source`: repository-relative path
- `target`: path relative to `$HOME`

To add a file:

1. Copy it into `dotfiles/home/` at the same relative path.
2. Add one tab-delimited row to `dotfiles/manifest.tsv`.
3. Preview with `./install.sh --module <module> --dry-run`.

Existing targets are backed up before replacement. A second install creates no
new backups when nothing changed.

## Pins and runtimes

- `config/pins.conf`: archive URLs, SHA-256 checksums, and Git commits.
- `config/runtimes.conf`: mise-managed Node.js, Python, and pnpm versions.

Update an explicit version, then rerun `./install.sh` or
`./scripts/update.sh`. Do not use `latest` for pinned runtimes.
