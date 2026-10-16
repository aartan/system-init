# Architecture

## Goals

- Reproduce one Fedora workstation from an explicit, reviewable repository.
- Keep packages, system services, and dotfiles independent and testable.
- Make every write visible in `--dry-run`.
- Never overwrite an existing configuration without a backup.
- Keep macOS support behind a platform interface without pretending it works.

## Repository layout

```text
system-init/
├── install.sh                   entry point
├── uninstall.sh                 conservative removal
├── config/
│   ├── settings.conf            feature switches, backup retention
│   ├── pins.conf                versions, commits, SHA-256 checksums
│   ├── runtimes.conf            mise runtime pins
│   └── modules.conf             canonical module order
├── lib/
│   ├── logging.sh               colorized and file logging
│   ├── common.sh                paths, run/run_sudo, downloads, backups list
│   ├── platform.sh              OS detection and adapter loading
│   ├── packages.sh              declarative package parser
│   ├── modules.sh               selection, dependencies, execution
│   ├── dotfiles.sh              manifest parsing, linking, verification
│   ├── backups.sh               snapshots and restore
│   └── validation.sh            preflight and secret-path checks
├── installers/
│   ├── dnf.sh                   Fedora RPM adapter
│   ├── flatpak.sh               Flatpak adapter
│   ├── brew.sh                  macOS Homebrew library (not enabled)
│   ├── mise.sh                  pinned mise and runtimes
│   ├── fonts.sh                 pinned Nerd Fonts archive
│   ├── keyd.sh                  pinned source build and service
│   ├── zsh.sh                   pinned shell framework checkouts
│   └── code.sh                  VS Code extensions
├── platforms/
│   ├── fedora/
│   │   ├── platform.conf        PLATFORM_SUPPORTED=1
│   │   ├── platform.sh          validation and lifecycle hooks
│   │   ├── packages.sh          DNF repo setup
│   │   ├── system.sh            service helpers
│   │   ├── repos/               VS Code and Brave repo files
│   │   └── system/keyd.conf     root-owned keyd config
│   └── macos/                   guarded scaffold, not enabled
├── modules/
│   └── <name>/
│       ├── module.conf          description and dependencies
│       ├── packages.<platform>  package declarations
│       └── post-install.sh      optional hook
├── dotfiles/
│   ├── home/                    exact user configuration copies
│   ├── platform/                reserved for platform overrides
│   └── manifest.tsv             explicit source -> target mapping
├── scripts/
│   ├── update.sh
│   ├── backup.sh
│   ├── restore.sh
│   ├── doctor.sh
│   └── list.sh
└── docs/
```

## Install flow

1. Parse arguments, detect the platform, and load the platform adapter.
2. Resolve requested modules and their dependencies in `modules.conf` order.
3. Initialize state and logging, then run preflight validation: Bash version,
   non-root execution, repository layout, package manifest syntax, dotfile
   manifest syntax, secret paths.
4. Request sudo only when needed. A non-interactive run without cached sudo
   fails before changing anything.
5. Write the in-progress marker.
6. Back up existing dotfile targets that are not already managed correctly, so
   only real conflicts produce a pre-install snapshot.
7. Ensure required Fedora repositories.
8. For each selected module:
   - install declared DNF and Flatpak packages;
   - run the module's optional `post-install.sh`.
9. Install selected dotfiles with conflict backups.
10. Run platform post-install checks and prune old snapshots.
11. Print a summary. Failures accumulate and produce a non-zero exit code.

The in-progress marker is removed only on success. Rerunning after an
interruption is safe and idempotent.

## Module contract

`module.conf` uses simple `KEY=value` lines:

```ini
MODULE_DESCRIPTION="Zsh, Powerlevel10k, shell plugins, Alacritty, btop"
MODULE_DEPENDS="core,fonts"
```

`packages.fedora` is a three-column, whitespace-delimited file:

```text
# manager  package  optional
dnf        git
flatpak    md.obsidian.Obsidian  optional
```

Guarantees:

- Managers are limited to `dnf`, `flatpak`, `brew`, and `cask`.
- Required failure is recorded; optional failure is a warning and the run
  continues.
- Package names are passed as argv elements, never through `eval`.
- Duplicate declarations are rejected by validation.
- Packages already installed are skipped, which keeps repeated runs fast.

`post-install.sh` is sourced and must define `module_post_install()`. The
function is unset after each module so hooks cannot leak into later modules.
Hooks are responsible for verification as well as configuration.

## Dotfile contract

`dotfiles/manifest.tsv` is tab-delimited:

```text
module  strategy  platforms  source  target
```

- `strategy`: `symlink` or `copy`
- `platforms`: `all`, `fedora`, `macos`, or a comma-separated combination
- `source`: repository-relative path
- `target`: path relative to `$HOME`

The parser validates paths, rejects `..`, rejects sources that resolve outside
the repository, detects duplicate targets, and supports a platform-specific row
overriding an `all` row for the same target.

See [dotfiles.md](dotfiles.md).

## Dry-run semantics

`DRY_RUN=1` is checked by every mutating primitive:

- `run` and `run_sudo` print the argv-quoted command instead of executing.
- Downloads, archive extraction, package installs, service changes, keyd builds,
  dotfile links, backups, and state directory creation are skipped.
- Read-only probes (for example `rpm -q`, `flatpak info`, `systemctl is-active`)
  still run so the output reflects the real current state.
- No log file, backup snapshot, or in-progress marker is created.

## Backups

```text
${XDG_STATE_HOME:-$HOME/.local/state}/system-init/
├── backups/<timestamp>/
│   ├── files/<absolute path without leading slash>
│   ├── manifest.tsv
│   └── metadata.conf
├── logs/
└── install.in-progress
```

`manifest.tsv` records the original path, stored payload, and kind. Symlinks are
copied with `cp -a --no-dereference`, so a broken link can be restored exactly.
Restores skip paths outside `$HOME` unless `--system` is explicit.

## Platform abstraction

`lib/platform.sh` detects Fedora and macOS and sources
`platforms/<platform>/platform.conf`. Fedora declares
`PLATFORM_SUPPORTED=1`; macOS declares `0`, so the installer refuses early.
Adapters may provide:

- `platform_specific_validate`
- `platform_specific_preflight`
- `platform_specific_init`
- `platform_specific_post_install`

Fedora additionally loads `packages.sh` and `system.sh` for repository and
service helpers. A future macOS adapter can supply the same functions and
`packages.macos` files without changing the installer engine.

## Error handling

- `set -Eeuo pipefail` and an `ERR` trap report the failing line.
- `record_failure` and `record_warning` accumulate results for the final summary.
- Module failures do not silently disappear; the final exit code is non-zero.
- `doctor.sh` is read-only and exits non-zero if any check fails.
- `uninstall.sh` removes only links that still point at this repository.
