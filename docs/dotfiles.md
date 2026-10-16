# Dotfiles

## Managed files

| File                                 | Strategy | Source                                           |
| ------------------------------------ | -------- | ------------------------------------------------ |
| `~/.gitconfig`                       | symlink  | `dotfiles/home/.gitconfig`                       |
| `~/.zshrc`                           | symlink  | `dotfiles/home/.zshrc`                           |
| `~/.p10k.zsh`                        | symlink  | `dotfiles/home/.p10k.zsh`                        |
| `~/.config/alacritty/alacritty.toml` | symlink  | `dotfiles/home/.config/alacritty/alacritty.toml` |
| `~/.config/btop/btop.conf`           | symlink  | `dotfiles/home/.config/btop/btop.conf`           |
| `~/.config/Code/User/settings.json`  | symlink  | `dotfiles/home/.config/Code/User/settings.json`  |

`/etc/keyd/default.conf` is managed separately by the `system` module. It is
copied, not symlinked, because keyd runs as root and must not read a
user-writable configuration.

## `.zshrc` changes from the original

The migration copy is otherwise byte-for-byte equivalent to the original:

1. Removed the fnm PATH block and `eval "$(fnm env --shell zsh)"`.
2. Added `~/.local/bin` to `PATH`.
3. Added guarded mise activation:

   ```zsh
   if command -v mise >/dev/null 2>&1; then
     eval "$(mise activate zsh)"
   fi
   ```

4. Replaced hard-coded `/home/aartan/...` paths with `$HOME` checks.

All aliases, plugins, history settings, syntax highlighting, autosuggestions,
and Powerlevel10k loading are preserved. No Neovim configuration is invented.

## Manifest format

`dotfiles/manifest.tsv` is tab-delimited. Comments start with `#`.

```text
module<TAB>strategy<TAB>platforms<TAB>source<TAB>target
```

Example:

```text
terminal	symlink	all	dotfiles/home/.zshrc	.zshrc
```

Rules:

- `module` must match a directory under `modules/`.
- `strategy` is `symlink` or `copy`.
- `platforms` is `all`, `fedora`, `macos`, or a comma-separated list.
- `source` is relative to the repository root and cannot contain `..`.
- `target` is relative to `$HOME` and cannot contain `..`.
- Duplicate targets are rejected, except that a platform-specific row replaces
  an `all` row for the same target on that platform.
- Only rows whose module is selected and whose platform matches are installed.

## Linking behavior

- A target that is already the correct symlink is left unchanged.
- A regular file, directory, unmanaged symlink, or broken symlink is backed up,
  removed, and replaced.
- A conflict backup is written to the current snapshot under
  `${XDG_STATE_HOME:-~/.local/state}/system-init/backups/<timestamp>/files/`.
- After linking, the target is verified with `readlink -f`.
- For `copy`, the result is verified with `cmp` or `diff -rq`.
- Repeated installations create no new backups when everything is current.

## Adding or changing a dotfile

1. Copy the file into `dotfiles/home/` at the mirrored relative path.
2. Add one tab-delimited row to `dotfiles/manifest.tsv`.
3. Run `./install.sh --dry-run --module <module>`.
4. Run `./scripts/backup.sh` before applying on an existing machine.
5. Apply with `./install.sh --module <module>` or a full install.

To override a file only on one platform, keep the `all` row and add a row with
the same target and `fedora` or `macos` in the platforms column.

## What is intentionally not managed

- Shell history files
- SSH and GPG keys
- Browser profiles and sessions
- VS Code global storage, workspace storage, chat model data, trust tokens
- Obsidian vaults
- GNOME extension code and desktop settings
- Gaming data and configuration
- VM images, ISOs, and libvirt XML
- Project repositories

## Backup and restore

```bash
./scripts/backup.sh
./scripts/restore.sh --list
./scripts/restore.sh --latest
```

A pre-install snapshot is also created automatically for existing dotfile
targets that would be replaced. If all managed targets are already current, no
new snapshot is created. Restoring a snapshot replaces current targets with the
backed-up versions. System paths are skipped unless `--system` is supplied.
