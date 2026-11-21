#!/usr/bin/env bash
# Portability regression tests for shared code.
# Run with: ./tests/portability.sh
set -uo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    exec /opt/homebrew/bin/bash "$0" "$@"
  fi
  printf 'skip - Bash 5 is required.\n'
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEST_TMP="$(mktemp -d "$TMP_BASE/system-init-portability-tests.XXXXXXXX")"
FAILURES=0
PASSES=0

pass() { PASSES=$((PASSES + 1)); printf 'ok - %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'not ok - %s\n' "$*"; }
skip() { printf 'skip - %s\n' "$*"; }

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
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

export DEV_SETUP_TARGET_HOME="$TEST_TMP/home"
export HOME="$DEV_SETUP_TARGET_HOME"
mkdir -p "$HOME"

# shellcheck source=../lib/logging.sh
source "$ROOT/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/platform.sh
source "$ROOT/lib/platform.sh"

platform_detect
platform_load || {
  printf 'not ok - platform adapter failed to load\n'
  exit 1
}

# ---------------------------------------------------------------------------
# Helpers behave consistently on GNU and BSD userlands
# ---------------------------------------------------------------------------
expect_eq "lexical normalisation" "$TEST_TMP/a/c" "$(path_lexical "$TEST_TMP/a/b/../c")"
mkdir -p "$TEST_TMP/a"
ln -s "$TEST_TMP/a" "$TEST_TMP/link"
expect_eq "canonicalisation follows symlinks" "$TEST_TMP/a" \
  "$(path_canonicalize "$TEST_TMP/link")"
expect_eq "missing path resolution" "$TEST_TMP/a/missing" \
  "$(path_resolve "$TEST_TMP/a/missing")"

printf 'payload\n' >"$TEST_TMP/hash"
if compat_is_macos; then
  expected_sha="$(shasum -a 256 "$TEST_TMP/hash" | awk '{ print $1 }')"
else
  expected_sha="$(sha256sum "$TEST_TMP/hash" | awk '{ print $1 }')"
fi
expect_eq "file hashing" "$expected_sha" "$(file_sha256 "$TEST_TMP/hash")"

printf 'mode\n' >"$TEST_TMP/mode"
chmod_mode 600 "$TEST_TMP/mode"
expect_eq "mode helper" "600" "$(file_mode "$TEST_TMP/mode")"
expect_eq "size helper" "5" "$(file_size "$TEST_TMP/mode")"
expect_eq "UTC timestamp parsing" "1795262400" "$(timestamp_epoch '2026-11-21 12:00:00')"

printf 'new\n' >"$TEST_TMP/new"
printf 'old\n' >"$TEST_TMP/old"
mv_replace "$TEST_TMP/new" "$TEST_TMP/old"
expect_eq "atomic replacement" "new" "$(cat "$TEST_TMP/old")"

mkdir -p "$TEST_TMP/dir"
ln -s "$TEST_TMP/dir" "$TEST_TMP/dir-link"
printf 'file\n' >"$TEST_TMP/source"
mv_replace "$TEST_TMP/source" "$TEST_TMP/dir-link"
if [[ -f "$TEST_TMP/dir-link" && ! -L "$TEST_TMP/dir-link" ]]; then
  pass "replacement does not follow a symlink destination"
else
  fail "replacement followed a symlink destination"
fi

printf 'installed\n' >"$TEST_TMP/install-source"
install_file 640 "$TEST_TMP/install-source" "$TEST_TMP/install/child"
expect_eq "install helper" "640" "$(file_mode "$TEST_TMP/install/child")"

mkdir -p "$TEST_TMP/delete/sub"
printf 'x\n' >"$TEST_TMP/delete/sub/file"
if safe_rm_rf "$TEST_TMP/delete"; then
  pass "safe recursive deletion"
else
  fail "safe recursive deletion failed"
fi

# ---------------------------------------------------------------------------
# Shared code must not call GNU-only tools directly
# ---------------------------------------------------------------------------
SHARED_FILES=(
  lib/bootstrap.sh
  lib/common.sh
  lib/backups.sh
  lib/dotfiles.sh
  lib/git_identity.sh
  lib/modules.sh
  lib/packages.sh
  lib/platform.sh
  lib/report.sh
  installers/brew.sh
  installers/fonts.sh
  installers/mise.sh
  installers/zsh.sh
  platforms/macos/platform.sh
  platforms/macos/system.sh
)

for pattern in \
  'stat -c' \
  'realpath -e' \
  'realpath -m' \
  'mv -fT' \
  'getent ' \
  'nproc' \
  'findmnt' \
  'chmod [0-7]+ --' \
  'install -D'; do
  hits="$(grep -HnE "$pattern" "${SHARED_FILES[@]}" 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  if [[ -n "$hits" ]]; then
    fail "shared code still uses '$pattern': $hits"
  else
    pass "shared code avoids '$pattern'"
  fi
done

SCANNED="$ROOT/lib/common.sh $ROOT/lib/backups.sh $ROOT/lib/dotfiles.sh \
  $ROOT/lib/git_identity.sh $ROOT/lib/modules.sh $ROOT/lib/packages.sh \
  $ROOT/lib/platform.sh $ROOT/lib/bootstrap.sh $ROOT/lib/report.sh"
# shellcheck disable=SC2086
if grep -Hn 'sha256sum' $SCANNED 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' | grep -q .; then
  fail "shared code calls sha256sum instead of file_sha256/string_sha256"
else
  pass "shared code hashes through compat helpers"
fi

# ---------------------------------------------------------------------------
# macOS manifests
# ---------------------------------------------------------------------------
MACOS_MANIFESTS=("$ROOT"/modules/*/packages.macos)
if grep -hE '^[[:space:]]*(dnf|flatpak)[[:space:]]' "${MACOS_MANIFESTS[@]}" >/dev/null 2>&1; then
  fail "macOS manifests contain DNF or Flatpak rows"
else
  pass "macOS manifests use brew and cask only"
fi
if grep -hiE 'firefox|proton' "${MACOS_MANIFESTS[@]}" | grep -v '^[[:space:]]*#' | grep -q .; then
  fail "macOS manifests contain excluded applications"
else
  pass "Firefox and Proton apps are excluded on macOS"
fi

missing=0
for formula in bash git git-lfs curl wget jq zip unzip xz gzip gnupg \
  openssl@3 make cmake ninja pkgconf shellcheck podman podman-compose skopeo \
  valkey neovim tmux fzf ripgrep fd bat eza btop nmap zoxide lazygit \
  zsh-autosuggestions zsh-syntax-highlighting; do
  if ! grep -hFxq "brew $formula" "${MACOS_MANIFESTS[@]}"; then
    fail "missing macOS formula: $formula"
    missing=1
  fi
done
(( missing == 0 )) && pass "required macOS formulae are declared"

if grep -Eq '^P10K_COMMIT=[0-9a-f]{40}$' "$ROOT/config/pins.conf" \
  && grep -q 'powerlevel10k.git' "$ROOT/installers/zsh.sh"; then
  pass "Powerlevel10k is pinned and installed on macOS"
else
  fail "Powerlevel10k pin/install is missing"
fi

missing=0
for app in podman-desktop dbeaver-community postgres-app brave-browser \
  google-chrome visual-studio-code obsidian keepassxc github utm raycast; do
  if ! grep -hFxq "cask $app" "${MACOS_MANIFESTS[@]}"; then
    fail "missing macOS cask: $app"
    missing=1
  fi
done
(( missing == 0 )) && pass "required macOS casks are declared"

if grep -Eq '^ALACRITTY_DMG_SHA256=[0-9a-f]{64}$' "$ROOT/config/pins.conf" \
  && grep -Eq '^ALACRITTY_DMG_URL=' "$ROOT/config/pins.conf" \
  && [[ -f "$ROOT/installers/alacritty.sh" ]] \
  && ! grep -q '^cask alacritty$' "$ROOT/modules/terminal/packages.macos"; then
  pass "Alacritty uses the pinned official DMG instead of the disabled cask"
else
  fail "Alacritty direct-install pins are incomplete"
fi

printf '\nPortability test summary: %d passed, %d failed\n' "$PASSES" "$FAILURES"
if (( FAILURES > 0 )); then
  exit 1
fi
