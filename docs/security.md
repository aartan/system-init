# Security

## Security model

`system-init` is a single-user workstation bootstrap, not a multi-user
provisioning system. It assumes the invoking user is trusted and that sudo is
the correct boundary for system changes. The controls below reduce accidental
data loss and accidental secret publication; they do not turn an untrusted
machine into a trusted one.

## Repository hygiene

- No credentials, API keys, SSH keys, GPG keys, shell history, browser
  profiles, or application secrets are stored in this repository.
- `.gitignore` excludes common sensitive paths as a convenience. It is **not**
  a security boundary: files already tracked remain tracked, and unusual secret
  file names are not detected by name alone.
- `./scripts/doctor.sh` scans repository content for common credential
  patterns, including private-key blocks, database URLs with embedded
  passwords, GitHub tokens, AWS access keys, OpenAI-style keys, and Slack
  tokens.
- The scan is intentionally conservative and pattern-based. A clean scan is not
  proof that no secret exists. Review `git diff` and `git status` before every
  commit.
- `validation_secret_paths` rejects known forbidden paths during installer
  preflight. It also searches for common private-key filenames and extensions.

## Sensitive material found during discovery

The following material exists on the workstation and is deliberately outside
the repository and outside the normal backup scope:

- Shell history containing credential-like lines, including database
  connection URLs and API tokens.
- `~/.config/opencode/service.json`.
- `~/.config/masar/better-auth-secret.bin` and related authentication data.
- VS Code Trust Tokens, trust-token journals, and browser-partition trust data.
- SSH and GPG key material.
- Browser profiles, cookies, sessions, extension storage, and sync data.
- VS Code global storage, workspace storage, and chat model data.

No values were copied into the repository or documentation. They are not
needed to reproduce the workstation.

### Required manual action

Rotate any credential that may have been exposed in shell history or another
unmanaged file. In particular, review database URLs, Supabase keys, cloud
access keys, and API tokens. `system-init` cannot determine whether a credential
is still valid and intentionally does not read, print, or migrate it.

If you want to reduce future exposure, review and edit your history file
manually after making a private backup. Do not automate deletion of history
you may still need, and do not paste history contents into an issue or chat.
This repository does not modify shell history.

## Installer safeguards

| Control                  | Implementation                                                                                           |
| ------------------------ | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Strict shell behavior    | `set -Eeuo pipefail` in executable entry points                                                          |
| No remote code execution | No `curl                                                                                                 | bash`; archives are downloaded to a temporary directory and verified before use |
| Download integrity       | SHA-256 verification for mise, Nerd Fonts, and keyd                                                      |
| Pinned source            | Git checkouts for Oh My Zsh, Powerlevel10k, history-substring-search, and keyd                           |
| No dynamic evaluation    | Package and manifest input are parsed as data; package names are passed as argv                          |
| Path containment         | Dotfile sources must be repository-relative and cannot contain `..`; targets must be relative to `$HOME` |
| No silent overwrite      | Existing targets are backed up before replacement; broken symlinks are backed up too                     |
| Least privilege          | `sudo` is requested only for DNF, Flatpak system operations, systemd, keyd, and the login shell          |
| Non-interactive refusal  | The installer refuses to proceed if sudo needs a password and stdin is not a terminal                    |
| Genuine dry-run          | Mutating primitives skip execution; no state, logs, or backup directories are created                    |
| Restrictive state        | State, logs, backups, and snapshot metadata are created with mode `700`/`600`                            |
| Root-owned system config | `/etc/keyd/default.conf` is copied with root ownership, never symlinked to a user file                   |
| No secret migration      | History, SSH, GPG, app secrets, and browser data are excluded                                            |

## Trust boundaries

### sudo

The installer can run arbitrary privileged package and service operations by
design. A user who can run `sudo` can already change the system. The scripts
avoid broad `sudo` shell strings and pass arguments as argv, but they do not
sandbox the commands they invoke.

### Third-party repositories and applications

The repository adds:

- Microsoft VS Code RPM repository
- Brave RPM repository
- Flathub as a Flatpak remote

These are third-party trust relationships. Repository files enable GPG
checking, and Flathub uses its own signing infrastructure, but the repository
does not independently audit those vendors or every package version.

The existing workstation also has third-party software and gaming packages.
They are outside this project's management and are not audited here.

### Downloaded archives

mise, Nerd Fonts, and keyd are downloaded over HTTPS and verified against
pinned SHA-256 values. The initial trust anchor is the repository content
itself: if an attacker can change `config/pins.conf`, they can change the
expected checksum. Protect the repository and review changes to pins.

Oh My Zsh, Powerlevel10k, and history-substring-search are cloned over HTTPS
and checked out at pinned commits. The commits are not independently signed or
verified by this project. A future hardening step could verify signed tags or
Git commit signatures.

### keyd

keyd runs as root, reads `/etc/keyd/default.conf`, and remaps keyboard input.
The configuration is small and reviewed, but it is privileged input-path
software. The installer builds it from the pinned source archive, verifies the
resulting version, copies the configuration as root, enables the service, and
restarts it after changes. It does not remove the keyd binary or disable the
service unless `uninstall.sh --system` is explicitly requested.

### macOS phase 2

`platforms/macos/platform.conf` sets `PLATFORM_SUPPORTED=0`, so the installer
refuses to continue on macOS. The macOS scaffold is not a claim of security
review or functional support. A future Homebrew bootstrap must avoid
`curl | bash`, pin or verify what it can, and be tested on real hardware.

## Backups

Backups contain copies of managed dotfiles and, only with `--system`, the keyd
configuration. They do not include `~/.ssh`, `~/.gnupg`, shell history, browser
profiles, application secrets, VM images, or project data.

Even so, dotfiles can contain personal information. Treat snapshots as private:

- They live under `${XDG_STATE_HOME:-~/.local/state}/system-init/backups/`.
- Directories are created with mode `700`, metadata and manifests with `600`.
- They are not encrypted at rest. Full-disk encryption is assumed.
- `prune_backups` retains only the configured number of snapshots
  (`DOTFILES_BACKUP_KEEP`, default 10; `0` disables pruning).
- `restore.sh` refuses paths outside `$HOME` unless `--system` is explicit.

## Logging

Logs are written under the state directory with mode `600`. Commands are
rendered with `printf %q` for display. The installer does not log file contents,
environment dumps, secrets, or credential values. Debug mode increases command
visibility but does not read secret files.

## Known limitations

- Pattern-based secret scanning can miss unusual credentials.
- The repository cannot rotate or revoke exposed credentials.
- Package installation trusts Fedora, Flathub, Microsoft, and Brave metadata.
- No mandatory access control, firewall, SELinux, or kernel hardening is added.
- The installer does not verify GPG signatures on downloaded release archives,
  only pinned SHA-256 checksums.
- Builds of keyd use the local compiler and headers; the build environment is
  trusted.
- The `win11` VM and its images are unmanaged machine state.

## If a secret is committed

1. Do not rewrite history until you have a backup and a clear plan.
2. Revoke or rotate the credential immediately. Assume any pushed value is
   compromised.
3. Remove the value from the working tree and add the path to `.gitignore`.
4. If the commit was pushed, coordinate history rewriting with everyone who
   has a clone.
5. Run `./scripts/doctor.sh` and inspect `git status` before committing again.

The fastest safe response is always to rotate the secret, not to rely on
deleting a file from the latest commit.
