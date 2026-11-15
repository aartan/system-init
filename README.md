# system-init

Opinionated Fedora workstation provisioning for software development.

`system-init` installs a development environment, optional desktop productivity
applications, and a managed set of dotfiles. Existing files are backed up before
replacement, and every action can be previewed with `--dry-run`.

**Supported platform:** Fedora Linux 43 or newer

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

# Install (prompts for a profile and Git identity)
./install.sh

# Verify the result
./scripts/doctor.sh
```

## Profiles

An interactive install prompts for one of two profiles:

| Profile | Contents |
|---|---|
| `core` | CLI tools, shell, fonts, editors, containers, databases, runtimes, required packages only |
| `extended` | Everything in core, plus browsers, productivity apps, virtualization, and all optional desktop applications |

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
| `./scripts/doctor.sh` | Run read-only diagnostics (mise inspection is offline/no-install) |
| `./scripts/backup.sh` | Back up managed dotfiles |
| `./scripts/restore.sh` | Restore a backup |
| `./uninstall.sh` | Remove managed links |

## Customization

- Add or remove packages in `modules/<name>/packages.fedora`.
- Add modules to `config/modules.conf` and choose profile membership in
  `config/profiles.conf`.
- Change pinned versions in `config/pins.conf` and `config/runtimes.conf`.
- Manage user files through `dotfiles/manifest.tsv`; destinations must also be
  added to `DOTFILES_ALLOWED_TARGETS` in `lib/dotfiles.sh`.
- Database and virtualization services are opt-in through
  `config/settings.conf`. The extended profile installs optional desktop apps
  automatically; direct `--module` runs use `INSTALL_OPTIONAL_APPS`.

See [customization](docs/customization.md) and
[troubleshooting](docs/troubleshooting.md).

## After installation

The installer offers to restart at the end of an interactive run. If you decline,
log out and back in instead:

```bash
exec zsh
./scripts/doctor.sh
```

Log out and back in if the login shell, fonts, or session environment do not
update in existing terminals.

The installer prompts for a Git name and email and writes them to
`~/.gitconfig.local`, which the managed `.gitconfig` includes. For
non-interactive installs, set `DEV_SETUP_GIT_NAME` and `DEV_SETUP_GIT_EMAIL`.
If you skip the prompt, configure them later:

```bash
git config --file ~/.gitconfig.local user.name "Your Name"
git config --file ~/.gitconfig.local user.email "you@example.com"
```

## Safety

- Run `system-init` as your normal user; all entrypoints refuse to run as root.
  `sudo` is invoked only for individual privileged commands.
- `--dry-run` prints every mutating command without running it.
- Existing dotfiles are backed up to
  `${XDG_STATE_HOME:-$HOME/.local/state}/system-init/backups/`.
- Pinned font/mise archives, their inner binaries where applicable, Fedora
  repository definitions, and repository key bundles are verified against
  pinned SHA-256 checksums. Repository key bundles are also checked against an
  explicit primary-fingerprint allow-list when `gpg` is available. DNF package
  versions, Flatpak application contents, VS Code extension contents,
  mise-managed runtime tarballs, and Git checkouts are not all hash-pinned by
  this repository; see the residual risks below.
- Dotfile destinations are restricted to an explicit allowlist and must stay
  under `$HOME`; `.ssh`, `.gnupg`, `.local/bin`, autostart entries, and systemd
  user units are never managed. `.gitconfig.local` is an approved restore-only
  side file.
- Restore applies the same allowlist as installation. A v2 manifest entry must
  map to its exact `files/<destination>` payload. Directory payloads and
  directory replacement are refused; empty snapshots are refused; every entry
  is validated and hashed before mutation, and a failed apply rolls back
  entries already applied.
- New snapshots use a canonical `manifest.v2` with per-file sizes, SHA-256
  hashes, normalized modes (0600 for files), and a detached OpenPGP signature.
  Manifest entries are built from process-owned state, written to private
  storage, and signed as exact bytes. The manifest is not published until
  finalization, so an interrupted or partial backup has no authenticated
  manifest. A signed snapshot is never silently downgraded to unsigned.
- `complete=0` is written when a snapshot is created. A snapshot is only
  marked complete after its structure, signature (when configured), and every
  payload hash verify. Empty or incomplete snapshots are not selected by
  `--latest` and are not counted for pruning.
- Restore verifies and parses a private copy of the manifest, re-verifies the
  installed destination before commit, uses no-target-directory moves, refuses
  a source that changed after it was backed up, and holds an exclusive
  operation lock. This closes normal pathname-replacement races; see the
  same-user limitation below.
- Legacy v1 snapshots are unverified and require `--allow-legacy`. Unsigned v2
  snapshots require `--allow-unsigned`. An invalid v2 snapshot never falls back
  to v1. Expired or revoked signing keys, expired signatures, missing public
  keys, and ambiguous multiple signatures are rejected.
- Restore writes a journal under
  `${XDG_STATE_HOME:-$HOME/.local/state}/system-init/journal/`. Journal
  recovery accepts only canonical journals in that directory, owned by the
  current user, with restrictive permissions. Every destination is
  re-canonicalized, required to remain under `$HOME`, and checked against the
  managed-destination allowlist; traversal, symlinked journals/staging
  directories, and directory or symlink `stage/old` payloads are rejected.
- Interrupted restore states, including `PREPARED`, `MOVING_ASIDE`,
  `MOVED_ASIDE`, `NEW_INSTALLED`, `APPLIED`, `APPLY_FAILED`,
  `ROLLBACK_FAILED`, `COMMIT_PENDING`, and `COMMIT_FAILED`, are never reported
  as a clean recovery while any destination remains unresolved. Recovery is
  idempotent across retries after a partial recovery; staging data is preserved
  on failure, and the journal is removed only after every entry is resolved.
- Backup, restore, install, update, uninstall, and journal recovery take an
  exclusive state lock. This prevents normal entrypoints from interleaving.
  The fallback lock records process start time and boot ID, so a recycled PID
  is not mistaken for a live owner.
- Recursive deletion of state, snapshots, staging directories, and purge
  targets requires `findmnt` and refuses mount points or child mounts; it fails
  closed if mount inspection is unavailable. Archive extraction rejects
  absolute and `..` member paths before extraction.
- Restored files are mode 0600. ACLs and extended attributes from a snapshot
  are not applied. A symlinked `$HOME` or `XDG_STATE_HOME` is supported with
  canonical state paths, while symlinked descendants of the home directory are
  rejected.
- Git inspections run with system/global configuration disabled, hostile Git
  environment variables cleared, repository-local executable configuration
  rejected, and group/other-writable checkout metadata rejected.
- Flatpak system remotes are checked by name and an explicit allow-list of
  official Flathub endpoints (including both the legacy descriptor and the
  current `dl.flathub.org` repository URL), and only system-scope Flatpak
  applications count as installed.
- mise-managed runtimes are installed only on x86-64. On aarch64 the mise
  module fails closed with an explicit message rather than installing an
  x86-64 binary. Doctor uses installed-runtime inspection (`mise ls --installed`
  with offline mode) and does not run `mise exec`, so it does not auto-install
  missing runtimes.
- No credentials, private keys, shell history, or browser profiles are stored
  in the repository. `platforms/fedora/keys/*.asc` contains public repository
  signing keys only.

### Backup signing and recovery

Backups are signed with the OpenPGP key identified by the full 40-hex primary
fingerprint in `BACKUP_SIGNING_KEY` (environment or local settings). The
private key must live outside the repository and outside `BACKUP_DIR`; the
default is the user's GnuPG keyring:

```bash
gpg --quick-generate-key "system-init backups <you@example.invalid>" ed25519 sign 2y
gpg --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}'
export BACKUP_SIGNING_KEY=<full-fingerprint>
```

Unattended signing requires a key without a passphrase or a gpg-agent cache;
otherwise pre-seed the agent before running `install.sh` or
`scripts/backup.sh`. The public key must be present in the verifying user's
GnuPG keyring.

Verification requires the primary fingerprint in the GnuPG `VALIDSIG` status
to match `BACKUP_SIGNING_KEY`. Signatures made by an authorised signing subkey
are accepted when the reported primary key matches. A signature by any other
key in the keyring is rejected. The verifier also rejects `REVKEYSIG`,
`KEYREVOKED`, `EXPKEYSIG`, `KEYEXPIRED`, `EXPSIG`, `NO_PUBKEY`, `ERRSIG`,
`BADSIG`, and failed/ambiguous status with anything other than one `GOODSIG`
and one `VALIDSIG`. In particular, a key that has been revoked or has expired
no longer authorises new or old snapshots; stop using it and rotate.

Key rotation is manual. Create and verify a new snapshot with the new key
before removing the old key from the keyring. Old snapshots signed by a
different fingerprint, a revoked key, or an expired key are rejected. There is
no automatic multi-key grace period.

Migration: set a signing key and create a new signed snapshot. Do not
auto-reseal imported v1 snapshots; `--allow-legacy` is an explicit acceptance
of unverified content. Legacy/unsigned restores are still subject to the
destination allowlist, empty-snapshot rejection, locking, and rollback.

Snapshot metadata (`metadata.conf`: created/reason/host/user) is displayed but
is not cryptographically covered by `manifest.v2`; it has no authority over
which files are restored. The `complete` flag is a selection hint stored in
that metadata. Snapshot contents are authenticated by the signed manifest and
payload hashes, not by metadata. There is no trusted freshness sequence or
anti-replay index: an older valid signed snapshot can be copied back into the
backup directory and selected by `--latest`. If replay matters, keep backups
on append-only/immutable storage or maintain a trusted external index.

Restore writes a journal in the state journal directory. To recover, inspect
the listed destination and staging directory and run:

```bash
./scripts/restore.sh --recover-journal PATH
```

The journal path must be a direct, canonical, current-user-owned file under
`${XDG_STATE_HOME:-$HOME/.local/state}/system-init/journal/` with no group or
other permissions. Recovery restores a regular `stage/old` only when the
destination is missing; existing destinations are left untouched for manual
review. Directory or symlink `stage/old` payloads are rejected. On success the
staging directory and journal are removed; on any unresolved or failed state
they are retained and the command exits nonzero.

### Same-user threat model

All controls run as the invoking user. A same-user attacker who can modify the
repository scripts, the state directory, or the home directory can change the
verifier or the files it protects. Signed backups are intended to detect
tampering with backup content when the verifier and its configuration are
trusted, not to defend against a fully compromised account. A hardware token
protects the private key, but it cannot prevent a same-user process from
modifying the verification script if that script lives in a user-writable
checkout. Run restore from a trusted/read-only copy or a separate account if
that threat is in scope.

## License

MIT. See [LICENSE](LICENSE).
