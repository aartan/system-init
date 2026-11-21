#!/usr/bin/env bash
# macOS arm64 portability and behaviour tests.
# Run with: ./tests/macos.sh
# shellcheck disable=SC2034 # configuration globals are read by sourced code
set -uo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    exec /opt/homebrew/bin/bash "$0" "$@"
  fi
  printf 'skip - Bash 5 is required; install it with: brew install bash\n'
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'skip - tests/macos.sh targets macOS.\n'
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# macOS TMPDIR is under /var, which is itself a symlink. Canonicalize the base
# so path safety checks see the real /private/var path.
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEST_TMP="$(mktemp -d "$TMP_BASE/system-init-macos-tests.XXXXXXXX")"
FAILURES=0
PASSES=0
SKIPS=0

pass() { PASSES=$((PASSES + 1)); printf 'ok - %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'not ok - %s\n' "$*"; }
skip() { SKIPS=$((SKIPS + 1)); printf 'skip - %s\n' "$*"; }

check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$description"
  else
    fail "$description"
  fi
}

expect_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$description"
  else
    fail "$description (expected '$expected', got '$actual')"
  fi
}

cleanup() {
  state_lock_release 2>/dev/null || true
  chmod -R u+rwX "$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

export DEV_SETUP_TARGET_HOME="$TEST_TMP/home"
export HOME="$DEV_SETUP_TARGET_HOME"
mkdir -p "$HOME"
PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# shellcheck source=../lib/logging.sh
source "$ROOT/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/platform.sh
source "$ROOT/lib/platform.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT/lib/backups.sh"
# shellcheck source=../lib/dotfiles.sh
source "$ROOT/lib/dotfiles.sh"
# shellcheck source=../lib/packages.sh
source "$ROOT/lib/packages.sh"
# shellcheck source=../lib/modules.sh
source "$ROOT/lib/modules.sh"
# shellcheck source=../lib/validation.sh
source "$ROOT/lib/validation.sh"
# shellcheck source=../lib/git_identity.sh
source "$ROOT/lib/git_identity.sh"
# shellcheck source=../installers/brew.sh
source "$ROOT/installers/brew.sh"
# shellcheck source=../installers/alacritty.sh
source "$ROOT/installers/alacritty.sh"
# shellcheck source=../installers/fonts.sh
source "$ROOT/installers/fonts.sh"
# shellcheck source=../installers/mise.sh
source "$ROOT/installers/mise.sh"
# shellcheck source=../installers/zsh.sh
source "$ROOT/installers/zsh.sh"

platform_detect
platform_load || {
  printf 'not ok - macOS platform adapter failed to load\n'
  exit 1
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------
expect_eq "macOS platform is detected" "macos" "$PLATFORM"
expect_eq "Apple Silicon is normalized to aarch64" "aarch64" "$PLATFORM_ARCH"
check "macOS platform validation passes" platform_validate

if [[ -x "$BREW_BIN" ]]; then
  check "Homebrew preflight passes" platform_preflight
else
  skip "Homebrew is not installed at $BREW_PREFIX"
fi

# ---------------------------------------------------------------------------
# Portable filesystem helpers
# ---------------------------------------------------------------------------
expect_eq "lexical path normalization" "$TEST_TMP/a/c" \
  "$(path_lexical "$TEST_TMP/a/b/../c")"
mkdir -p "$TEST_TMP/a"
ln -s "$TEST_TMP/a" "$TEST_TMP/a-link"
expect_eq "canonical path follows symlinks" "$TEST_TMP/a" \
  "$(path_canonicalize "$TEST_TMP/a-link")"
expect_eq "missing paths resolve lexically" "$TEST_TMP/a/missing" \
  "$(path_resolve "$TEST_TMP/a/missing")"

printf 'payload\n' >"$TEST_TMP/hash-file"
expect_eq "SHA-256 matches shasum" "$(shasum -a 256 "$TEST_TMP/hash-file" | awk '{ print $1 }')" \
  "$(file_sha256 "$TEST_TMP/hash-file")"
expect_eq "string SHA-256 matches shasum" "$(printf 'value' | shasum -a 256 | awk '{ print $1 }')" \
  "$(string_sha256 value)"

printf 'mode\n' >"$TEST_TMP/mode-file"
chmod_mode 600 "$TEST_TMP/mode-file"
expect_eq "chmod_mode applies a private mode" "600" "$(file_mode "$TEST_TMP/mode-file")"
expect_eq "file_size reports bytes" "5" "$(file_size "$TEST_TMP/mode-file")"

expect_eq "timestamp_epoch parses UTC" "1795262400" \
  "$(timestamp_epoch '2026-11-21 12:00:00')"
expect_eq "timestamp_compact formats UTC" "20261121T120000Z" \
  "$(timestamp_compact 1795262400)"

printf 'new\n' >"$TEST_TMP/new"
printf 'old\n' >"$TEST_TMP/old"
mv_replace "$TEST_TMP/new" "$TEST_TMP/old"
expect_eq "mv_replace replaces a file atomically" "new" "$(cat "$TEST_TMP/old")"

mkdir -p "$TEST_TMP/mv-dir"
ln -s "$TEST_TMP/mv-dir" "$TEST_TMP/mv-link"
printf 'regular\n' >"$TEST_TMP/mv-source"
mv_replace "$TEST_TMP/mv-source" "$TEST_TMP/mv-link"
if [[ -f "$TEST_TMP/mv-link" && ! -L "$TEST_TMP/mv-link" ]] \
  && [[ -z "$(ls -A "$TEST_TMP/mv-dir")" ]]; then
  pass "mv_replace replaces a symlink instead of following it"
else
  fail "mv_replace followed a symlink destination"
fi

printf 'installed\n' >"$TEST_TMP/install-source"
install_file 640 "$TEST_TMP/install-source" "$TEST_TMP/installed/child"
expect_eq "install_file creates parents and mode" "640" "$(file_mode "$TEST_TMP/installed/child")"

mkdir -p "$TEST_TMP/delete-me/sub"
printf 'x\n' >"$TEST_TMP/delete-me/sub/file"
safe_rm_rf "$TEST_TMP/delete-me"
check "safe_rm_rf removes a normal tree" test ! -e "$TEST_TMP/delete-me"

# ---------------------------------------------------------------------------
# Dotfiles and package manifests
# ---------------------------------------------------------------------------
SELECTED_MODULES=(terminal editors)
entries="$(dotfiles_entries)"
if grep -Fq $'Library/Application Support/Code/User/settings.json' <<<"$entries"; then
  pass "macOS VS Code settings target is selected"
else
  fail "macOS VS Code settings target is missing"
fi
if grep -Fq '.p10k.zsh' <<<"$entries"; then
  pass "Powerlevel10k config is selected on macOS"
else
  fail "Powerlevel10k config is missing on macOS"
fi
if dotfiles_restore_target_is_safe "Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf" \
  && ! dotfiles_restore_target_is_safe "Library/Fonts/Unrelated.ttf"; then
  pass "only Nerd Font payloads are restorable from the Fonts directory"
else
  fail "Font restore allowlist is too broad or too narrow"
fi
if grep -q 'no macOS prompt is shown' "$ROOT/install.sh"; then
  fail "macOS still skips the Fedora Git identity prompt"
else
  pass "macOS uses the same Git identity prompt as Fedora"
fi
identity_file="$HOME/.gitconfig.local"
git_identity_write_atomic "$identity_file" "Mac Test" "mac@example.invalid"
if [[ "$(git_identity_config --file "$identity_file" --get user.name)" == "Mac Test" ]] \
  && [[ "$(git_identity_config --file "$identity_file" --get user.email)" == "mac@example.invalid" ]] \
  && [[ "$(file_mode "$identity_file")" == "600" ]]; then
  pass "Git identity file is written atomically with private permissions"
else
  fail "Git identity file verification failed"
fi

SELECTED_MODULES=(core browsers containers databases development editors fonts productivity terminal virtualization)
check "macOS package manifests validate" validation_package_manifests
if grep -RIl '^dnf\|^flatpak' "$ROOT"/modules/*/packages.macos >/dev/null 2>&1; then
  fail "macOS manifests contain Fedora package managers"
else
  pass "macOS manifests use only brew and cask"
fi
if grep -RIl 'firefox' "$ROOT"/modules/*/packages.macos >/dev/null 2>&1; then
  fail "macOS manifest still installs Firefox"
else
  pass "Firefox is not installed on macOS"
fi


CAPTURE="$TEST_TMP/package-calls"
: >"$CAPTURE"
brew_install() { printf 'brew %s\n' "$*" >>"$CAPTURE"; }
brew_cask_install() { printf 'cask %s\n' "$*" >>"$CAPTURE"; }
SELECTED_MODULES=(core)
PROFILE=extended
packages_install_module core
if grep -Eq '^brew .*bash' "$CAPTURE"; then
  pass "required Homebrew formulae are installed"
else
  fail "required Homebrew formulae were not installed"
fi

: >"$CAPTURE"
SELECTED_MODULES=(browsers)
packages_install_module browsers
if grep -Eq '^cask .*brave-browser' "$CAPTURE" \
  && grep -Eq '^cask .*google-chrome' "$CAPTURE"; then
  pass "macOS browser casks are installed"
else
  fail "macOS browser casks are missing"
fi
if grep -Fq 'firefox' "$CAPTURE"; then
  fail "Firefox was selected on macOS"
else
  pass "Firefox is excluded from the browser module"
fi

# ---------------------------------------------------------------------------
# Podman machine handling
# ---------------------------------------------------------------------------
PODMAN_LIST="$TEST_TMP/podman-list"
PODMAN_CALLS="$TEST_TMP/podman-calls"
: >"$PODMAN_CALLS"
podman() {
  printf '%s\n' "$*" >>"$PODMAN_CALLS"
  case "$*" in
    "machine list --format {{.Name}} {{.Running}}") cat "$PODMAN_LIST" ;;
    "info") return 0 ;;
    *) return 0 ;;
  esac
}
PODMAN_MACHINE_AUTO=1
PODMAN_MACHINE_NAME=default
DRY_RUN=0

: >"$PODMAN_LIST"
: >"$PODMAN_CALLS"
macos_podman_machine_prepare
if grep -Fxq 'machine init default' "$PODMAN_CALLS" \
  && grep -Fxq 'machine start default' "$PODMAN_CALLS"; then
  pass "Podman machine is initialized and started when absent"
else
  fail "Podman machine initialization/start was not attempted"
fi

printf 'default false\n' >"$PODMAN_LIST"
: >"$PODMAN_CALLS"
macos_podman_machine_prepare
if grep -Fxq 'machine start default' "$PODMAN_CALLS" \
  && ! grep -Fxq 'machine init default' "$PODMAN_CALLS"; then
  pass "an existing stopped Podman machine is started"
else
  fail "existing stopped Podman machine was not started correctly"
fi

printf 'default* true\n' >"$PODMAN_LIST"
: >"$PODMAN_CALLS"
macos_podman_machine_prepare
if ! grep -Fxq 'machine start default' "$PODMAN_CALLS" \
  && ! grep -Fxq 'machine init default' "$PODMAN_CALLS"; then
  pass "a running Podman machine is left alone (default marker)"
else
  fail "a running Podman machine was restarted"
fi

PODMAN_MACHINE_AUTO=0
: >"$PODMAN_CALLS"
macos_podman_machine_prepare
if [[ ! -s "$PODMAN_CALLS" ]]; then
  pass "automatic Podman machine setup can be disabled"
else
  fail "Podman commands ran while automatic setup was disabled"
fi
PODMAN_MACHINE_AUTO=1

# ---------------------------------------------------------------------------
# Backup and restore round-trip
# ---------------------------------------------------------------------------
STATE_DIR="$TEST_TMP/state/system-init"
LOG_DIR="$STATE_DIR/logs"
BACKUP_DIR="$STATE_DIR/backups"
JOURNAL_DIR="$STATE_DIR/journal"
LOG_FILE=""
init_state_dirs
managed="$HOME/.zshrc"
printf 'original\n' >"$managed"
backup_init "test" || fail "backup_init failed"
backup_path "$managed" "dotfile" "test" || fail "backup_path failed"
backup_finalize || fail "backup_finalize failed"
snapshot="$BACKUP_RUN_DIR"
printf 'modified\n' >"$managed"
RESTORE_ALLOW_UNSIGNED=1
if backup_restore_snapshot "$snapshot"; then
  expect_eq "backup/restore round-trip preserves content" "original" "$(cat "$managed")"
else
  fail "backup_restore_snapshot failed"
fi
state_lock_release

# ---------------------------------------------------------------------------
# Shell configuration
# ---------------------------------------------------------------------------
check "managed .zshrc parses" zsh -n "$ROOT/dotfiles/home/.zshrc"
check "managed .p10k.zsh parses" zsh -n "$ROOT/dotfiles/home/.p10k.zsh"
zshrc="$ROOT/dotfiles/home/.zshrc"
if grep -q 'ZSH_THEME="powerlevel10k/powerlevel10k"' "$zshrc" \
  && grep -q 'source "$HOME/.p10k.zsh"' "$zshrc" \
  && ! grep -q 'starship init zsh' "$zshrc"; then
  pass "macOS uses Powerlevel10k with the shared p10k config"
else
  fail "macOS Powerlevel10k configuration is incomplete"
fi
if grep -Eq '^[[:space:]]*typeset -g POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION=' \
  "$ROOT/dotfiles/home/.p10k.zsh"; then
  fail "Powerlevel10k OS icon is overridden instead of using the native icon"
else
  pass "Powerlevel10k uses the native OS icon"
fi
if grep -Eq '^[[:space:]]*plugins=.*zsh-(autosuggestions|syntax-highlighting)' "$zshrc"; then
  fail "autosuggestions or syntax highlighting is listed as an Oh My Zsh plugin"
else
  pass "autosuggestions and syntax highlighting are not double-loaded"
fi
if grep -q 'Postgres.app/Contents/Versions/latest/bin' "$zshrc" \
  && grep -q 'openssl@3' "$zshrc"; then
  pass "keg-only OpenSSL and Postgres.app paths are present"
else
  fail "macOS tool paths are missing from .zshrc"
fi
expect_eq "Alacritty uses the system zsh" "/bin/zsh" \
  "$(awk -F'"' '/^program = / { print $2; exit }' "$ROOT/dotfiles/home/.config/alacritty/alacritty.toml")"
if [[ "$ALACRITTY_DMG_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  && [[ -f "$ROOT/installers/alacritty.sh" ]] \
  && ! grep -q '^cask alacritty$' "$ROOT/modules/terminal/packages.macos"; then
  pass "Alacritty uses the pinned official DMG"
else
  fail "Alacritty direct-install configuration is incomplete"
fi
DRY_RUN=1
if alacritty_install >/dev/null 2>&1; then
  pass "Alacritty install is available in dry-run mode"
else
  fail "Alacritty install failed in dry-run mode"
fi
DRY_RUN=0

# ---------------------------------------------------------------------------
# Dry-run installer
# ---------------------------------------------------------------------------
if [[ -x "$BREW_BIN" ]] && [[ -x /opt/homebrew/bin/bash ]]; then
  if "$ROOT/install.sh" --dry-run --profile core --yes >"$TEST_TMP/dry-run.log" 2>&1; then
    pass "install.sh dry-run completes for the core profile"
  else
    fail "install.sh dry-run failed (see $TEST_TMP/dry-run.log)"
    sed -n '1,80p' "$TEST_TMP/dry-run.log"
  fi
else
  skip "install.sh dry-run needs Homebrew and Homebrew Bash 5"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\nmacOS test summary: %d passed, %d failed, %d skipped\n' "$PASSES" "$FAILURES" "$SKIPS"
if (( FAILURES > 0 )); then
  exit 1
fi
