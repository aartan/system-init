#!/usr/bin/env bash
# Security regression tests for system-init.
#
# These tests source library code in isolation and use temporary directories.
# They never run installers, module hooks, package managers, or sudo against
# the host. Run with: ./tests/security.sh
set -uo pipefail

if (( EUID == 0 )); then
  printf 'system-init tests: refusing to run as root; fixtures must be user-owned.\n' >&2
  exit 1
fi

# This suite exercises Fedora/GNU-specific behaviour (findmnt, /proc, getent,
# systemd units, GNU coreutils). Run the macOS suite on Apple Silicon.
if [[ "$(uname -s)" == "Darwin" ]]; then
  printf 'skip - tests/security.sh targets Fedora; run ./tests/macos.sh on macOS.\n'
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ACTUAL_REPO="$ROOT"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/system-init-tests.XXXXXXXX")"
TEST_LOG="$TEST_TMP/test.log"
FAILURES=0
PASSES=0
SKIPS=0

cleanup() {
  chmod -R u+rwX -- "$TEST_TMP" 2>/dev/null || true
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

note() {
  printf '%s\n' "$*"
}

pass() {
  PASSES=$((PASSES + 1))
  printf 'ok - %s\n' "$*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'not ok - %s\n' "$*"
}

skip() {
  SKIPS=$((SKIPS + 1))
  printf 'skip - %s\n' "$*"
}

check() {
  local description="$1"
  shift
  if "$@" >>"$TEST_LOG" 2>&1; then
    pass "$description"
  else
    fail "$description"
  fi
}

# Assert an exact non-zero exit status. A test that fails because of an
# unrelated typo, missing command or unset variable must not count as proof
# that a security check works.
expect_failure() {
  local description="$1"
  shift
  local expected_rc="${EXPECT_FAILURE_RC:-1}"
  local output="" rc=0

  output="$("$@" 2>&1)" || rc=$?
  printf '### %s (rc=%s)\n%s\n' "$description" "$rc" "$output" >>"$TEST_LOG"

  if (( rc == 0 )); then
    fail "$description (expected failure, got success)"
    return
  fi
  if (( rc != expected_rc )); then
    fail "$description (expected rc $expected_rc, got $rc: ${output//$'\n'/ | })"
    return
  fi
  if grep -Eq 'unbound variable|syntax error' <<<"$output"; then
    fail "$description (shell error: ${output//$'\n'/ | })"
    return
  fi
  pass "$description"
}

# Assert failure with a specific diagnostic. Used for security checks whose
# reason matters (allowlist rejection, rollback, checksum mismatch, etc.).
expect_failure_message() {
  local description="$1"
  local pattern="$2"
  shift 2
  local expected_rc="${EXPECT_FAILURE_RC:-1}"
  local output="" rc=0

  output="$("$@" 2>&1)" || rc=$?
  printf '### %s (rc=%s)\n%s\n' "$description" "$rc" "$output" >>"$TEST_LOG"

  if (( rc == 0 )); then
    fail "$description (expected failure, got success)"
    return
  fi
  if (( rc != expected_rc )); then
    fail "$description (expected rc $expected_rc, got $rc: ${output//$'\n'/ | })"
    return
  fi
  if ! grep -Eq -- "$pattern" <<<"$output"; then
    fail "$description (missing '$pattern': ${output//$'\n'/ | })"
    return
  fi
  pass "$description"
}

expect_eq() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$description"
  else
    fail "$description (expected '$expected', got '$actual')"
  fi
}

expect_match() {
  local description="$1"
  local pattern="$2"
  local actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    pass "$description"
  else
    fail "$description (expected match for '$pattern', got '$actual')"
  fi
}

fixture() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>"$TEST_TMP/fixture.err"; then
    return 0
  fi
  fail "fixture: $description"
  return 1
}

reset_failures() {
  FAILED_ITEMS=()
  WARNED_ITEMS=()
}

# ---------------------------------------------------------------------------
# Load libraries under test.
# ---------------------------------------------------------------------------
# shellcheck source=../lib/logging.sh
source "$ROOT/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/git_identity.sh
source "$ROOT/lib/git_identity.sh"
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
# shellcheck source=../installers/dnf.sh
source "$ROOT/installers/dnf.sh"
# shellcheck source=../installers/flatpak.sh
source "$ROOT/installers/flatpak.sh"
# shellcheck source=../installers/mise.sh
source "$ROOT/installers/mise.sh"
# shellcheck source=../installers/code.sh
source "$ROOT/installers/code.sh"
# shellcheck source=../installers/zsh.sh
source "$ROOT/installers/zsh.sh"
# shellcheck source=../platforms/fedora/packages.sh
source "$ROOT/platforms/fedora/packages.sh"

PLATFORM=fedora
PLATFORM_NAME="Fedora Linux"
PLATFORM_ARCH="x86_64"
DRY_RUN=0
DEBUG=0
TARGET_HOME="$TEST_TMP/home"
mkdir -p "$TARGET_HOME"
TARGET_USER="$(id -un)"
STATE_DIR="$TARGET_HOME/.local/state/system-init"
LOG_DIR="$STATE_DIR/logs"
BACKUP_DIR="$STATE_DIR/backups"
JOURNAL_DIR="$STATE_DIR/journal"
mkdir -p "$BACKUP_DIR"
REPO_ROOT="$ACTUAL_REPO"
SELECTED_MODULES=()
FAILED_ITEMS=()
WARNED_ITEMS=()
CURRENT_MODULE="test"
BACKUP_RUN_DIR=""
BACKUP_WARNED_UNSIGNED=0
RESTORE_ALLOW_LEGACY=0
RESTORE_ALLOW_UNSIGNED=0

GPG_TESTS=0
if have_command gpg; then
  GNUPGHOME="$TEST_TMP/gnupg"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
  export GNUPGHOME
  if gpg --batch --passphrase '' --quick-generate-key \
    "system-init test <test@example.invalid>" ed25519 sign 0 >/dev/null 2>&1; then
    BACKUP_SIGNING_KEY="$(gpg --batch --with-colons --list-secret-keys 2>/dev/null \
      | awk -F: '$1 == "fpr" { print $10; exit }')"
    if backup_signing_key_valid "$BACKUP_SIGNING_KEY"; then
      GPG_TESTS=1
      export BACKUP_SIGNING_KEY
    fi
  fi
fi
if (( GPG_TESTS == 0 )); then
  BACKUP_SIGNING_KEY=""
  fail "gpg key generation unavailable; signed-backup security tests cannot run"
fi

# ---------------------------------------------------------------------------
# H2: root guards and PATH sanitisation
# ---------------------------------------------------------------------------
note "# H2 root guards and PATH"

ENTRYPOINTS=(
  install.sh
  uninstall.sh
  scripts/backup.sh
  scripts/doctor.sh
  scripts/list.sh
  scripts/restore.sh
  scripts/update.sh
)

for entrypoint in "${ENTRYPOINTS[@]}"; do
  guard_line="$(grep -n 'EUID == 0' "$ROOT/$entrypoint" | head -n 1 | cut -d: -f1)"
  source_line="$(grep -n '^source ' "$ROOT/$entrypoint" | head -n 1 | cut -d: -f1)"
  path_line="$(grep -n '^PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$ROOT/$entrypoint" | head -n 1 | cut -d: -f1)"

  if [[ -n "$guard_line" && -n "$source_line" && -n "$path_line" ]] \
    && (( guard_line < source_line && path_line < source_line )); then
    pass "$entrypoint checks root and sets PATH before sourcing"
  else
    fail "$entrypoint must guard root and set PATH before sourcing (guard=$guard_line path=$path_line source=$source_line)"
  fi
done

test_guard_line="$(grep -n 'EUID == 0' "$ROOT/tests/security.sh" | head -n 1 | cut -d: -f1)"
test_source_line="$(grep -n '^source ' "$ROOT/tests/security.sh" | head -n 1 | cut -d: -f1)"
if [[ -n "$test_guard_line" && -n "$test_source_line" ]] && (( test_guard_line < test_source_line )); then
  pass "tests/security.sh refuses root before sourcing repository code"
else
  fail "tests/security.sh must refuse root before sourcing repository code"
fi

if unshare -Ur true >/dev/null 2>&1; then
  marker="$TEST_TMP/root-guard-sourced"
  for entrypoint in "${ENTRYPOINTS[@]}"; do
    copy="$TEST_TMP/rootguard-${entrypoint//\//-}"
    mkdir -p "$copy/lib" "$copy/$(dirname -- "$entrypoint")"
    cp -- "$ROOT/$entrypoint" "$copy/$entrypoint"
    printf 'touch %q\n' "$marker" >"$copy/lib/logging.sh"
    chmod +x "$copy/$entrypoint"

    if unshare -Ur bash "$copy/$entrypoint" >"$TEST_TMP/rootguard.out" 2>&1; then
      fail "$entrypoint should refuse to run as root"
    elif grep -q 'refusing to run as root' "$TEST_TMP/rootguard.out"; then
      if [[ -e "$marker" ]]; then
        fail "$entrypoint sourced repository files before refusing root"
      else
        pass "$entrypoint refuses root before sourcing"
      fi
    else
      fail "$entrypoint did not report the root refusal"
    fi
    rm -f -- "$marker"
  done
else
  fail "user namespaces unavailable; runtime root-guard tests are mandatory"
fi

safe_path="$(PATH="$TEST_TMP/evil:/usr/bin" bash -c 'source "$1/lib/common.sh"; printf "%s" "$PATH"' _ "$ROOT" 2>>"$TEST_LOG")"
expect_eq "lib/common.sh resets PATH to trusted system directories" "/usr/sbin:/usr/bin:/sbin:/bin" "$safe_path"

# ---------------------------------------------------------------------------
# H1: backup snapshot validation and safe restore
# ---------------------------------------------------------------------------
note "# H1 backup snapshots and restore"

BACKUP_DIR="$TEST_TMP/snapshots"
mkdir -p "$BACKUP_DIR"
H1_HOME="$TEST_TMP/h1-home"
mkdir -p "$H1_HOME"
TARGET_HOME="$H1_HOME"
REPO_ROOT="$ACTUAL_REPO"

make_snapshot() {
  local name="$1"
  local snapshot="$BACKUP_DIR/$name"
  mkdir -p "$snapshot/files"
  : >"$snapshot/manifest.tsv"
  printf 'created=test\n' >"$snapshot/metadata.conf"
  printf '%s\n' "$snapshot"
}

make_outside_snapshot() {
  local snapshot="$1"
  mkdir -p "$snapshot/files"
  : >"$snapshot/manifest.tsv"
  printf 'created=test\n' >"$snapshot/metadata.conf"
  printf '%s\n' "$snapshot"
}

write_payload() {
  local snapshot="$1"
  local destination="$2"
  local content="$3"
  mkdir -p "$(dirname -- "$snapshot/files$destination")"
  printf '%s\n' "$content" >"$snapshot/files$destination"
}

set_manifest() {
  local snapshot="$1"
  local original="$2"
  local stored="$3"
  printf '%s\t%s\tfile\n' "$original" "$stored" >"$snapshot/manifest.tsv"
}

valid_snapshot="$(make_snapshot "20260101T000000Z")"
expect_eq "direct child snapshot resolves" "$(realpath -e -- "$valid_snapshot")" "$(backup_snapshot_path "$valid_snapshot")"

RESTORE_ALLOW_LEGACY=0
expect_failure_message "legacy v1 restore requires --allow-legacy" 'allow-legacy' \
  backup_restore_snapshot "$valid_snapshot"
RESTORE_ALLOW_LEGACY=1

outside_snapshot="$(make_outside_snapshot "$TEST_TMP/outside-snapshot")"
expect_failure "snapshot outside BACKUP_DIR is rejected" backup_snapshot_path "$outside_snapshot"

nested_snapshot_dir="$BACKUP_DIR/nested/20260101T000000Z"
make_outside_snapshot "$nested_snapshot_dir" >/dev/null
expect_failure "nested snapshot is rejected" backup_snapshot_path "$nested_snapshot_dir"

symlink_snapshot="$BACKUP_DIR/symlink-snapshot"
ln -s -- "$outside_snapshot" "$symlink_snapshot"
expect_failure "symlinked snapshot is rejected" backup_snapshot_path "$symlink_snapshot"

symlink_manifest="$(make_snapshot "symlink-manifest")"
rm -f -- "$symlink_manifest/manifest.tsv"
ln -s -- "$outside_snapshot/manifest.tsv" "$symlink_manifest/manifest.tsv"
expect_failure "symlinked snapshot manifest is rejected" backup_snapshot_path "$symlink_manifest"

symlink_files="$(make_snapshot "symlink-files")"
rm -rf -- "$symlink_files/files"
ln -s -- "$outside_snapshot/files" "$symlink_files/files"
expect_failure "symlinked snapshot payload directory is rejected" backup_snapshot_path "$symlink_files"

# Destination allowlist and payload binding.
manifest_snapshot="$(make_snapshot "20260101T000002Z")"
printf 'original\n' >"$H1_HOME/.zshrc"
write_payload "$manifest_snapshot" "$H1_HOME/.zshrc" "restored"

set_manifest "$manifest_snapshot" "$H1_HOME/../escaped" "$manifest_snapshot/files$H1_HOME/.zshrc"
expect_failure_message "restore rejects destination traversal" 'outside' \
  backup_restore_snapshot "$manifest_snapshot"
[[ ! -e "$TEST_TMP/escaped" ]] && pass "traversal destination was not created" || fail "traversal destination was created"

set_manifest "$manifest_snapshot" "$H1_HOME" "$manifest_snapshot/files$H1_HOME/.zshrc"
expect_failure_message "restore rejects replacing TARGET_HOME itself" 'outside' \
  backup_restore_snapshot "$manifest_snapshot"

mkdir -p "$manifest_snapshot/files$H1_HOME/.ssh"
printf 'attacker-key\n' >"$manifest_snapshot/files$H1_HOME/.ssh/authorized_keys"
set_manifest "$manifest_snapshot" "$H1_HOME/.ssh/authorized_keys" \
  "$manifest_snapshot/files$H1_HOME/.ssh/authorized_keys"
expect_failure_message "restore rejects .ssh/authorized_keys" 'unapproved destination' \
  backup_restore_snapshot "$manifest_snapshot"
[[ ! -e "$H1_HOME/.ssh/authorized_keys" ]] \
  && pass "unauthorized .ssh payload was not written" \
  || fail "unauthorized .ssh payload was written"

mkdir -p "$manifest_snapshot/files$H1_HOME/.config/autostart"
printf '[Desktop Entry]\n' >"$manifest_snapshot/files$H1_HOME/.config/autostart/evil.desktop"
set_manifest "$manifest_snapshot" "$H1_HOME/.config/autostart/evil.desktop" \
  "$manifest_snapshot/files$H1_HOME/.config/autostart/evil.desktop"
expect_failure_message "restore rejects autostart entries" 'unapproved destination' \
  backup_restore_snapshot "$manifest_snapshot"

# Exact payload mapping: an allowlisted destination with a different payload
# path must not be accepted.
set_manifest "$manifest_snapshot" "$H1_HOME/.zshrc" "$manifest_snapshot/files/arbitrary"
printf 'arbitrary\n' >"$manifest_snapshot/files/arbitrary"
expect_failure_message "restore rejects a payload that does not match its destination" \
  'does not match' backup_restore_snapshot "$manifest_snapshot"

# Directory destinations and directory payloads.
mkdir -p "$H1_HOME/dir-destination"
set_manifest "$manifest_snapshot" "$H1_HOME/.zshrc" "$manifest_snapshot/files$H1_HOME/.zshrc"
rm -rf -- "$H1_HOME/.zshrc"
mkdir -p "$H1_HOME/.zshrc"
expect_failure_message "restore refuses to replace an existing directory" 'existing directory' \
  backup_restore_snapshot "$manifest_snapshot"
[[ -d "$H1_HOME/.zshrc" ]] && pass "directory destination was preserved" || fail "directory destination was removed"
rm -rf -- "$H1_HOME/.zshrc"
printf 'original\n' >"$H1_HOME/.zshrc"

dir_payload_snapshot="$(make_snapshot "20260101T000003Z")"
mkdir -p "$dir_payload_snapshot/files$H1_HOME/.zshrc"
printf 'nested\n' >"$dir_payload_snapshot/files$H1_HOME/.zshrc/evil"
set_manifest "$dir_payload_snapshot" "$H1_HOME/.zshrc" "$dir_payload_snapshot/files$H1_HOME/.zshrc"
expect_failure_message "restore refuses a directory payload" 'directory payload' \
  backup_restore_snapshot "$dir_payload_snapshot"
expect_eq "file destination survives directory payload rejection" "original" "$(cat "$H1_HOME/.zshrc")"

# Symlinked destination parent.
outside_parent="$TEST_TMP/outside-parent"
mkdir -p "$outside_parent"
mkdir -p "$H1_HOME/.config"
ln -s -- "$outside_parent" "$H1_HOME/.config/btop"
write_payload "$manifest_snapshot" "$H1_HOME/.config/btop/btop.conf" "restored"
set_manifest "$manifest_snapshot" "$H1_HOME/.config/btop/btop.conf" \
  "$manifest_snapshot/files$H1_HOME/.config/btop/btop.conf"
expect_failure_message "restore rejects a symlinked destination parent" 'unapproved destination' \
  backup_restore_snapshot "$manifest_snapshot"
rm -f -- "$H1_HOME/.config/btop"

# Symlinked payload parent.
payload_parent_link="$(make_snapshot "20260101T000004Z")"
mkdir -p "$(dirname -- "$payload_parent_link/files$H1_HOME")"
ln -s -- "$outside_parent" "$payload_parent_link/files$H1_HOME"
printf 'outside\n' >"$outside_parent/.zshrc"
set_manifest "$payload_parent_link" "$H1_HOME/.zshrc" "$payload_parent_link/files$H1_HOME/.zshrc"
expect_failure_message "restore rejects a symlinked payload parent" 'payload parent' \
  backup_restore_snapshot "$payload_parent_link"

# Payload symlinks: absolute, chained and relative escapes.
payload_leaf_link="$(make_snapshot "20260101T000005Z")"
mkdir -p "$payload_leaf_link/files$H1_HOME"
ln -s -- /etc/passwd "$payload_leaf_link/files$H1_HOME/.zshrc"
set_manifest "$payload_leaf_link" "$H1_HOME/.zshrc" "$payload_leaf_link/files$H1_HOME/.zshrc"
expect_failure_message "restore rejects an absolute payload symlink escaping home" 'escapes' \
  backup_restore_snapshot "$payload_leaf_link"

payload_chain_link="$(make_snapshot "20260101T000006Z")"
ln -s -- /etc "$H1_HOME/etc-link"
mkdir -p "$payload_chain_link/files$H1_HOME"
ln -s -- "$H1_HOME/etc-link/passwd" "$payload_chain_link/files$H1_HOME/.zshrc"
set_manifest "$payload_chain_link" "$H1_HOME/.zshrc" "$payload_chain_link/files$H1_HOME/.zshrc"
expect_failure_message "restore rejects a chained payload symlink escaping home" 'escapes' \
  backup_restore_snapshot "$payload_chain_link"
rm -f -- "$H1_HOME/etc-link"

payload_relative_link="$(make_snapshot "20260101T000007Z")"
printf 'payload\n' >"$outside_parent/payload"
mkdir -p "$payload_relative_link/files$H1_HOME"
ln -s -- "../outside-payload" "$payload_relative_link/files$H1_HOME/.zshrc"
printf 'payload\n' >"$payload_relative_link/files/outside-payload"
set_manifest "$payload_relative_link" "$H1_HOME/.zshrc" "$payload_relative_link/files$H1_HOME/.zshrc"
expect_failure_message "restore rejects a relative payload symlink escaping home" 'escapes' \
  backup_restore_snapshot "$payload_relative_link"

# Valid restore.
good_snapshot="$(make_snapshot "20260101T000008Z")"
printf 'original\n' >"$H1_HOME/.zshrc"
write_payload "$good_snapshot" "$H1_HOME/.zshrc" "restored"
set_manifest "$good_snapshot" "$H1_HOME/.zshrc" "$good_snapshot/files$H1_HOME/.zshrc"
reset_failures
check "valid snapshot restores successfully" backup_restore_snapshot "$good_snapshot"
expect_eq "restored content matches the snapshot" "restored" "$(cat "$H1_HOME/.zshrc")"
leftover="$(find "$H1_HOME" -maxdepth 1 -name '.system-init-restore.*' -print -quit)"
expect_eq "restore leaves no staging directories" "" "$leftover"

# Approved destinations whose parent directories do not exist yet.
new_parent_snapshot="$(make_snapshot "20260101T000008Z-a")"
write_payload "$new_parent_snapshot" "$H1_HOME/.config/alacritty/alacritty.toml" "theme = 'test'"
set_manifest "$new_parent_snapshot" "$H1_HOME/.config/alacritty/alacritty.toml" \
  "$new_parent_snapshot/files$H1_HOME/.config/alacritty/alacritty.toml"
check "restore creates approved missing parent directories" \
  backup_restore_snapshot "$new_parent_snapshot"
expect_eq "restore writes into a newly created parent directory" \
  "theme = 'test'" "$(cat "$H1_HOME/.config/alacritty/alacritty.toml")"

# The installer-created .gitconfig.local is an explicitly approved extra file.
gitlocal_snapshot="$(make_snapshot "20260101T000009Z")"
printf 'old-name\n' >"$H1_HOME/.gitconfig.local"
write_payload "$gitlocal_snapshot" "$H1_HOME/.gitconfig.local" "restored-name"
set_manifest "$gitlocal_snapshot" "$H1_HOME/.gitconfig.local" \
  "$gitlocal_snapshot/files$H1_HOME/.gitconfig.local"
check "restore accepts the managed .gitconfig.local side file" \
  backup_restore_snapshot "$gitlocal_snapshot"
expect_eq ".gitconfig.local restored" "restored-name" "$(cat "$H1_HOME/.gitconfig.local")"

# Missing payload and late manifest failures.
missing_snapshot="$(make_snapshot "20260101T000010Z")"
printf 'original\n' >"$H1_HOME/.zshrc"
set_manifest "$missing_snapshot" "$H1_HOME/.zshrc" "$missing_snapshot/files$H1_HOME/.zshrc"
expect_failure_message "restore fails when payload is missing" 'missing or unsupported' \
  backup_restore_snapshot "$missing_snapshot"
expect_eq "original remains when a single restore fails" "original" "$(cat "$H1_HOME/.zshrc")"

multi_validate="$(make_snapshot "20260101T000011Z")"
printf 'original\n' >"$H1_HOME/.zshrc"
printf 'original-git\n' >"$H1_HOME/.gitconfig"
write_payload "$multi_validate" "$H1_HOME/.zshrc" "restored"
{
  printf '%s\t%s\tfile\n' "$H1_HOME/.zshrc" "$multi_validate/files$H1_HOME/.zshrc"
  printf '%s\t%s\tfile\n' "$H1_HOME/.gitconfig" "$multi_validate/files$H1_HOME/.gitconfig"
} >"$multi_validate/manifest.tsv"
expect_failure_message "a late manifest failure aborts before any change" 'before any change' \
  backup_restore_snapshot "$multi_validate"
expect_eq "first entry untouched after validation failure" "original" "$(cat "$H1_HOME/.zshrc")"

# A failure during apply (read-only destination parent) must roll back the
# first, already-applied entry.
rollback_snapshot="$(make_snapshot "20260101T000012Z")"
printf 'original\n' >"$H1_HOME/.zshrc"
mkdir -p "$H1_HOME/.config/btop"
write_payload "$rollback_snapshot" "$H1_HOME/.zshrc" "restored"
write_payload "$rollback_snapshot" "$H1_HOME/.config/btop/btop.conf" "restored-btop"
{
  printf '%s\t%s\tfile\n' "$H1_HOME/.zshrc" "$rollback_snapshot/files$H1_HOME/.zshrc"
  printf '%s\t%s\tfile\n' "$H1_HOME/.config/btop/btop.conf" \
    "$rollback_snapshot/files$H1_HOME/.config/btop/btop.conf"
} >"$rollback_snapshot/manifest.tsv"
chmod 0500 "$H1_HOME/.config/btop"
expect_failure_message "late apply failure rolls back earlier entries" 'rolling back' \
  backup_restore_snapshot "$rollback_snapshot"
chmod 0700 "$H1_HOME/.config/btop"
expect_eq "rolled-back destination retains its original content" "original" "$(cat "$H1_HOME/.zshrc")"
staging_left="$(find "$H1_HOME" -maxdepth 4 -name '.system-init-restore.*' -print -quit)"
expect_eq "rollback leaves no staging directories" "" "$staging_left"

# Rollback failure: preserve the staging data and aggregate the unresolved
# destination instead of deleting the only previous copy.
rollback_fail_snapshot="$(make_snapshot "20260101T000013Z")"
printf 'original-zshrc\n' >"$H1_HOME/.zshrc"
mkdir -p "$H1_HOME/.config/btop"
printf 'original-btop\n' >"$H1_HOME/.config/btop/btop.conf"
write_payload "$rollback_fail_snapshot" "$H1_HOME/.zshrc" "restored-zshrc"
write_payload "$rollback_fail_snapshot" "$H1_HOME/.config/btop/btop.conf" "restored-btop"
{
  printf '%s\t%s\tfile\n' "$H1_HOME/.config/btop/btop.conf" \
    "$rollback_fail_snapshot/files$H1_HOME/.config/btop/btop.conf"
  printf '%s\t%s\tfile\n' "$H1_HOME/.zshrc" "$rollback_fail_snapshot/files$H1_HOME/.zshrc"
} >"$rollback_fail_snapshot/manifest.tsv"
mv() {
  if [[ "${1:-}" == "-fT" && "${2:-}" == "--" && "${3:-}" == */old ]]; then
    return 1
  fi
  command mv "$@"
}
chmod 0500 "$H1_HOME"
RESTORE_ALLOW_LEGACY=1
rollback_fail_output="$(
  backup_restore_snapshot "$rollback_fail_snapshot" 2>&1
)" && rollback_fail_rc=0 || rollback_fail_rc=$?
unset -f mv
chmod 0700 "$H1_HOME"
expect_eq "rollback failure returns nonzero" "1" "$rollback_fail_rc"
if grep -q 'Rollback incomplete' <<<"$rollback_fail_output" \
  && grep -q 'previous data' <<<"$rollback_fail_output"; then
  pass "rollback failure is aggregated with the affected destination"
else
  fail "rollback failure did not aggregate affected destinations"
fi
preserved_stage="$(find "$H1_HOME/.config/btop" -maxdepth 1 -type d -name '.system-init-restore.*' -print -quit)"
[[ -n "$preserved_stage" && -f "$preserved_stage/old" ]] \
  && pass "rollback failure preserves the previous copy in staging" \
  || fail "rollback failure did not preserve the previous copy"
expect_eq "preserved previous copy content" "original-btop" "$(cat "$preserved_stage/old" 2>/dev/null || true)"

# Commit refuses to delete previous data when the destination vanished.
commit_dest="$H1_HOME/.missing-commit-destination"
rm -f -- "$commit_dest"
commit_stage="$H1_HOME/.system-init-restore.commit-test"
mkdir -p "$commit_stage"
printf 'only-copy\n' >"$commit_stage/old"
expect_failure_message "commit preserves previous data when destination is missing" \
  'Refusing to delete previous data' backup_restore_commit "$commit_dest" "$commit_stage"
[[ -f "$commit_stage/old" ]] \
  && pass "missing-destination commit did not delete the staging copy" \
  || fail "missing-destination commit deleted the staging copy"
rm -rf -- "$commit_stage"

# Journal recovery restores a missing destination from stage/old.
recover_dest="$H1_HOME/.p10k.zsh"
recover_stage="$H1_HOME/.system-init-restore.recover-test"
JOURNAL_DIR="$TEST_TMP/h1-journal"
init_private_dir "$JOURNAL_DIR"
recover_journal="$JOURNAL_DIR/restore-test.journal"
mkdir -p "$recover_stage"
chmod 700 "$recover_stage"
printf 'recover-me\n' >"$recover_stage/old"
rm -f -- "$recover_dest"
printf 'MOVED_ASIDE\t%s\t%s\t1\n' "$recover_dest" "$recover_stage" >"$recover_journal"
chmod 600 "$recover_journal"
check "journal recovery restores a missing destination" \
  backup_restore_recover_journal "$recover_journal"
expect_eq "journal recovery content" "recover-me" "$(cat "$recover_dest")"
[[ ! -e "$recover_stage" ]] && pass "journal recovery removed its staging directory" \
  || fail "journal recovery left the staging directory"
[[ ! -e "$recover_journal" ]] && pass "journal recovery removed the resolved journal" \
  || fail "journal recovery left a resolved journal"

# Recovery leaves an existing destination and its staging data untouched.
existing_stage="$H1_HOME/.system-init-restore.existing-test"
mkdir -p "$existing_stage"
chmod 700 "$existing_stage"
printf 'newer-file\n' >"$H1_HOME/.zshrc"
printf 'older-file\n' >"$existing_stage/old"
recover_journal="$JOURNAL_DIR/restore-existing.journal"
printf 'APPLIED\t%s\t%s\t1\n' "$H1_HOME/.zshrc" "$existing_stage" >"$recover_journal"
chmod 600 "$recover_journal"
expect_failure "journal recovery refuses to clobber an existing destination" \
  backup_restore_recover_journal "$recover_journal"
[[ -f "$existing_stage/old" ]] \
  && pass "journal recovery preserved staging data for manual review" \
  || fail "journal recovery deleted staging data for an existing destination"
rm -rf -- "$existing_stage"

# Symlinked HOME: backup and restore must use the same canonical target.
real_home="$TEST_TMP/h1-real-home"
link_home="$TEST_TMP/h1-home-link"
mkdir -p "$real_home"
ln -s -- "$real_home" "$link_home"
printf 'original-home\n' >"$real_home/.zshrc"
saved_target_home="$TARGET_HOME"
saved_backup_dir="$BACKUP_DIR"
TARGET_HOME="$link_home"
BACKUP_DIR="$TEST_TMP/symlink-backups"
mkdir -p "$BACKUP_DIR"
BACKUP_RUN_DIR=""
printf 'restored-home\n' >"$real_home/.zshrc"
check "backup_path supports a symlinked HOME" backup_path "$link_home/.zshrc"
check "symlinked HOME backup finalizes" backup_finalize
if [[ -n "$BACKUP_RUN_DIR" ]] && grep -Fq -- "$link_home/.zshrc" "$BACKUP_RUN_DIR/manifest.tsv"; then
  pass "symlinked HOME backup records the source path"
else
  fail "symlinked HOME backup did not record the source path"
fi
printf 'modified-home\n' >"$real_home/.zshrc"
saved_allow_unsigned="$RESTORE_ALLOW_UNSIGNED"
if (( GPG_TESTS == 0 )); then
  RESTORE_ALLOW_UNSIGNED=1
fi
reset_failures
check "restore supports a symlinked HOME" backup_restore_snapshot "$BACKUP_RUN_DIR"
RESTORE_ALLOW_UNSIGNED="$saved_allow_unsigned"
expect_eq "symlinked HOME restore writes the canonical target" "restored-home" "$(cat "$real_home/.zshrc")"
BACKUP_RUN_DIR=""
TARGET_HOME="$saved_target_home"
BACKUP_DIR="$saved_backup_dir"

check "path_is_under is consistent for a symlinked root" path_is_under "$link_home/.zshrc" "$link_home"
check "path_resolves_under follows a symlinked root" path_resolves_under "$link_home/.zshrc" "$link_home"
expect_failure "path_is_under rejects equality with the root" path_is_under "/" "/"

backup_outside="$TEST_TMP/outside-backup-source"
printf 'outside\n' >"$backup_outside"
expect_failure_message "backup_path refuses sources outside TARGET_HOME" 'outside' \
  backup_path "$backup_outside"

# ---------------------------------------------------------------------------
# H1b: canonical v2 manifest, signatures, hashes and downgrade policy
# ---------------------------------------------------------------------------
note "# H1b v2 manifest integrity"

v2_home="$TEST_TMP/v2-home"
mkdir -p "$v2_home"
TARGET_HOME="$v2_home"
BACKUP_DIR="$TEST_TMP/v2-snapshots"
mkdir -p "$BACKUP_DIR"
BACKUP_RUN_DIR=""
RESTORE_ALLOW_LEGACY=0
RESTORE_ALLOW_UNSIGNED=0

printf 'v2-original\n' >"$v2_home/.zshrc"
check "v2 backup creates a canonical manifest" backup_path "$v2_home/.zshrc" "dotfile"
check "v2 backup finalizes" backup_finalize
v2_snapshot="$BACKUP_RUN_DIR"
expect_eq "v2 manifest version header" $'SYSTEM-INIT-BACKUP-V2\t1' \
  "$(head -n 1 "$v2_snapshot/manifest.v2")"
expected_v2_line="$(
  printf '.zshrc\tfile\t%s\t%s\t0600\tfiles/.zshrc\tdotfile' \
    "$(stat -c '%s' -- "$v2_snapshot/files/.zshrc")" \
    "$(file_sha256 "$v2_snapshot/files/.zshrc")"
)"
expect_eq "v2 manifest contains relative destination and payload" \
  "$expected_v2_line" "$(tail -n 1 "$v2_snapshot/manifest.v2")"

if (( GPG_TESTS == 1 )); then
  expect_eq "signed v2 snapshot status" "signed" "$(backup_snapshot_status "$v2_snapshot")"
else
  expect_eq "unsigned v2 snapshot status" "unsigned-v2" "$(backup_snapshot_status "$v2_snapshot")"
  RESTORE_ALLOW_UNSIGNED=1
fi

printf 'v2-modified\n' >"$v2_home/.zshrc"
check "v2 restore succeeds with valid signature/hashes" backup_restore_snapshot "$v2_snapshot"
expect_eq "v2 restore content" "v2-original" "$(cat "$v2_home/.zshrc")"
expect_eq "v2 restore normalizes mode" "600" "$(stat -c '%a' "$v2_home/.zshrc")"

# Payload tampering must fail before any destination change.
printf 'protected\n' >"$v2_home/.zshrc"
printf 'tampered\n' >"$v2_snapshot/files/.zshrc"
expect_failure_message "tampered v2 payload is rejected" 'hash or size' \
  backup_restore_snapshot "$v2_snapshot"
expect_eq "tampered payload did not change the destination" "protected" "$(cat "$v2_home/.zshrc")"
printf 'v2-original\n' >"$v2_snapshot/files/.zshrc"

# Manifest tampering must fail even when the v1 manifest is intact.
cp -- "$v2_snapshot/manifest.v2" "$TEST_TMP/v2-manifest.good"
awk -F'\t' 'BEGIN { OFS="\t" } NR == 1 { print; next } { $4="0000000000000000000000000000000000000000000000000000000000000000"; print }' \
  "$TEST_TMP/v2-manifest.good" >"$v2_snapshot/manifest.v2"
expect_failure_message "tampered v2 manifest is rejected" 'signature|hash|manifest' \
  backup_restore_snapshot "$v2_snapshot"
cp -- "$TEST_TMP/v2-manifest.good" "$v2_snapshot/manifest.v2"

if (( GPG_TESTS == 1 )); then
  cp -- "$v2_snapshot/manifest.v2.sig" "$TEST_TMP/v2-signature.good"
  printf 'not-a-signature\n' >"$v2_snapshot/manifest.v2.sig"
  expect_failure_message "invalid v2 signature is rejected" 'signature' \
    backup_restore_snapshot "$v2_snapshot"
  expect_eq "invalid-signature v2 status" "invalid-signature" \
    "$(backup_snapshot_status "$v2_snapshot")"
  RESTORE_ALLOW_UNSIGNED=1
  expect_failure_message "invalid signature is not bypassed by --allow-unsigned" 'signature' \
    backup_restore_snapshot "$v2_snapshot"
  RESTORE_ALLOW_UNSIGNED=0
  cp -- "$TEST_TMP/v2-signature.good" "$v2_snapshot/manifest.v2.sig"

  rm -f -- "$v2_snapshot/manifest.v2.sig"
  expect_failure_message "unsigned v2 requires --allow-unsigned" 'unsigned' \
    backup_restore_snapshot "$v2_snapshot"
  expect_eq "unsigned v2 status" "unsigned-v2" "$(backup_snapshot_status "$v2_snapshot")"
  printf 'v2-unsigned\n' >"$v2_home/.zshrc"
  RESTORE_ALLOW_UNSIGNED=1
  check "unsigned v2 restores with explicit opt-in" backup_restore_snapshot "$v2_snapshot"
  RESTORE_ALLOW_UNSIGNED=0
  expect_eq "unsigned v2 restored content" "v2-original" "$(cat "$v2_home/.zshrc")"
fi

# v2 symlink entries hash the link target and restore the link itself.
printf 'link-target\n' >"$v2_home/.zshrc-target"
ln -s -- ".zshrc-target" "$v2_home/.p10k.zsh"
saved_backup_dir="$BACKUP_DIR"
BACKUP_DIR="$TEST_TMP/v2-symlink-snapshots"
mkdir -p "$BACKUP_DIR"
BACKUP_RUN_DIR=""
check "v2 backup records a symlink entry" backup_path "$v2_home/.p10k.zsh" "dotfile"
check "v2 symlink backup finalizes" backup_finalize
expect_eq "v2 symlink manifest type and mode" "symlink 0777" \
  "$(tail -n 1 "$BACKUP_RUN_DIR/manifest.v2" | awk -F'\t' '{ print $2, $5 }')"
rm -f -- "$v2_home/.p10k.zsh"
saved_allow_unsigned="$RESTORE_ALLOW_UNSIGNED"
(( GPG_TESTS == 0 )) && RESTORE_ALLOW_UNSIGNED=1
check "v2 symlink restore succeeds" backup_restore_snapshot "$BACKUP_RUN_DIR"
RESTORE_ALLOW_UNSIGNED="$saved_allow_unsigned"
[[ -L "$v2_home/.p10k.zsh" && "$(readlink -- "$v2_home/.p10k.zsh")" == ".zshrc-target" ]] \
  && pass "v2 symlink was restored with its relative target" \
  || fail "v2 symlink was not restored correctly"
BACKUP_RUN_DIR=""
BACKUP_DIR="$saved_backup_dir"

# Legacy v1 status and duplicate destinations.
legacy_status_snapshot="$(make_snapshot "20260101T000090Z")"
printf 'legacy-status\n' >"$v2_home/.zshrc"
write_payload "$legacy_status_snapshot" "$v2_home/.zshrc" "legacy-status"
set_manifest "$legacy_status_snapshot" "$v2_home/.zshrc" \
  "$legacy_status_snapshot/files$v2_home/.zshrc"
expect_eq "legacy snapshot status" "legacy-unverified" \
  "$(backup_snapshot_status "$legacy_status_snapshot")"

v1_duplicate="$(make_snapshot "20260101T000091Z")"
printf 'protected\n' >"$v2_home/.zshrc"
write_payload "$v1_duplicate" "$v2_home/.zshrc" "restored"
printf '%s\t%s\tfile\n%s\t%s\tfile\n' \
  "$v2_home/.zshrc" "$v1_duplicate/files$v2_home/.zshrc" \
  "$v2_home/.zshrc" "$v1_duplicate/files$v2_home/.zshrc" \
  >"$v1_duplicate/manifest.tsv"
RESTORE_ALLOW_LEGACY=1
expect_failure_message "v1 duplicate destinations are rejected" 'duplicate destination' \
  backup_restore_snapshot "$v1_duplicate"
RESTORE_ALLOW_LEGACY=0

# Malformed, unsorted and duplicate v2 manifests fail closed, even when a
# valid v1 manifest is present (downgrade prevention).
downgrade_snapshot="$BACKUP_DIR/20260101T000092Z"
mkdir -p "$downgrade_snapshot/files"
printf 'created=test\ncomplete=1\n' >"$downgrade_snapshot/metadata.conf"
printf 'protected\n' >"$v2_home/.zshrc"
write_payload "$downgrade_snapshot" "$v2_home/.zshrc" "v1-restored"
printf '%s\t%s\tfile\n' "$v2_home/.zshrc" "$downgrade_snapshot/files$v2_home/.zshrc" \
  >"$downgrade_snapshot/manifest.tsv"
printf 'not-a-v2-manifest\n' >"$downgrade_snapshot/manifest.v2"
RESTORE_ALLOW_LEGACY=1
RESTORE_ALLOW_UNSIGNED=1
expect_failure_message "invalid v2 never falls back to v1" 'v2 manifest' \
  backup_restore_snapshot "$downgrade_snapshot"
expect_eq "downgrade attempt left destination untouched" "protected" "$(cat "$v2_home/.zshrc")"

dup_v2="$BACKUP_DIR/20260101T000093Z"
mkdir -p "$dup_v2/files/.zshrc"
printf 'created=test\ncomplete=1\n' >"$dup_v2/metadata.conf"
: >"$dup_v2/files/.zshrc/payload"
printf 'SYSTEM-INIT-BACKUP-V2\t1\n' >"$dup_v2/manifest.v2"
printf '.zshrc\tfile\t0\t%s\t0600\tfiles/.zshrc\t-\n' "$(printf '' | sha256sum | awk '{print $1}')" \
  >>"$dup_v2/manifest.v2"
printf '.zshrc\tfile\t0\t%s\t0600\tfiles/.zshrc\t-\n' "$(printf '' | sha256sum | awk '{print $1}')" \
  >>"$dup_v2/manifest.v2"
printf 'protected\n' >"$v2_home/.zshrc"
expect_failure_message "duplicate v2 destinations are rejected" 'v2 manifest' \
  backup_restore_snapshot "$dup_v2"

unsorted_v2="$BACKUP_DIR/20260101T000094Z"
mkdir -p "$unsorted_v2/files"
printf 'created=test\ncomplete=1\n' >"$unsorted_v2/metadata.conf"
printf 'SYSTEM-INIT-BACKUP-V2\t1\n' >"$unsorted_v2/manifest.v2"
empty_sha="$(printf '' | sha256sum | awk '{print $1}')"
printf '.zshrc\tfile\t0\t%s\t0600\tfiles/.zshrc\t-\n' "$empty_sha" >>"$unsorted_v2/manifest.v2"
printf '.gitconfig\tfile\t0\t%s\t0600\tfiles/.gitconfig\t-\n' "$empty_sha" >>"$unsorted_v2/manifest.v2"
printf 'protected\n' >"$v2_home/.zshrc"
expect_failure_message "unsorted v2 manifests are rejected" 'v2 manifest' \
  backup_restore_snapshot "$unsorted_v2"

malformed_v2="$BACKUP_DIR/20260101T000095Z"
mkdir -p "$malformed_v2/files"
printf 'created=test\ncomplete=1\n' >"$malformed_v2/metadata.conf"
printf 'SYSTEM-INIT-BACKUP-V2\t1\n' >"$malformed_v2/manifest.v2"
printf '.zshrc\tfile\t0\t%s\t0777\tfiles/.zshrc\t-\n' "$empty_sha" >>"$malformed_v2/manifest.v2"
expect_failure_message "invalid v2 modes are rejected" 'v2 manifest' \
  backup_restore_snapshot "$malformed_v2"

ambiguous_v2="$BACKUP_DIR/20260101T000096Z"
mkdir -p "$ambiguous_v2/files"
printf 'created=test\ncomplete=1\n' >"$ambiguous_v2/metadata.conf"
printf 'SYSTEM-INIT-BACKUP-V2\t1\n' >"$ambiguous_v2/manifest.v2"
printf '.zshrc\tfile\t0\t%s\t0600\tfiles/.zshrc\t-\textra\n' "$empty_sha" \
  >>"$ambiguous_v2/manifest.v2"
expect_failure_message "ambiguous/extra v2 fields are rejected" 'v2 manifest' \
  backup_restore_snapshot "$ambiguous_v2"
RESTORE_ALLOW_LEGACY=0
RESTORE_ALLOW_UNSIGNED=0

# ---------------------------------------------------------------------------
# H3: dotfile destination allowlist
# ---------------------------------------------------------------------------
note "# H3 dotfile destinations"

TARGET_HOME="$TEST_TMP/h3-home"
mkdir -p "$TARGET_HOME"
REPO_ROOT="$TEST_TMP/h3-repo"
mkdir -p "$REPO_ROOT/modules/core" "$REPO_ROOT/modules/terminal" "$REPO_ROOT/dotfiles/home"
printf 'gitconfig\n' >"$REPO_ROOT/dotfiles/home/.gitconfig"
printf 'zshrc\n' >"$REPO_ROOT/dotfiles/home/.zshrc"

for unsafe_target in \
  ".ssh/config" \
  ".gnupg/gpg.conf" \
  ".local/bin/evil" \
  ".config/autostart/evil.desktop" \
  ".config/systemd/user/evil.service" \
  "." \
  "./.zshrc" \
  "../outside" \
  ".config/../.ssh/config" \
  "/etc/passwd" \
  ".gitconfig.local"; do
  expect_failure "unsafe install target '$unsafe_target' is rejected" \
    dotfiles_target_is_safe "$unsafe_target"
done

for safe_target in ".gitconfig" ".zshrc" ".p10k.zsh" \
  ".config/alacritty/alacritty.toml" \
  ".config/btop/btop.conf" \
  ".config/Code/User/settings.json"; do
  check "allowlisted dotfile target '$safe_target' is accepted" \
    dotfiles_target_is_safe "$safe_target"
done

check "restore allowlist accepts .gitconfig.local" \
  dotfiles_restore_target_is_safe ".gitconfig.local"
for unsafe_restore_target in ".ssh/authorized_keys" ".gnupg/gpg.conf" \
  ".local/bin/evil" ".config/autostart/evil.desktop" \
  ".config/systemd/user/evil.service" "../outside"; do
  expect_failure "restore allowlist rejects '$unsafe_restore_target'" \
    dotfiles_restore_target_is_safe "$unsafe_restore_target"
done

check "valid manifest row is accepted" dotfiles_row_valid core symlink all dotfiles/home/.gitconfig .gitconfig
expect_failure "manifest row targeting .ssh is rejected" \
  dotfiles_row_valid core symlink all dotfiles/home/.gitconfig .ssh/config

mkdir -p "$TEST_TMP/h3-outside-config"
mkdir -p "$TARGET_HOME/.config"
ln -s -- "$TEST_TMP/h3-outside-config" "$TARGET_HOME/.config/btop"
expect_failure "dotfile target through a symlinked parent is rejected" \
  dotfiles_target_is_safe ".config/btop/btop.conf"
rm -f -- "$TARGET_HOME/.config/btop"

mkdir -p "$TARGET_HOME/.zshrc"
reset_failures
expect_failure "dotfiles_install_one refuses to replace a directory" \
  dotfiles_install_one terminal symlink dotfiles/home/.zshrc .zshrc
[[ -d "$TARGET_HOME/.zshrc" ]] && pass "directory target was preserved" || fail "directory target was removed"
rm -rf -- "$TARGET_HOME/.zshrc"

malicious_manifest="$TEST_TMP/h3-manifest.tsv"
printf 'core\tsymlink\tall\tdotfiles/home/.gitconfig\t../../.ssh/authorized_keys\n' >"$malicious_manifest"
DOTFILES_MANIFEST="$malicious_manifest"
SELECTED_MODULES=(core)
expect_failure "dotfiles_entries rejects a traversal target" dotfiles_entries

DOTFILES_MANIFEST="$ACTUAL_REPO/dotfiles/manifest.tsv"
REPO_ROOT="$ACTUAL_REPO"

# Symlinked HOME must not weaken the allowlist or the descendant checks.
h3_real_home="$TEST_TMP/h3-real-home"
h3_link_home="$TEST_TMP/h3-link-home"
mkdir -p "$h3_real_home/.config/btop"
ln -s -- "$h3_real_home" "$h3_link_home"
TARGET_HOME="$h3_link_home"
check "allowlisted target is accepted with a symlinked HOME" \
  dotfiles_target_is_safe ".config/btop/btop.conf"
mkdir -p "$TEST_TMP/h3-outside"
mkdir -p "$h3_real_home/.config"
ln -s -- "$TEST_TMP/h3-outside" "$h3_real_home/.config/alacritty"
expect_failure "symlinked descendant is rejected with a symlinked HOME" \
  dotfiles_target_is_safe ".config/alacritty/alacritty.toml"
rm -f -- "$h3_real_home/.config/alacritty"
TARGET_HOME="$TEST_TMP/h3-home"

# ---------------------------------------------------------------------------
# M1: module and hook validation
# ---------------------------------------------------------------------------
note "# M1 module names and hooks"

check "valid module name is accepted" module_name_is_valid "dev-tools_1"
for invalid_module in "" "." ".." "../evil" "a/b" "-option" "a b" "a.b"; do
  expect_failure "invalid module name '$invalid_module' is rejected" \
    module_name_is_valid "$invalid_module"
done

REPO_ROOT="$TEST_TMP/m1-repo"
mkdir -p "$REPO_ROOT/modules/hookmod" "$REPO_ROOT/modules/badmod"
printf 'MODULE_DESCRIPTION="hook"\n' >"$REPO_ROOT/modules/hookmod/module.conf"
printf 'MODULE_DESCRIPTION="bad"\nMODULE_DEPENDS="../../evil"\n' >"$REPO_ROOT/modules/badmod/module.conf"

outside_hook="$TEST_TMP/outside-hook.sh"
printf 'touch %q\n' "$TEST_TMP/m1-hook-executed" >"$outside_hook"
ln -s -- "$outside_hook" "$REPO_ROOT/modules/hookmod/post-install.sh"

expect_failure "modules_hook_path rejects a symlinked hook" modules_hook_path hookmod
reset_failures
SELECTED_MODULES=(hookmod)
modules_run >>"$TEST_LOG" 2>&1
if (( ${#FAILED_ITEMS[@]} > 0 )); then
  pass "modules_run records a failure for a symlinked hook"
else
  fail "modules_run did not record a failure for a symlinked hook"
fi
[[ ! -e "$TEST_TMP/m1-hook-executed" ]] && pass "symlinked hook was not executed" || fail "symlinked hook executed"

rm -f -- "$REPO_ROOT/modules/hookmod/post-install.sh"
printf 'module_post_install() { :; }\n' >"$REPO_ROOT/modules/hookmod/post-install.sh"
resolved_hook="$(modules_hook_path hookmod 2>>"$TEST_LOG")"
expect_eq "valid hook resolves under modules/" "$REPO_ROOT/modules/hookmod/post-install.sh" "$resolved_hook"

MODULES_CONF="$TEST_TMP/m1-modules.conf"
printf 'badmod\n' >"$MODULES_CONF"
reset_failures
expect_failure "modules_validate_all rejects traversal dependencies" modules_validate_all

REPO_ROOT="$ACTUAL_REPO"
MODULES_CONF="$ACTUAL_REPO/config/modules.conf"
SELECTED_MODULES=()

# ---------------------------------------------------------------------------
# M2: package token validation and end-of-options
# ---------------------------------------------------------------------------
note "# M2 package tokens"

check "normal package token is accepted" package_name_is_valid "zlib-devel"
for invalid_package in "-y" "--installroot=/" "foo bar" "../pkg" "foo/bar" ""; do
  expect_failure "invalid package token '$invalid_package' is rejected" \
    package_name_is_valid "$invalid_package"
done

CAPTURE="$TEST_TMP/m2-capture"
ORIGINAL_RUN_SUDO="$(declare -f run_sudo)"
ORIGINAL_DNF_INSTALLED="$(declare -f dnf_package_installed)"
ORIGINAL_FLATPAK_INSTALLED="$(declare -f flatpak_package_installed)"
run_sudo() {
  printf '%s\n' "$@" >"$CAPTURE"
  return 0
}
dnf_package_installed() { return 1; }
flatpak_package_installed() { return 1; }
FLATPAK_REMOTE=flathub

rm -f -- "$CAPTURE"
check "dnf_install accepts a normal package" dnf_install goodpkg
captured="$(cat "$CAPTURE" 2>/dev/null || true)"
expect_match "dnf_install passes -- before packages" $'(^|\n)install\n-y\n--\ngoodpkg($|\n)' "$captured"

rm -f -- "$CAPTURE"
expect_failure "dnf_install rejects an option-like package" dnf_install --installroot=/
[[ ! -e "$CAPTURE" ]] && pass "dnf_install did not invoke sudo for an invalid token" || fail "dnf_install invoked sudo for an invalid token"

rm -f -- "$CAPTURE"
check "flatpak_install accepts a normal application" flatpak_install org.example.App
captured="$(cat "$CAPTURE" 2>/dev/null || true)"
expect_match "flatpak_install passes -- before applications" $'(^|\n)install\n--system\n-y\n--noninteractive\nflathub\n--\norg.example.App($|\n)' "$captured"

rm -f -- "$CAPTURE"
expect_failure "flatpak_install rejects an option-like application" flatpak_install -x
[[ ! -e "$CAPTURE" ]] && pass "flatpak_install did not invoke sudo for an invalid token" || fail "flatpak_install invoked sudo for an invalid token"

rm -f -- "$CAPTURE"
expect_failure "flatpak_remove rejects an option-like application" flatpak_remove --user
[[ ! -e "$CAPTURE" ]] && pass "flatpak_remove did not invoke sudo for an invalid token" || fail "flatpak_remove invoked sudo for an invalid token"

FLATPAK_REMOTE=flathub
FLATPAK_REPO_URL="http://dl.flathub.org/repo/"
rm -f -- "$CAPTURE"
expect_failure "flatpak_remote_ensure rejects a non-HTTPS repository URL" flatpak_remote_ensure
[[ ! -e "$CAPTURE" ]] && pass "non-HTTPS Flatpak repository did not invoke sudo" || fail "non-HTTPS Flatpak repository invoked sudo"

FLATPAK_REPO_URL="-x"
expect_failure "flatpak_remote_ensure rejects an option-like repository URL" flatpak_remote_ensure

FLATPAK_REPO_URL="https://example.invalid/repo.flatpakrepo"
rm -f -- "$CAPTURE"
expect_failure "flatpak_remote_ensure rejects an arbitrary HTTPS repository URL" flatpak_remote_ensure
[[ ! -e "$CAPTURE" ]] && pass "arbitrary HTTPS Flatpak repository did not invoke sudo" || fail "arbitrary HTTPS Flatpak repository invoked sudo"

FLATPAK_REPO_URL="https://dl.flathub.org.evil.invalid/repo/"
expect_failure "flatpak_remote_ensure rejects a lookalike Flathub host" flatpak_remote_ensure

check "approved Flathub repository URL is accepted" \
  flatpak_remote_url_is_approved flathub "https://dl.flathub.org/repo/"
check "approved legacy Flathub repository URL is accepted" \
  flatpak_remote_url_is_approved flathub "https://flathub.org/repo/"
expect_failure "unapproved Flathub repository URL is rejected" \
  flatpak_remote_url_is_approved flathub "https://evil.example.invalid/repo/"

flatpak() { return 0; }
FLATPAK_REPO_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"
rm -f -- "$CAPTURE"
check "flatpak_remote_ensure accepts the current official Flathub repository" flatpak_remote_ensure
captured="$(cat "$CAPTURE" 2>/dev/null || true)"
expect_match "flatpak_remote_ensure passes -- before the remote and URL" \
  $'(^|\n)remote-add\n--if-not-exists\n--system\n--\nflathub\nhttps://dl.flathub.org/repo/flathub.flatpakrepo($|\n)' \
  "$captured"
if [[ "$captured" != *"--no-gpg-verify"* ]]; then
  pass "flatpak_remote_ensure keeps Flatpak GPG verification enabled"
else
  fail "flatpak_remote_ensure disabled Flatpak GPG verification"
fi

rm -f -- "$CAPTURE"
FLATPAK_REPO_URL="https://flathub.org/repo/flathub.flatpakrepo"
check "flatpak_remote_ensure accepts the legacy Flathub descriptor" flatpak_remote_ensure
captured="$(cat "$CAPTURE" 2>/dev/null || true)"
expect_match "legacy Flathub descriptor is passed through unchanged" \
  $'(^|\n)remote-add\n--if-not-exists\n--system\n--\nflathub\nhttps://flathub.org/repo/flathub.flatpakrepo($|\n)' \
  "$captured"
unset -f flatpak
FLATPAK_REPO_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"

REPO_ROOT="$TEST_TMP/m2-repo"
mkdir -p "$REPO_ROOT/modules/pkgmod"
printf 'dnf -y\n' >"$REPO_ROOT/modules/pkgmod/packages.fedora"
SELECTED_MODULES=(pkgmod)
PLATFORM=fedora
expect_failure "package manifest validation rejects option-like tokens" validation_package_manifests
printf 'dnf ../pkg\n' >"$REPO_ROOT/modules/pkgmod/packages.fedora"
expect_failure "package manifest validation rejects traversal tokens" validation_package_manifests

# Profile policy: extended always includes optional apps, core always excludes
# them, and direct --module runs follow INSTALL_OPTIONAL_APPS.
OPTIONAL_REPO="$TEST_TMP/m2-optional-repo"
mkdir -p "$OPTIONAL_REPO/modules/optmod"
cat >"$OPTIONAL_REPO/modules/optmod/packages.fedora" <<'OPTIONAL_MANIFEST'
dnf required-pkg
dnf optional-pkg optional
flatpak org.example.Required
flatpak org.example.Optional optional
OPTIONAL_MANIFEST
REPO_ROOT="$OPTIONAL_REPO"
PLATFORM=fedora
OPTIONAL_CAPTURE="$TEST_TMP/m2-optional-capture"
ORIGINAL_DNF_INSTALL="$(declare -f dnf_install)"
ORIGINAL_FLATPAK_INSTALL="$(declare -f flatpak_install)"
dnf_install() { printf 'dnf %s\n' "$*" >>"$OPTIONAL_CAPTURE"; }
flatpak_install() { printf 'flatpak %s\n' "$*" >>"$OPTIONAL_CAPTURE"; }
SAVED_INSTALL_OPTIONAL_APPS="$INSTALL_OPTIONAL_APPS"
SAVED_PROFILE="${PROFILE:-}"

rm -f -- "$OPTIONAL_CAPTURE"
PROFILE=extended
INSTALL_OPTIONAL_APPS=0
check "extended profile installs optional packages despite the direct-run setting" \
  packages_install_module optmod
captured="$(cat "$OPTIONAL_CAPTURE" 2>/dev/null || true)"
expect_match "extended profile installs optional DNF packages" \
  $'(^|\n)dnf optional-pkg($|\n)' "$captured"
expect_match "extended profile installs optional Flatpak applications" \
  $'(^|\n)flatpak org\.example\.Optional($|\n)' "$captured"

rm -f -- "$OPTIONAL_CAPTURE"
PROFILE=core
INSTALL_OPTIONAL_APPS=1
check "core profile skips optional packages even when enabled in settings" \
  packages_install_module optmod
captured="$(cat "$OPTIONAL_CAPTURE" 2>/dev/null || true)"
if [[ "$captured" != *"optional-pkg"* && "$captured" != *"org.example.Optional"* ]]; then
  pass "core profile did not install optional packages"
else
  fail "core profile installed optional packages"
fi
expect_match "core profile still installs required packages" \
  $'(^|\n)flatpak org\.example\.Required($|\n)' "$captured"

rm -f -- "$OPTIONAL_CAPTURE"
unset PROFILE
INSTALL_OPTIONAL_APPS=1
check "direct module runs install optional packages when enabled" \
  packages_install_module optmod
captured="$(cat "$OPTIONAL_CAPTURE" 2>/dev/null || true)"
expect_match "direct module run installs optional packages" \
  $'(^|\n)flatpak org\.example\.Optional($|\n)' "$captured"

rm -f -- "$OPTIONAL_CAPTURE"
INSTALL_OPTIONAL_APPS=0
check "direct module runs skip optional packages by default" \
  packages_install_module optmod
captured="$(cat "$OPTIONAL_CAPTURE" 2>/dev/null || true)"
if [[ "$captured" != *"optional-pkg"* && "$captured" != *"org.example.Optional"* ]]; then
  pass "direct module run did not install optional packages"
else
  fail "direct module run installed optional packages"
fi

REPO_ROOT="$ACTUAL_REPO"
PROFILE=extended
INSTALL_OPTIONAL_APPS=0
rm -f -- "$OPTIONAL_CAPTURE"
check "extended profile installs all productivity applications" \
  packages_install_module productivity
captured="$(cat "$OPTIONAL_CAPTURE" 2>/dev/null || true)"
for productivity_app in \
  md.obsidian.Obsidian \
  org.keepassxc.KeePassXC \
  me.proton.Mail \
  me.proton.Pass \
  com.protonvpn.www \
  io.github.shiftey.Desktop \
  com.github.tchx84.Flatseal \
  com.mattjakeman.ExtensionManager; do
  if grep -Fq -- "$productivity_app" <<<"$captured"; then
    pass "extended profile includes productivity app $productivity_app"
  else
    fail "extended profile omitted productivity app $productivity_app"
  fi
done

if [[ -n "$SAVED_PROFILE" ]]; then
  PROFILE="$SAVED_PROFILE"
else
  unset PROFILE
fi
INSTALL_OPTIONAL_APPS="$SAVED_INSTALL_OPTIONAL_APPS"
eval "$ORIGINAL_DNF_INSTALL"
eval "$ORIGINAL_FLATPAK_INSTALL"

REPO_ROOT="$ACTUAL_REPO"
SELECTED_MODULES=()
eval "$ORIGINAL_RUN_SUDO"
eval "$ORIGINAL_DNF_INSTALLED"
eval "$ORIGINAL_FLATPAK_INSTALLED"

# ---------------------------------------------------------------------------
# M3: zsh framework checkouts
# ---------------------------------------------------------------------------
note "# M3 zsh framework checkouts"

if command -v git >/dev/null 2>&1; then
  TARGET_HOME="$TEST_TMP/m3-home"
  mkdir -p "$TARGET_HOME"
  git_repo="$TEST_TMP/m3-git"
  git init -q "$git_repo"
  git -C "$git_repo" config user.name "Test"
  git -C "$git_repo" config user.email "test@example.invalid"
  printf 'one\n' >"$git_repo/file"
  git -C "$git_repo" add file
  git -C "$git_repo" commit -q -m one
  commit_one="$(git -C "$git_repo" rev-parse HEAD)"
  printf 'two\n' >>"$git_repo/file"
  git -C "$git_repo" commit -q -am two

  wrong_checkout="$TARGET_HOME/wrong"
  git clone -q -- "$git_repo" "$wrong_checkout"
  reset_failures
  expect_failure "existing checkout at the wrong commit fails closed" \
    zsh_git_clone_at "$git_repo" "$wrong_checkout" "$commit_one"

  dirty_checkout="$TARGET_HOME/dirty"
  git clone -q -- "$git_repo" "$dirty_checkout"
  git -C "$dirty_checkout" checkout -q "$commit_one"
  printf 'dirty\n' >>"$dirty_checkout/file"
  reset_failures
  expect_failure "dirty framework checkout fails closed" \
    zsh_git_clone_at "$git_repo" "$dirty_checkout" "$commit_one"

  clean_checkout="$TARGET_HOME/clean"
  git clone -q -- "$git_repo" "$clean_checkout"
  git -C "$clean_checkout" checkout -q "$commit_one"
  reset_failures
  check "clean pinned framework checkout is accepted" \
    zsh_git_clone_at "$git_repo" "$clean_checkout" "$commit_one"

  failed_checkout="$TARGET_HOME/failed"
  reset_failures
  expect_failure "failed clone fails closed" \
    zsh_git_clone_at "$TEST_TMP/does-not-exist" "$failed_checkout" "$commit_one"
  [[ ! -e "$failed_checkout" ]] && pass "failed clone left no partial checkout" || fail "failed clone left a partial checkout"

  symlink_target="$TEST_TMP/m3-symlink-target"
  mkdir -p "$symlink_target"
  symlink_checkout="$TARGET_HOME/symlink"
  ln -s -- "$symlink_target" "$symlink_checkout"
  reset_failures
  expect_failure "symlinked framework destination is rejected" \
    zsh_git_clone_at "$git_repo" "$symlink_checkout" "$commit_one"

  # A checkout whose .git is a symlink must be refused before any Git command.
  gitlink_checkout="$TARGET_HOME/gitlink"
  git clone -q -- "$git_repo" "$gitlink_checkout"
  git -C "$gitlink_checkout" checkout -q "$commit_one"
  mv -- "$gitlink_checkout/.git" "$TEST_TMP/m3-moved-git"
  ln -s -- "$TEST_TMP/m3-moved-git" "$gitlink_checkout/.git"
  reset_failures
  expect_failure_message "symlinked .git metadata is rejected" 'not a real directory' \
    zsh_git_clone_at "$git_repo" "$gitlink_checkout" "$commit_one"

  # Ownership check: simulate a foreign owner by overriding stat.
  if git_checkout_owned_by_user "$clean_checkout"; then
    pass "checkout ownership check accepts the current user"
  else
    fail "checkout ownership check rejected the current user"
  fi
  stat() { printf '99999\n'; }
  reset_failures
  expect_failure "checkout ownership check rejects foreign ownership" \
    git_checkout_owned_by_user "$clean_checkout"
  unset -f stat

  # Repo-local core.fsmonitor is executable configuration. Prove the vector is
  # live, then prove the safe wrapper suppresses it.
  fsmonitor_checkout="$TARGET_HOME/fsmonitor"
  git clone -q -- "$git_repo" "$fsmonitor_checkout"
  git -C "$fsmonitor_checkout" checkout -q "$commit_one"
  fsmonitor_marker="$TEST_TMP/m3-fsmonitor-executed"
  fsmonitor_hook="$TEST_TMP/m3-fsmonitor-hook"
  printf '#!/bin/sh\ntouch %q\nexit 0\n' "$fsmonitor_marker" >"$fsmonitor_hook"
  chmod 0755 "$fsmonitor_hook"
  git -C "$fsmonitor_checkout" config core.fsmonitor "$fsmonitor_hook"
  rm -f -- "$fsmonitor_marker"
  GIT_OPTIONAL_LOCKS=0 git -C "$fsmonitor_checkout" status --porcelain >/dev/null 2>&1 || true
  if [[ -e "$fsmonitor_marker" ]]; then
    rm -f -- "$fsmonitor_marker"
    reset_failures
    expect_failure "checkout validation rejects a malicious core.fsmonitor config" \
      zsh_git_clone_at "$git_repo" "$fsmonitor_checkout" "$commit_one"
    [[ ! -e "$fsmonitor_marker" ]] \
      && pass "malicious core.fsmonitor did not execute during validation" \
      || fail "malicious core.fsmonitor executed during validation"
  else
    skip "this Git version does not execute a path-valued core.fsmonitor"
  fi

  # The update path uses git_safe and the same ownership check. Exercise both
  # the fsmonitor and hook suppression mechanisms it relies on.
  update_checkout="$TARGET_HOME/update-checkout"
  git clone -q -- "$git_repo" "$update_checkout"
  git -C "$update_checkout" checkout -q "$commit_one"
  update_marker="$TEST_TMP/m3-update-marker"
  update_hook="$TEST_TMP/m3-update-fsmonitor"
  printf '#!/bin/sh\ntouch %q\nexit 0\n' "$update_marker" >"$update_hook"
  chmod 0755 "$update_hook"
  git -C "$update_checkout" config core.fsmonitor "$update_hook"
  rm -f -- "$update_marker"
  GIT_OPTIONAL_LOCKS=0 git -C "$update_checkout" status --porcelain >/dev/null 2>&1 || true
  if [[ -e "$update_marker" ]]; then
    rm -f -- "$update_marker"
    reset_failures
    check "update-path Git wrapper suppresses core.fsmonitor" \
      git_safe -C "$update_checkout" status --porcelain
    [[ ! -e "$update_marker" ]] \
      && pass "update-path Git wrapper did not execute core.fsmonitor" \
      || fail "update-path Git wrapper executed core.fsmonitor"
  else
    skip "Git version does not execute path-valued core.fsmonitor"
  fi

  post_checkout="$update_checkout/.git/hooks/post-checkout"
  printf '#!/bin/sh\ntouch %q\nexit 0\n' "$update_marker" >"$post_checkout"
  chmod 0755 "$post_checkout"
  rm -f -- "$update_marker"
  git -C "$update_checkout" checkout -q HEAD >/dev/null 2>&1 || true
  if [[ -e "$update_marker" ]]; then
    rm -f -- "$update_marker"
    check "update-path Git wrapper suppresses hooks" \
      git_safe -C "$update_checkout" checkout -q HEAD
    [[ ! -e "$update_marker" ]] \
      && pass "update-path Git wrapper did not execute post-checkout" \
      || fail "update-path Git wrapper executed post-checkout"
  else
    skip "Git version did not execute post-checkout in this checkout"
  fi

  if grep -q 'git_safe -C "$REPO_ROOT" pull' "$ACTUAL_REPO/scripts/update.sh" \
    && grep -q 'git_checkout_owned_by_user "$REPO_ROOT"' "$ACTUAL_REPO/scripts/update.sh"; then
    pass "update script uses the safe Git wrapper and ownership check"
  else
    fail "update script does not use the safe Git wrapper and ownership check"
  fi
else
  fail "git unavailable; zsh checkout security tests are mandatory"
fi

# ---------------------------------------------------------------------------
# M4: absolute sudo handling
# ---------------------------------------------------------------------------
note "# M4 sudo handling"

CAPTURE="$TEST_TMP/m4-capture"
export SUDO_CAPTURE="$CAPTURE"
SUDO_BIN="$TEST_TMP/fake-sudo"
cat >"$SUDO_BIN" <<'FAKE_SUDO'
#!/bin/sh
cap="${SUDO_CAPTURE:?}"
for arg in "$@"; do printf '%s\n' "$arg"; done >"$cap"
[ "$1" = "--" ] && shift
case "$1" in
  install)
    shift
    mode=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -D|-d) shift ;;
        -m*) mode="${1#-m}"; shift ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    src="$1"
    dst="$2"
    [ -n "$src" ] && [ -n "$dst" ] || exit 1
    mkdir -p -- "$(dirname -- "$dst")" || exit 1
    cp -- "$src" "$dst" || exit 1
    [ -n "$mode" ] && chmod "$mode" -- "$dst"
    exit 0
    ;;
  sha256sum)
    shift
    exec /usr/bin/sha256sum "$@"
    ;;
  *)
    exit 0
    ;;
esac
FAKE_SUDO
chmod 0755 "$SUDO_BIN"
check "absolute regular sudo binary is accepted" sudo_binary_valid

ln -s -- /usr/bin/true "$TEST_TMP/sudo-link"
SAVED_SUDO_BIN="$SUDO_BIN"
SUDO_BIN="$TEST_TMP/sudo-link"
expect_failure "symlinked sudo binary is rejected" sudo_binary_valid
SUDO_BIN="relative/sudo"
expect_failure "relative sudo binary is rejected" sudo_binary_valid
SUDO_BIN="$SAVED_SUDO_BIN"

rm -f -- "$CAPTURE"
check "run_sudo invokes the absolute binary with end-of-options" run_sudo echo hello
captured="$(cat "$CAPTURE" 2>/dev/null || true)"
expect_match "run_sudo passes -- before arguments" $'^--\necho\nhello$' "$captured"

marker="$TEST_TMP/m4-marker"
SUDO_BIN="$TEST_TMP/missing-sudo"
rm -f -- "$marker"
expect_failure "run_sudo fails closed when the binary is invalid" run_sudo touch "$marker"
[[ ! -e "$marker" ]] && pass "invalid sudo did not execute the command" || fail "invalid sudo executed the command"

mkdir -p "$TEST_TMP/m4-path"
printf '#!/bin/sh\ntouch %q\nexit 0\n' "$marker" >"$TEST_TMP/m4-path/sudo"
chmod 0755 "$TEST_TMP/m4-path/sudo"
rm -f -- "$marker"
SAVED_PATH="$PATH"
PATH="$TEST_TMP/m4-path:/usr/bin:/bin"
SUDO_BIN="$TEST_TMP/missing-sudo"
expect_failure "run_sudo does not fall back to PATH" run_sudo true
[[ ! -e "$marker" ]] && pass "PATH sudo was not executed" || fail "PATH sudo was executed"
PATH="$SAVED_PATH"

SUDO_BIN="$SAVED_SUDO_BIN"
rm -f -- "$CAPTURE"
DRY_RUN=0
check "platform_sudo_prepare uses the absolute sudo binary" platform_sudo_prepare
captured="$(cat "$CAPTURE" 2>/dev/null || true)"
expect_eq "platform_sudo_prepare probes sudo with -n true" $'-n\ntrue' "$captured"

platform_source="$(cat "$ACTUAL_REPO/lib/platform.sh")"
if [[ "$platform_source" != *"sudo -n"* && "$platform_source" != *"sudo -v"* ]]; then
  pass "platform.sh contains no PATH-resolved sudo calls"
else
  fail "platform.sh still contains PATH-resolved sudo calls"
fi

# ---------------------------------------------------------------------------
# M5: pinned repository keys and definitions
# ---------------------------------------------------------------------------
note "# M5 repository keys and definitions"

microsoft_key="$ACTUAL_REPO/platforms/fedora/keys/microsoft.asc"
brave_key="$ACTUAL_REPO/platforms/fedora/keys/brave-core.asc"

expect_eq "Microsoft key matches the pinned SHA-256" "$MICROSOFT_GPG_SHA256" "$(file_sha256 "$microsoft_key")"
expect_eq "Brave key matches the pinned SHA-256" "$BRAVE_GPG_SHA256" "$(file_sha256 "$brave_key")"
expect_eq "VS Code repository definition matches its pinned SHA-256" \
  "$VSCODE_REPO_SHA256" "$(file_sha256 "$ACTUAL_REPO/platforms/fedora/repos/vscode.repo")"
expect_eq "Brave repository definition matches its pinned SHA-256" \
  "$BRAVE_REPO_SHA256" "$(file_sha256 "$ACTUAL_REPO/platforms/fedora/repos/brave-browser.repo")"

vscode_repo="$(cat "$ACTUAL_REPO/platforms/fedora/repos/vscode.repo")"
brave_repo_file="$(cat "$ACTUAL_REPO/platforms/fedora/repos/brave-browser.repo")"
expect_match "VS Code repo uses a local key file" 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-microsoft' "$vscode_repo"
expect_match "Brave repo uses a local key file" 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-brave' "$brave_repo_file"
if [[ "$vscode_repo$brave_repo_file" != *"https://"*".asc"* ]]; then
  pass "repository definitions do not fetch replacement keys"
else
  fail "repository definitions still fetch remote key files"
fi

rm -f -- "$CAPTURE"
check "pinned Microsoft key installs successfully" \
  fedora_install_key microsoft "$microsoft_key" "$TEST_TMP/RPM-GPG-KEY-microsoft"
captured="$(cat "$CAPTURE" 2>/dev/null || true)"
expect_match "key install verifies the installed RPM GPG key" 'RPM-GPG-KEY-microsoft' "$captured"

tampered_key="$TEST_TMP/tampered-microsoft.asc"
cp -- "$microsoft_key" "$tampered_key"
printf '\n' >>"$tampered_key"
rm -f -- "$CAPTURE"
expect_failure_message "tampered repository key is rejected" 'pinned SHA-256' \
  fedora_install_key microsoft "$tampered_key" "$TEST_TMP/tampered-target"
[[ ! -e "$CAPTURE" ]] && pass "tampered key was not installed" || fail "tampered key was installed"

expect_failure "unknown repository key name is rejected" \
  fedora_install_key unknown "$microsoft_key" "$TEST_TMP/unknown-target"

# Fingerprint branch: mock gpg with a wrong and then the expected fingerprint.
gpg() {
  printf 'fpr:::::::::0000000000000000000000000000000000000000:\n'
}
expect_failure_message "wrong GPG fingerprint is rejected" 'fingerprint mismatch' \
  fedora_install_key microsoft "$microsoft_key" "$TEST_TMP/fpr-wrong-target"
unset -f gpg

gpg() {
  printf 'fpr:::::::::%s:\n' "$MICROSOFT_GPG_FINGERPRINT"
}
check "matching GPG fingerprint is accepted" \
  fedora_install_key microsoft "$microsoft_key" "$TEST_TMP/fpr-ok-target"
unset -f gpg

# Missing gpg: the SHA-256 pin still binds the key bytes.
ORIGINAL_HAVE_COMMAND="$(declare -f have_command)"
have_command() {
  [[ "$1" != "gpg" ]] && command -v "$1" >/dev/null 2>&1
}
check "key install proceeds with the SHA pin when gpg is unavailable" \
  fedora_install_key microsoft "$microsoft_key" "$TEST_TMP/nogpg-target"
eval "$ORIGINAL_HAVE_COMMAND"

# Post-install verification: a privileged copy that writes different bytes is
# rejected even though the source file matched the pin.
repo_source="$TEST_TMP/vscode.repo.test"
printf '[test]\nname=test\n' >"$repo_source"
repo_sha="$(file_sha256 "$repo_source")"

bad_sudo="$TEST_TMP/bad-install-sudo"
cat >"$bad_sudo" <<'BAD_SUDO'
#!/bin/sh
[ "$1" = "--" ] && shift
case "$1" in
  install)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -D|-d|-m*) shift ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    dst="$2"
    mkdir -p -- "$(dirname -- "$dst")" || exit 1
    printf 'tampered\n' >"$dst"
    exit 0
    ;;
  sha256sum)
    shift
    exec /usr/bin/sha256sum "$@"
    ;;
  rm)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --|-f) shift ;;
        *) break ;;
      esac
    done
    rm -f -- "$1"
    exit 0
    ;;
  *) exit 0 ;;
esac
BAD_SUDO
chmod 0755 "$bad_sudo"
SUDO_BIN="$bad_sudo"
expect_failure_message "post-install key hash mismatch is rejected" 'Installed repository key' \
  fedora_install_key microsoft "$microsoft_key" "$TEST_TMP/bad-installed-key"
[[ ! -e "$TEST_TMP/bad-installed-key" ]] \
  && pass "unpinned installed key was removed after verification failure" \
  || fail "unpinned installed key was left in place"
bad_repo_target="$TEST_TMP/etc/yum.repos.d/bad-installed.repo"
expect_failure_message "post-install repository hash mismatch is rejected" \
  'Installed repository definition' \
  dnf_repo_ensure "$repo_source" "$bad_repo_target" "$repo_sha"
[[ ! -e "$bad_repo_target" ]] \
  && pass "unpinned installed repository was removed after verification failure" \
  || fail "unpinned installed repository was left in place"
SUDO_BIN="$SAVED_SUDO_BIN"

# Repository definitions are hash-pinned before and after installation.
repo_source="$TEST_TMP/vscode.repo.test"
printf '[test]\nname=test\n' >"$repo_source"
repo_sha="$(file_sha256 "$repo_source")"
repo_target="$TEST_TMP/etc/yum.repos.d/vscode.repo"
check "hash-pinned repository definition installs" \
  dnf_repo_ensure "$repo_source" "$repo_target" "$repo_sha"
expect_eq "installed repository content matches the source" \
  "$(cat "$repo_source")" "$(cat "$repo_target")"
expect_failure_message "repository definition with a wrong pin is rejected" 'pinned SHA-256' \
  dnf_repo_ensure "$repo_source" "$TEST_TMP/etc/yum.repos.d/bad.repo" \
  "0000000000000000000000000000000000000000000000000000000000000000"
mkdir -p "$TEST_TMP/etc/yum.repos.d"
ln -s -- "$repo_source" "$TEST_TMP/etc/yum.repos.d/link.repo"
expect_failure_message "symlinked repository target is rejected" 'symlinked repository file' \
  dnf_repo_ensure "$repo_source" "$TEST_TMP/etc/yum.repos.d/link.repo" "$repo_sha"

# ---------------------------------------------------------------------------
# M6: mise, architecture selection, downloads and VS Code
# ---------------------------------------------------------------------------
note "# M6 mise, downloads and VS Code"

expect_match "mise binary checksum is pinned" '^[0-9a-f]{64}$' "$MISE_BIN_SHA256"
expect_match "VS Code ESLint version is pinned" '^[0-9]+\.[0-9]+\.[0-9]+$' "$VSCODE_ESLINT_VERSION"
expect_match "VS Code Prettier version is pinned" '^[0-9]+\.[0-9]+\.[0-9]+$' "$VSCODE_PRETTIER_VERSION"

extensions_ok=1
for extension in "${VSCODE_EXTENSIONS[@]}"; do
  case "$extension" in
    "dbaeumer.vscode-eslint@$VSCODE_ESLINT_VERSION") ;;
    "esbenp.prettier-vscode@$VSCODE_PRETTIER_VERSION") ;;
    *) extensions_ok=0 ;;
  esac
done
(( extensions_ok == 1 )) && pass "VS Code extensions include pinned versions" || fail "VS Code extension pins are missing"

SAVED_PLATFORM_ARCH="$PLATFORM_ARCH"
PLATFORM_ARCH="aarch64"
expect_failure "aarch64 is not supported for mise" mise_arch_supported
reset_failures
expect_failure_message "mise install fails closed on aarch64" 'linux-x64' mise_install_binary
PLATFORM_ARCH="x86_64"
check "x86_64 is supported for mise" mise_arch_supported
PLATFORM_ARCH="$SAVED_PLATFORM_ARCH"

MISE_BIN="$TEST_TMP/mise"
printf '#!/bin/sh\necho 2026.11.8\n' >"$MISE_BIN"
chmod 0755 "$MISE_BIN"
fake_mise_sha="$(file_sha256 "$MISE_BIN")"
SAVED_MISE_SHA="$MISE_BIN_SHA256"
MISE_BIN_SHA256="$fake_mise_sha"
check "mise binary with the pinned checksum is trusted" mise_binary_trusted

ln -s -- "$MISE_BIN" "$TEST_TMP/mise-link"
SAVED_MISE_BIN="$MISE_BIN"
MISE_BIN="$TEST_TMP/mise-link"
expect_failure "symlinked mise binary is not trusted" mise_binary_trusted
MISE_BIN="$SAVED_MISE_BIN"

MISE_BIN_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
expect_failure "mise binary with a wrong checksum is not trusted" mise_binary_trusted
MISE_BIN_SHA256="$SAVED_MISE_SHA"

ORIGINAL_PARSE_RUNTIMES="$(declare -f parse_runtimes)"
ORIGINAL_MISE_TRUSTED="$(declare -f mise_binary_trusted)"
ORIGINAL_MISE_RUN="$(declare -f mise_run)"

parse_runtimes() { printf 'node latest\n'; }
mise_binary_trusted() { return 0; }
mise_run() { printf 'v26.13.0\n'; }
reset_failures
expect_failure "mise runtime verification rejects non-exact pins" mise_verify_runtimes

parse_runtimes() { printf 'node 26.13.0\n'; }
reset_failures
check "mise runtime verification accepts an exact version" mise_verify_runtimes
eval "$ORIGINAL_PARSE_RUNTIMES"
eval "$ORIGINAL_MISE_TRUSTED"
eval "$ORIGINAL_MISE_RUN"

# download_verify: checksum mismatch and success, using a fake curl.
mkdir -p "$TEST_TMP/fakebin"
cat >"$TEST_TMP/fakebin/curl" <<'FAKE_CURL'
#!/bin/sh
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--output" ]; then out="$arg"; fi
  prev="$arg"
done
[ -n "$out" ] || exit 1
printf 'downloaded-payload' >"$out"
FAKE_CURL
chmod 0755 "$TEST_TMP/fakebin/curl"
SAVED_PATH="$PATH"
PATH="$TEST_TMP/fakebin:$PATH"
download_target="$TEST_TMP/download.bin"
expect_failure_message "download_verify rejects a checksum mismatch" 'Checksum mismatch' \
  download_verify "https://example.invalid/asset" "$download_target" \
  "0000000000000000000000000000000000000000000000000000000000000000"
good_download_sha="$(printf 'downloaded-payload' | sha256sum | awk '{ print $1 }')"
check "download_verify accepts a matching checksum" \
  download_verify "https://example.invalid/asset" "$download_target" "$good_download_sha"
PATH="$SAVED_PATH"

# ---------------------------------------------------------------------------
# LOW: lifecycle, state safety, atomic files, listing and user validation
# ---------------------------------------------------------------------------
note "# LOW hardening"

settings="$(cat "$ACTUAL_REPO/config/settings.conf")"
if grep -qx 'ENABLE_DATABASE_SERVICES=0' <<<"$settings"; then
  pass "database services default to opt-in"
else
  fail "database services default to opt-in"
fi
if grep -qx 'ENABLE_VIRTUALIZATION_SERVICES=0' <<<"$settings"; then
  pass "virtualization services default to opt-in"
else
  fail "virtualization services default to opt-in"
fi
if grep -qx 'INSTALL_OPTIONAL_APPS=0' <<<"$settings"; then
  pass "optional applications default to opt-in"
else
  fail "optional applications default to opt-in"
fi

fedora_min="$(grep -oE '^FEDORA_MIN_VERSION=[0-9]+' "$ACTUAL_REPO/platforms/fedora/platform.conf" | cut -d= -f2)"
if [[ "$fedora_min" =~ ^[0-9]+$ ]] && (( fedora_min >= 43 )); then
  pass "minimum Fedora release reflects a supported lifecycle"
else
  fail "minimum Fedora release is not updated (found '${fedora_min:-none}')"
fi

if ! grep -q 'termbin' "$ACTUAL_REPO/dotfiles/home/.zshrc"; then
  pass "termbin alias is absent from managed zshrc"
else
  fail "termbin alias is still present in managed zshrc"
fi

if ! grep -qE 'zsh[[:space:]]+-lic' "$ACTUAL_REPO/scripts/doctor.sh"; then
  pass "doctor does not execute user startup files"
else
  fail "doctor still executes user startup files"
fi

if grep -q '\-L "$path/\.git"' "$ACTUAL_REPO/scripts/doctor.sh"; then
  pass "doctor rejects symlinked Git metadata in managed checkouts"
else
  fail "doctor does not reject symlinked Git metadata in managed checkouts"
fi

if grep -q 'git_safe' "$ACTUAL_REPO/installers/zsh.sh" \
  && grep -q 'git_safe' "$ACTUAL_REPO/scripts/doctor.sh" \
  && grep -q 'core.fsmonitor=false' "$ACTUAL_REPO/lib/common.sh"; then
  pass "Git inspections disable core.fsmonitor"
else
  fail "Git inspections do not disable core.fsmonitor"
fi

# Execute doctor's checkout inspection with a malicious fsmonitor config.
if command -v git >/dev/null 2>&1; then
  doctor_repo="$TEST_TMP/doctor-repo"
  if fixture "copy repository for doctor test" cp -a -- "$ROOT" "$doctor_repo"; then
    doctor_home="$TEST_TMP/doctor-home"
    doctor_omz="$doctor_home/.oh-my-zsh"
    mkdir -p "$doctor_home"
    if fixture "initialize doctor checkout" git init -q "$doctor_omz" \
      && fixture "configure doctor checkout identity" \
        git -C "$doctor_omz" config user.email "test@example.invalid" \
      && fixture "configure doctor checkout name" \
        git -C "$doctor_omz" config user.name "Test"; then
      printf 'doctor\n' >"$doctor_omz/file"
      fixture "stage doctor checkout file" git -C "$doctor_omz" add file
      fixture "commit doctor checkout" git -C "$doctor_omz" commit -q -m one
      doctor_commit="$(git -C "$doctor_omz" rev-parse HEAD)"
      sed -i \
        -e "s/^OH_MY_ZSH_COMMIT=.*/OH_MY_ZSH_COMMIT=$doctor_commit/" \
        -e "s/^P10K_COMMIT=.*/P10K_COMMIT=$doctor_commit/" \
        -e "s/^HISTORY_SUBSTRING_COMMIT=.*/HISTORY_SUBSTRING_COMMIT=$doctor_commit/" \
        "$doctor_repo/config/pins.conf"
      doctor_marker="$TEST_TMP/doctor-fsmonitor-executed"
      doctor_hook="$TEST_TMP/doctor-fsmonitor-hook"
      printf '#!/bin/sh\ntouch %q\nexit 0\n' "$doctor_marker" >"$doctor_hook"
      chmod 0755 "$doctor_hook"
      git -C "$doctor_omz" config core.fsmonitor "$doctor_hook"
      rm -f -- "$doctor_marker"
      GIT_OPTIONAL_LOCKS=0 git -C "$doctor_omz" status --porcelain >/dev/null 2>&1 || true
      if [[ -e "$doctor_marker" ]]; then
        rm -f -- "$doctor_marker"
        doctor_output="$(
          XDG_STATE_HOME="$TEST_TMP/doctor-state" \
          DEV_SETUP_TARGET_HOME="$doctor_home" \
          "$doctor_repo/scripts/doctor.sh" 2>&1
        )" || true
        if grep -q 'Oh My Zsh' <<<"$doctor_output"; then
          pass "doctor reached the managed checkout inspection"
        else
          fail "doctor did not reach the managed checkout inspection"
        fi
        [[ ! -e "$doctor_marker" ]] \
          && pass "doctor did not execute a malicious core.fsmonitor" \
          || fail "doctor executed a malicious core.fsmonitor"
      else
        skip "Git version does not execute path-valued core.fsmonitor for doctor"
      fi
    else
      fail "could not prepare the doctor checkout fixture"
    fi
  fi
else
  fail "git unavailable; doctor Git security test is mandatory"
fi

# Execute the actual update path against a temporary checkout and origin.
if command -v git >/dev/null 2>&1; then
  update_repo="$TEST_TMP/update-repo"
  update_bare="$TEST_TMP/update-origin.git"
  update_work="$TEST_TMP/update-work"
  update_home="$TEST_TMP/update-home"
  update_marker="$TEST_TMP/update-fsmonitor-executed"
  if fixture "copy repository for update test" cp -a -- "$ROOT" "$update_repo" \
    && fixture "initialize update origin" git init --bare -q "$update_bare" \
    && fixture "configure update checkout identity" \
      git -C "$update_repo" config user.email "test@example.invalid" \
    && fixture "configure update checkout name" \
      git -C "$update_repo" config user.name "Test" \
    && fixture "create update branch" git -C "$update_repo" checkout -q -B main \
    && fixture "stage update fixture" git -C "$update_repo" add -A \
    && fixture "commit update fixture" git -C "$update_repo" commit -q -m "test snapshot"; then
    update_base="$(git -C "$update_repo" rev-parse HEAD)"
    git -C "$update_repo" remote set-url origin "$update_bare"
    fixture "push update base" git -C "$update_repo" push -q -u origin main
    git -C "$update_bare" symbolic-ref HEAD refs/heads/main
    fixture "clone update work" git clone -q "$update_bare" "$update_work"
    git -C "$update_work" config user.email "test@example.invalid"
    git -C "$update_work" config user.name "Test"
    printf 'update-work\n' >>"$update_work/README.md"
    if fixture "commit update work" git -C "$update_work" commit -q -am "next" \
      && fixture "push update work" git -C "$update_work" push -q origin main; then
      git -C "$update_repo" fetch -q origin
      git -C "$update_repo" reset --hard -q "$update_base"
      update_hook="$TEST_TMP/update-fsmonitor-hook"
      printf '#!/bin/sh\ntouch %q\nexit 0\n' "$update_marker" >"$update_hook"
      chmod 0755 "$update_hook"
      git -C "$update_repo" config core.fsmonitor "$update_hook"
      printf '#!/bin/sh\ntouch %q\nexit 0\n' "$update_marker" \
        >"$update_repo/.git/hooks/post-merge"
      chmod 0755 "$update_repo/.git/hooks/post-merge"
      rm -f -- "$update_marker"
      git -C "$update_repo" pull --ff-only >/dev/null 2>&1 || true
      if [[ -e "$update_marker" ]]; then
        rm -f -- "$update_marker"
        git -C "$update_repo" reset --hard -q "$update_base" >/dev/null 2>&1 || true
        # reset --hard can itself consult fsmonitor; clear the marker again so
        # the following assertion measures only the update script.
        rm -f -- "$update_marker"
        mkdir -p "$update_home"
        update_output="$(
          XDG_STATE_HOME="$TEST_TMP/update-state" \
          DEV_SETUP_TARGET_HOME="$update_home" \
          "$update_repo/scripts/update.sh" --skip-packages --skip-runtimes 2>&1
        )" || true
        if [[ ! -e "$update_marker" ]]; then
          pass "update script did not execute malicious Git configuration"
        else
          fail "update script executed malicious Git configuration"
        fi
        if grep -q 'Refusing to update' <<<"$update_output"; then
          pass "update script refuses a checkout with unsafe local Git configuration"
        else
          fail "update script did not refuse unsafe local Git configuration"
        fi
        git -C "$update_repo" config --unset core.fsmonitor || true
        rm -f -- "$update_repo/.git/hooks/post-merge"
        update_output="$(
          XDG_STATE_HOME="$TEST_TMP/update-state" \
          DEV_SETUP_TARGET_HOME="$update_home" \
          "$update_repo/scripts/update.sh" --skip-packages --skip-runtimes 2>&1
        )" || true
        if grep -q 'Updated the system-init Git checkout' <<<"$update_output"; then
          pass "update script completes a clean fast-forward"
        else
          fail "update script did not complete a clean fast-forward"
        fi
      else
        skip "Git version did not execute the update-path command vector"
      fi
    else
      fail "could not prepare the update origin commit"
    fi
  fi
else
  fail "git unavailable; update security test is mandatory"
fi

for valid_user in "$(id -un)" "dev-user_1" "a.b"; do
  check "valid target user '$valid_user' is accepted" target_user_is_valid "$valid_user"
done
for invalid_user in "" "-R" "--help" "a b" "user;id" "../root"; do
  expect_failure "invalid target user '$invalid_user' is rejected" \
    target_user_is_valid "$invalid_user"
done
reset_failures
TARGET_USER="-R"
expect_failure_message "login-shell change rejects an option-like target user" 'Invalid target user' \
  zsh_set_login_shell
TARGET_USER="$(id -un)"

STATE_DIR="$TEST_TMP/state/system-init"
mkdir -p "$STATE_DIR"
check "normal state directory is safe to purge" state_dir_is_safe
ln -s -- "$TEST_TMP/state" "$TEST_TMP/state-link"
STATE_DIR="$TEST_TMP/state-link/system-init"
expect_failure "symlinked state directory is not safe to purge" state_dir_is_safe
mkdir -p "$TEST_TMP/state/not-system-init"
STATE_DIR="$TEST_TMP/state/not-system-init"
expect_failure "unexpected state directory name is not safe to purge" state_dir_is_safe
STATE_DIR="$TEST_TMP/state/system-init"

# Symlinked XDG_STATE_HOME and HOME are canonicalised at library load time.
real_state="$TEST_TMP/real-state"
mkdir -p "$real_state"
ln -s -- "$real_state" "$TEST_TMP/state-link2"
state_result="$(XDG_STATE_HOME="$TEST_TMP/state-link2" \
  DEV_SETUP_TARGET_HOME="$TEST_TMP/h3-home" \
  bash -c 'source "$1/lib/common.sh"; printf "%s" "$STATE_DIR"; init_private_dir "$STATE_DIR" && printf ":ok"' \
  _ "$ROOT" 2>>"$TEST_LOG")"
expect_eq "symlinked XDG_STATE_HOME is canonicalised and usable" \
  "$(realpath -e -- "$real_state")/system-init:ok" "$state_result"

home_state_result="$(DEV_SETUP_TARGET_HOME="$h3_link_home" \
  bash -c 'source "$1/lib/common.sh"; printf "%s" "$STATE_DIR"; init_private_dir "$STATE_DIR" && printf ":ok"' \
  _ "$ROOT" 2>>"$TEST_LOG")"
expect_eq "symlinked HOME state directory is canonicalised and usable" \
  "$(realpath -e -- "$h3_real_home")/.local/state/system-init:ok" "$home_state_result"

saved_home_for_state="$TARGET_HOME"
TARGET_HOME="$TEST_TMP/no-such-home"
STATE_DIR="$TEST_TMP/no-such-state/system-init"
expect_failure_message "state init refuses a missing target home" \
  'unsafe or missing target home' init_state_dirs
[[ ! -e "$TEST_TMP/no-such-home" ]] \
  && pass "state init did not create a missing target home" \
  || fail "state init created a missing target home"
[[ ! -e "$TEST_TMP/no-such-state" ]] \
  && pass "state init did not create state for a missing target home" \
  || fail "state init created state for a missing target home"
TARGET_HOME="$saved_home_for_state"
STATE_DIR="$TEST_TMP/state/system-init"

# Atomic private file creation replaces a planted symlink instead of following it.
victim="$TEST_TMP/atomic-victim"
printf 'secret\n' >"$victim"
planted="$TEST_TMP/atomic-link"
ln -s -- "$victim" "$planted"
printf 'replacement\n' | write_private_file "$planted"
expect_eq "atomic state write does not follow a planted symlink" "secret" "$(cat "$victim")"
expect_eq "atomic state write replaces the symlink with a regular file" \
  "replacement" "$(cat "$planted")"
[[ ! -L "$planted" ]] && pass "state marker is no longer a symlink" || fail "state marker is still a symlink"
expect_failure "write_private_file rejects a relative path" write_private_file "relative/file"

# A symlink to a directory must be replaced, not followed by mv.
atomic_dir="$TEST_TMP/atomic-target-dir"
atomic_dir_link="$TEST_TMP/atomic-dir-link"
mkdir -p "$atomic_dir"
ln -s -- "$atomic_dir" "$atomic_dir_link"
printf 'dir-replacement\n' | write_private_file "$atomic_dir_link"
expect_eq "state write replaces a symlink-to-directory" "dir-replacement" "$(cat "$atomic_dir_link")"
[[ ! -L "$atomic_dir_link" ]] \
  && pass "symlink-to-directory was replaced by a regular file" \
  || fail "symlink-to-directory was not replaced"
[[ -z "$(find "$atomic_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  && pass "state write did not move the temporary file into the target directory" \
  || fail "state write moved the temporary file into the target directory"

# Restore normalizes mode and does not apply ACLs/xattrs from the snapshot.
acl_home="$TEST_TMP/acl-home"
mkdir -p "$acl_home"
printf 'acl-content\n' >"$acl_home/.zshrc"
chmod 0644 "$acl_home/.zshrc"
acl_ok=0
if have_command setfacl && have_command getfacl && getent passwd nobody >/dev/null 2>&1; then
  if setfacl -m u:nobody:r-- "$acl_home/.zshrc" >/dev/null 2>&1 \
    && getfacl -p "$acl_home/.zshrc" 2>/dev/null | grep -q '^user:nobody:'; then
    acl_ok=1
  fi
fi
xattr_ok=0
if have_command setfattr && have_command getfattr; then
  if setfattr -n user.system_init_test -v secret "$acl_home/.zshrc" >/dev/null 2>&1 \
    && getfattr -d "$acl_home/.zshrc" 2>/dev/null | grep -q 'user.system_init_test'; then
    xattr_ok=1
  fi
fi
if (( acl_ok == 1 || xattr_ok == 1 )); then
  saved_target_home="$TARGET_HOME"
  saved_backup_dir="$BACKUP_DIR"
  TARGET_HOME="$acl_home"
  BACKUP_DIR="$TEST_TMP/acl-snapshots"
  mkdir -p "$BACKUP_DIR"
  BACKUP_RUN_DIR=""
  RESTORE_ALLOW_UNSIGNED_SAVED="$RESTORE_ALLOW_UNSIGNED"
  (( GPG_TESTS == 0 )) && RESTORE_ALLOW_UNSIGNED=1
  check "backup captures a file with ACLs/xattrs" backup_path "$acl_home/.zshrc"
  check "ACL/xattr backup finalizes" backup_finalize
  printf 'changed\n' >"$acl_home/.zshrc"
  check "restore normalizes ACL/xattr-bearing files" \
    backup_restore_snapshot "$BACKUP_RUN_DIR"
  RESTORE_ALLOW_UNSIGNED="$RESTORE_ALLOW_UNSIGNED_SAVED"
  expect_eq "restored ACL/xattr file content" "acl-content" "$(cat "$acl_home/.zshrc")"
  expect_eq "restored mode is normalized" "600" "$(stat -c '%a' "$acl_home/.zshrc")"
  if (( acl_ok == 1 )); then
    if getfacl -p "$acl_home/.zshrc" 2>/dev/null | grep -q '^user:nobody:'; then
      fail "restore applied an ACL from the snapshot"
    else
      pass "restore stripped the snapshot ACL"
    fi
  fi
  if (( xattr_ok == 1 )); then
    if getfattr -d "$acl_home/.zshrc" 2>/dev/null | grep -q 'user.system_init_test'; then
      fail "restore applied an xattr from the snapshot"
    else
      pass "restore stripped the snapshot xattr"
    fi
  fi
  BACKUP_RUN_DIR=""
  TARGET_HOME="$saved_target_home"
  BACKUP_DIR="$saved_backup_dir"
else
  skip "setfacl/setfattr unavailable or unsupported; ACL/xattr restore test skipped"
fi

# Snapshot names are validated and pruning is ordered by name, not mtime.
check "valid snapshot name is accepted" backup_snapshot_name_is_valid "20260101T000000Z-2"
for invalid_name in "good-snapshot" "2026010T000000Z" "../20260101T000000Z" "99999999T999999Z" "20991231T235959Z" ""; do
  expect_failure "invalid snapshot name '$invalid_name' is rejected" \
    backup_snapshot_name_is_valid "$invalid_name"
done

prune_dir="$TEST_TMP/prune-backups"
for prune_name in 20260101T000000Z 20260102T000000Z 20260103T000000Z; do
  mkdir -p "$prune_dir/$prune_name/files"
  printf '%s\t%s\tfile\n' "/tmp/payload" "$prune_dir/$prune_name/files/payload" \
    >"$prune_dir/$prune_name/manifest.tsv"
  printf 'created=test\n' >"$prune_dir/$prune_name/metadata.conf"
done
mkdir -p "$prune_dir/not-a-snapshot"
mkdir -p "$prune_dir/99999999T999999Z/files"
printf '%s\t%s\tfile\n' "/tmp/payload" "$prune_dir/99999999T999999Z/files/payload" \
  >"$prune_dir/99999999T999999Z/manifest.tsv"
printf 'created=test\n' >"$prune_dir/99999999T999999Z/metadata.conf"
touch -d '2099-01-01' "$prune_dir/20260101T000000Z"
touch -d '2099-01-01' "$prune_dir/not-a-snapshot"
BACKUP_DIR="$prune_dir"
DOTFILES_BACKUP_KEEP=2
DRY_RUN=0
prune_backups >>"$TEST_LOG" 2>&1
remaining="$(find "$prune_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)"
expect_eq "backup pruning keeps two valid snapshots plus invalid entries" "4" "$((remaining + 0))"
[[ -d "$prune_dir/20260102T000000Z" && -d "$prune_dir/20260103T000000Z" ]] \
  && pass "name ordering retained the newest valid snapshots" \
  || fail "name ordering did not retain the newest valid snapshots"
[[ ! -d "$prune_dir/20260101T000000Z" ]] \
  && pass "manipulated mtime did not protect the oldest snapshot" \
  || fail "manipulated mtime protected the oldest snapshot"
[[ -d "$prune_dir/not-a-snapshot" ]] \
  && pass "invalid snapshot name was not pruned" \
  || fail "invalid snapshot name was pruned"

# Metadata listing sanitises terminal control characters and skips symlinks.
list_state="$TEST_TMP/list-state"
list_snap="$list_state/system-init/backups/20260101T000000Z"
mkdir -p "$list_snap/files"
: >"$list_snap/manifest.tsv"
printf 'created=test\nreason=\033[31mEVIL\033[0m\n' >"$list_snap/metadata.conf"
list_output="$(XDG_STATE_HOME="$list_state" "$ROOT/scripts/restore.sh" --list 2>&1)" || true
if [[ "$list_output" == *$'\033'* ]]; then
  fail "restore --list emitted terminal control characters"
else
  pass "restore --list strips terminal control characters"
fi
if [[ "$list_output" == *'reason=[31mEVIL[0m'* ]]; then
  pass "restore --list shows the sanitised metadata value"
else
  fail "restore --list did not show the sanitised metadata value"
fi
if [[ "$list_output" == *'status: legacy-empty'* ]]; then
  pass "restore --list labels empty legacy snapshots"
else
  fail "restore --list did not label the empty legacy snapshot"
fi

list_snap2="$list_state/system-init/backups/20260102T000000Z"
mkdir -p "$list_snap2/files"
: >"$list_snap2/manifest.tsv"
printf 'SECRET-METADATA\n' >"$TEST_TMP/list-secret"
ln -s -- "$TEST_TMP/list-secret" "$list_snap2/metadata.conf"
list_output2="$(XDG_STATE_HOME="$list_state" "$ROOT/scripts/restore.sh" --list 2>&1)" || true
if [[ "$list_output2" == *'SECRET-METADATA'* ]]; then
  fail "restore --list followed a symlinked metadata file"
else
  pass "restore --list does not follow a symlinked metadata file"
fi

invalid_snap="$list_state/system-init/backups/20260103T000000Z"
mkdir -p "$invalid_snap/files"
ln -s -- "$TEST_TMP/list-secret" "$invalid_snap/manifest.tsv"
list_output3="$(XDG_STATE_HOME="$list_state" "$ROOT/scripts/restore.sh" --list 2>&1)" || true
if [[ "$list_output3" == *'invalid snapshot'* ]]; then
  pass "restore --list reports invalid snapshots without reading them"
else
  fail "restore --list did not report the invalid snapshot"
fi

# restore --list must label signed, unsigned and invalid v2 snapshots.
list_v2_home="$TEST_TMP/list-v2-home"
mkdir -p "$list_v2_home"
printf 'list-v2-content\n' >"$list_v2_home/.zshrc"
saved_target_home="$TARGET_HOME"
saved_backup_dir="$BACKUP_DIR"
TARGET_HOME="$list_v2_home"
BACKUP_DIR="$TEST_TMP/list-v2-snapshots"
mkdir -p "$BACKUP_DIR"
BACKUP_RUN_DIR=""
check "v2 list fixture backup" backup_path "$list_v2_home/.zshrc"
check "v2 list fixture finalizes" backup_finalize
cp -a -- "$BACKUP_RUN_DIR" "$list_state/system-init/backups/20260104T000000Z"
list_output4="$(XDG_STATE_HOME="$list_state" "$ROOT/scripts/restore.sh" --list 2>&1)" || true
if (( GPG_TESTS == 1 )); then
  [[ "$list_output4" == *'status: signed'* ]] \
    && pass "restore --list labels signed v2 snapshots" \
    || fail "restore --list did not label the signed v2 snapshot"
else
  [[ "$list_output4" == *'status: unsigned-v2'* ]] \
    && pass "restore --list labels unsigned v2 snapshots" \
    || fail "restore --list did not label the unsigned v2 snapshot"
fi

invalid_v2_dir="$list_state/system-init/backups/20260105T000000Z"
cp -a -- "$BACKUP_RUN_DIR" "$invalid_v2_dir"
printf 'not-a-manifest\n' >"$invalid_v2_dir/manifest.v2"
rm -f -- "$invalid_v2_dir/manifest.v2.sig"
list_output5="$(XDG_STATE_HOME="$list_state" "$ROOT/scripts/restore.sh" --list 2>&1)" || true
[[ "$list_output5" == *'status: invalid-v2'* ]] \
  && pass "restore --list labels invalid v2 snapshots" \
  || fail "restore --list did not label the invalid v2 snapshot"

if (( GPG_TESTS == 1 )); then
  invalid_sig_dir="$list_state/system-init/backups/20260106T000000Z"
  cp -a -- "$BACKUP_RUN_DIR" "$invalid_sig_dir"
  printf 'not-a-signature\n' >"$invalid_sig_dir/manifest.v2.sig"
  list_output6="$(XDG_STATE_HOME="$list_state" "$ROOT/scripts/restore.sh" --list 2>&1)" || true
  [[ "$list_output6" == *'status: invalid-signature'* ]] \
    && pass "restore --list labels invalid signatures" \
    || fail "restore --list did not label the invalid signature"
fi
TARGET_HOME="$saved_target_home"
BACKUP_DIR="$saved_backup_dir"
BACKUP_RUN_DIR=""

if grep -q 'Skipping managed dotfile removal because backup restoration' \
  "$ACTUAL_REPO/uninstall.sh"; then
  pass "uninstall skips dotfile removal when restore fails"
else
  fail "uninstall does not guard dotfile removal after a restore failure"
fi

# Execute the uninstall restore-abort path with temporary state and home only.
uninstall_home="$TEST_TMP/uninstall-home"
uninstall_state="$TEST_TMP/uninstall-state"
uninstall_snap="$uninstall_state/system-init/backups/20260101T000000Z"
mkdir -p "$uninstall_home" "$uninstall_snap/files$uninstall_home"
printf 'uninstall-original\n' >"$uninstall_home/.zshrc"
printf 'snapshot-content\n' >"$uninstall_snap/files$uninstall_home/.zshrc"
printf '%s\t%s\tfile\n' "$uninstall_home/.zshrc" \
  "$uninstall_snap/files$uninstall_home/.zshrc" >"$uninstall_snap/manifest.tsv"
printf 'created=test\n' >"$uninstall_snap/metadata.conf"
uninstall_output="$(
  XDG_STATE_HOME="$uninstall_state" \
  DEV_SETUP_TARGET_HOME="$uninstall_home" \
  "$ROOT/uninstall.sh" --dry-run --restore-backups 2>&1
)" || true
if grep -q 'Skipping managed dotfile removal because backup restoration' <<<"$uninstall_output"; then
  pass "uninstall actually aborts dotfile removal after a restore failure"
else
  fail "uninstall did not abort dotfile removal after a restore failure"
fi
if grep -q 'Legacy v1 snapshot' <<<"$uninstall_output"; then
  pass "uninstall requires explicit legacy policy for v1 snapshots"
else
  fail "uninstall did not reject the legacy snapshot by default"
fi
[[ -f "$uninstall_home/.zshrc" ]] \
  && pass "uninstall dry-run left the managed file untouched" \
  || fail "uninstall dry-run removed the managed file"

# ---------------------------------------------------------------------------
# Remediation regression tests
# ---------------------------------------------------------------------------
note "# Remediation F-01..F-17"

REM_ROOT=""
rem_setup() {
  REM_ROOT="$(mktemp -d "$TEST_TMP/rem.XXXXXXXX")"
  TARGET_HOME="$REM_ROOT/home"
  STATE_DIR="$REM_ROOT/state/system-init"
  LOG_DIR="$STATE_DIR/logs"
  BACKUP_DIR="$STATE_DIR/backups"
  JOURNAL_DIR="$STATE_DIR/journal"
  mkdir -p "$TARGET_HOME"
  state_lock_release
  init_private_dir "$STATE_DIR" || return 1
  init_private_dir "$LOG_DIR" || return 1
  init_private_dir "$BACKUP_DIR" || return 1
  init_private_dir "$JOURNAL_DIR" || return 1
  REPO_ROOT="$ACTUAL_REPO"
  TARGET_USER="$(id -un)"
  DRY_RUN=0
  BACKUP_RUN_DIR=""
  BACKUP_ENTRIES=()
  BACKUP_ENTRY_COUNT=0
  BACKUP_SOURCE_PATHS=()
  BACKUP_SNAPSHOT_COMPLETE=0
  RESTORE_ALLOW_LEGACY=0
  RESTORE_ALLOW_UNSIGNED=0
}

rem_v2_snapshot() {
  local content="${1:-benign}"
  printf '%s\n' "$content" >"$TARGET_HOME/.zshrc"
  backup_init "rem-test" >/dev/null || return 1
  backup_path "$TARGET_HOME/.zshrc" "dotfile" >/dev/null || return 1
  backup_finalize >/dev/null || return 1
  REM_SNAPSHOT="$BACKUP_RUN_DIR"
}

rem_stage() {
  local name="${1:-stage}"
  local stage="$TARGET_HOME/.system-init-restore.$name"
  mkdir -p "$stage" || return 1
  chmod 700 "$stage" || return 1
  printf '%s\n' "$stage"
}

rem_journal() {
  local status="$1"
  local dest="$2"
  local stage="$3"
  local had_old="${4:-0}"
  local journal
  init_private_dir "$JOURNAL_DIR" || return 1
  journal="$(mktemp -- "$JOURNAL_DIR/restore-XXXXXXXX.journal")" || return 1
  printf '%s\t%s\t%s\t%s\n' "$status" "$dest" "$stage" "$had_old" >"$journal"
  chmod 600 -- "$journal"
  printf '%s\n' "$journal"
}

# --- F-01 signing oracle ----------------------------------------------------
rem_setup
rem_v2_snapshot "oracle-benign"
rem_snap="$REM_SNAPSHOT"
printf 'ATTACKER-ORACLE\n' >"$rem_snap/files/.gitconfig"
oracle_size="$(stat -c '%s' "$rem_snap/files/.gitconfig")"
oracle_sha="$(file_sha256 "$rem_snap/files/.gitconfig")"
printf '.gitconfig\tfile\t%s\t%s\t0600\tfiles/.gitconfig\t-\n' "$oracle_size" "$oracle_sha" \
  >"$rem_snap/.manifest.v2.entries"
check "F-01: rebuild ignores attacker-controlled raw manifest entries" backup_manifest_rebuild
if grep -Fq $'.gitconfig\tfile\t' "$rem_snap/manifest.v2"; then
  fail "F-01: attacker entry obtained a signature"
else
  pass "F-01: attacker entry did not enter the signed manifest"
fi
check "F-01: signed snapshot still verifies after raw-file injection" \
  backup_signature_verify "$rem_snap/manifest.v2" "$rem_snap/manifest.v2.sig"

rem_setup
printf 'accumulating\n' >"$TARGET_HOME/.zshrc"
backup_init "rem-accumulate" >/dev/null
backup_path "$TARGET_HOME/.zshrc" "dotfile" >/dev/null
if [[ ! -e "$BACKUP_RUN_DIR/manifest.v2" ]]; then
  pass "F-01: accumulating entries does not publish a manifest"
else
  fail "F-01: accumulation published a manifest before finalization"
fi
check "F-01: accumulation finalizes into a signed manifest" backup_finalize
rem_setup
mkdir -p "$TARGET_HOME/.config/btop"
printf 'staged-source\n' >"$TARGET_HOME/.config/btop/btop.conf"
backup_init "rem-payload-link" >/dev/null
mkdir -p "$REM_ROOT/payload-evil"
ln -s -- "$REM_ROOT/payload-evil" "$BACKUP_RUN_DIR/files/.config"
expect_failure_message "F-01: symlinked snapshot payload parent is rejected" \
  'symlinked snapshot payload parent' backup_path "$TARGET_HOME/.config/btop/btop.conf" dotfile
[[ ! -e "$REM_ROOT/payload-evil/btop/btop.conf" ]] \
  && pass "F-01: payload symlink did not receive backup data" \
  || fail "F-01: payload symlink received backup data"
rem_setup
printf 'late-zshrc\n' >"$TARGET_HOME/.zshrc"
backup_init "rem-post-finalize" >/dev/null
backup_path "$TARGET_HOME/.zshrc" "dotfile" >/dev/null
backup_finalize >/dev/null
printf 'late-gitconfig\n' >"$TARGET_HOME/.gitconfig"
check "F-01: post-finalize conflict is persisted" \
  backup_path "$TARGET_HOME/.gitconfig" "dotfile"
if grep -Fq $'.gitconfig\tfile\t' "$BACKUP_RUN_DIR/manifest.v2"; then
  pass "F-01: post-finalize entry is in the signed manifest"
else
  fail "F-01: post-finalize entry was not added to the signed manifest"
fi
printf 'changed\n' >"$TARGET_HOME/.gitconfig"
check "F-01: post-finalize backup can be restored" backup_restore_snapshot "$BACKUP_RUN_DIR"
expect_eq "F-01: post-finalize restore content" "late-gitconfig" "$(cat "$TARGET_HOME/.gitconfig")"

rem_setup
printf 'before-race\n' >"$TARGET_HOME/.zshrc"
backup_init "rem-race" >/dev/null
backup_path "$TARGET_HOME/.zshrc" "dotfile" >/dev/null
backup_finalize >/dev/null
printf 'after-race\n' >"$TARGET_HOME/.zshrc"
expect_failure_message "F-01: changed source after backup is refused, not overwritten" \
  'changed after it was backed up' backup_path "$TARGET_HOME/.zshrc" "dotfile"
expect_eq "F-01: concurrent source change preserved" "after-race" "$(cat "$TARGET_HOME/.zshrc")"

rem_setup
printf 'stable-before\n' >"$TARGET_HOME/.zshrc"
backup_init "rem-preserve-old" >/dev/null
backup_path "$TARGET_HOME/.zshrc" "dotfile" >/dev/null
backup_finalize >/dev/null
old_manifest_sha="$(file_sha256 "$BACKUP_RUN_DIR/manifest.v2")"
old_signing_key="$BACKUP_SIGNING_KEY"
printf 'new-conflict\n' >"$TARGET_HOME/.gitconfig"
BACKUP_SIGNING_KEY="0000000000000000000000000000000000000000"
expect_failure "F-01: failed re-finalization does not destroy the old manifest" \
  backup_path "$TARGET_HOME/.gitconfig" "dotfile"
BACKUP_SIGNING_KEY="$old_signing_key"
expect_eq "F-01: previous signed manifest bytes preserved" "$old_manifest_sha" \
  "$(file_sha256 "$BACKUP_RUN_DIR/manifest.v2")"
printf 'changed-after\n' >"$TARGET_HOME/.zshrc"
check "F-01: previous snapshot still restores after a failed re-finalization" \
  backup_restore_snapshot "$BACKUP_RUN_DIR"
expect_eq "F-01: previous snapshot content preserved" "stable-before" "$(cat "$TARGET_HOME/.zshrc")"
check "F-01: retry after failed publication succeeds" \
  backup_path "$TARGET_HOME/.gitconfig" "dotfile"
if grep -Fq $'.gitconfig\tfile\t' "$BACKUP_RUN_DIR/manifest.v2"; then
  pass "F-01: retry entry is signed after successful publication"
else
  fail "F-01: retry entry was not signed"
fi

rem_setup
printf 'publish-stable\n' >"$TARGET_HOME/.zshrc"
backup_init "rem-publish-fail" >/dev/null
backup_path "$TARGET_HOME/.zshrc" "dotfile" >/dev/null
backup_finalize >/dev/null
publish_old_sha="$(file_sha256 "$BACKUP_RUN_DIR/manifest.v2")"
publish_snapshot="$BACKUP_RUN_DIR"
printf 'publish-new\n' >"$TARGET_HOME/.gitconfig"
mv() {
  if [[ "${1:-}" == "-fT" && "${2:-}" == "--" && "${3:-}" == */manifest.v2 ]]; then
    return 1
  fi
  command mv "$@"
}
expect_failure "F-01: failed publication preserves the old signed pair" \
  backup_path "$TARGET_HOME/.gitconfig" "dotfile"
unset -f mv
expect_eq "F-01: old manifest survives publication failure" "$publish_old_sha" \
  "$(file_sha256 "$publish_snapshot/manifest.v2")"
[[ -e "$publish_snapshot/manifest.v2.sig" ]] \
  && pass "F-01: old signature survives publication failure" \
  || fail "F-01: old signature was lost on publication failure"
printf 'publish-changed\n' >"$TARGET_HOME/.zshrc"
check "F-01: old snapshot restores after publication failure" \
  backup_restore_snapshot "$publish_snapshot"
expect_eq "F-01: old snapshot content after publication failure" "publish-stable" \
  "$(cat "$TARGET_HOME/.zshrc")"

rem_setup
printf 'signed-stable\n' >"$TARGET_HOME/.zshrc"
backup_init "rem-no-downgrade" >/dev/null
backup_path "$TARGET_HOME/.zshrc" "dotfile" >/dev/null
backup_finalize >/dev/null
downgrade_key="$BACKUP_SIGNING_KEY"
downgrade_manifest_sha="$(file_sha256 "$BACKUP_RUN_DIR/manifest.v2")"
printf 'downgrade-new\n' >"$TARGET_HOME/.gitconfig"
BACKUP_SIGNING_KEY=""
expect_failure_message "F-02: signed snapshot cannot be downgraded to unsigned" \
  'downgrade' backup_path "$TARGET_HOME/.gitconfig" "dotfile"
BACKUP_SIGNING_KEY="$downgrade_key"
expect_eq "F-02: manifest unchanged after downgrade refusal" "$downgrade_manifest_sha" \
  "$(file_sha256 "$BACKUP_RUN_DIR/manifest.v2")"
[[ -e "$BACKUP_RUN_DIR/manifest.v2.sig" ]] \
  && pass "F-02: signature survives downgrade refusal" \
  || fail "F-02: downgrade refusal removed the signature"

rem_setup
printf 'late-dotfile-original\n' >"$TARGET_HOME/.zshrc"
check "F-01: dotfile install finalizes a newly created snapshot" \
  dotfiles_install_one terminal symlink dotfiles/home/.zshrc .zshrc
if [[ -f "$BACKUP_RUN_DIR/manifest.v2" ]] \
  && [[ "$(awk -F= '$1 == "complete" { print $2; exit }' "$BACKUP_RUN_DIR/metadata.conf" 2>/dev/null)" == "1" ]] \
  && [[ -L "$TARGET_HOME/.zshrc" ]]; then
  pass "F-01: dotfile conflict backup is published and complete"
else
  fail "F-01: dotfile conflict backup was not published completely"
fi

rem_setup
printf 'signing-benign\n' >"$TARGET_HOME/.zshrc"
backup_init "rem-sign-fail" >/dev/null
backup_path "$TARGET_HOME/.zshrc" "dotfile" >/dev/null
good_signing_key="$BACKUP_SIGNING_KEY"
BACKUP_SIGNING_KEY="0000000000000000000000000000000000000000"
expect_failure_message "F-01: failed signing removes the published manifest" 'sign' \
  backup_manifest_rebuild
BACKUP_SIGNING_KEY="$good_signing_key"
if [[ ! -e "$BACKUP_RUN_DIR/manifest.v2" && ! -e "$BACKUP_RUN_DIR/manifest.v2.sig" ]]; then
  pass "F-01: failed signing left no valid manifest/signature pair"
else
  fail "F-01: failed signing left a manifest/signature pair"
fi

# --- F-02 OpenPGP status handling ------------------------------------------
if (( GPG_TESTS == 0 )); then
  fail "F-02: GnuPG is required for mandatory signature regression tests"
else
  gpg_create_key() {
    local label="$1"
    gpg --batch --passphrase '' --quick-generate-key "$label <test@example.invalid>" ed25519 sign 0 >/dev/null 2>&1 || return 1
    gpg --batch --with-colons --list-secret-keys "$label" 2>/dev/null \
      | awk -F: '$1 == "fpr" { print $10; exit }'
  }
  gpg_sign_file() {
    local file="$1" sig="$2" key="$3"
    gpg --batch --yes --armor --detach-sign --local-user "$key" --output "$sig" "$file" >/dev/null 2>&1
  }

  gpg_fpr_a="$(gpg_create_key "Rem A")"
  gpg_fpr_b="$(gpg_create_key "Rem B")"
  printf 'gpg-data\n' >"$REM_ROOT/gpg-data"
  gpg_sign_file "$REM_ROOT/gpg-data" "$REM_ROOT/a.sig" "$gpg_fpr_a"

  saved_signing_key="$BACKUP_SIGNING_KEY"
  BACKUP_SIGNING_KEY="$gpg_fpr_b"
  expect_failure_message "F-02: signature from a different key is rejected" \
    'does not match|invalid' backup_signature_verify "$REM_ROOT/gpg-data" "$REM_ROOT/a.sig"
  BACKUP_SIGNING_KEY="$gpg_fpr_a"
  check "F-02: signature from the configured key is accepted" \
    backup_signature_verify "$REM_ROOT/gpg-data" "$REM_ROOT/a.sig"

  gpg_fpr_rev="$(gpg_create_key "Rem Revoked")"
  gpg_sign_file "$REM_ROOT/gpg-data" "$REM_ROOT/rev.sig" "$gpg_fpr_rev"
  printf 'y\n0\n\ny\n' | gpg --yes --no-tty --command-fd 0 --output "$REM_ROOT/revoke.asc" \
    --gen-revoke "$gpg_fpr_rev" >/dev/null 2>&1 || true
  if [[ -f "$REM_ROOT/revoke.asc" ]] && gpg --batch --yes --import "$REM_ROOT/revoke.asc" >/dev/null 2>&1; then
    BACKUP_SIGNING_KEY="$gpg_fpr_rev"
    expect_failure_message "F-02: revoked key signature is rejected" \
      'revoked|expired|invalid' backup_signature_verify "$REM_ROOT/gpg-data" "$REM_ROOT/rev.sig"
  else
    fail "F-02: could not construct a revoked-key fixture"
  fi

  expired_home="$REM_ROOT/expired-gnupg"
  mkdir -p "$expired_home"
  chmod 700 "$expired_home"
  saved_gnupghome="$GNUPGHOME"
  GNUPGHOME="$expired_home"
  gpg --batch --faked-system-time 20200101T000000 --passphrase '' --quick-generate-key \
    'Rem Expired <expired@example.invalid>' ed25519 sign 1d >/dev/null 2>&1 || true
  gpg_fpr_exp="$(gpg --batch --with-colons --list-secret-keys 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }')"
  gpg --batch --faked-system-time 20200101T120000 --yes --armor --detach-sign \
    --local-user "$gpg_fpr_exp" --output "$REM_ROOT/expired.sig" "$REM_ROOT/gpg-data" >/dev/null 2>&1 || true
  if [[ -n "$gpg_fpr_exp" && -f "$REM_ROOT/expired.sig" ]]; then
    BACKUP_SIGNING_KEY="$gpg_fpr_exp"
    expect_failure_message "F-02: expired key signature is rejected" \
      'revoked|expired|invalid' backup_signature_verify "$REM_ROOT/gpg-data" "$REM_ROOT/expired.sig"
  else
    fail "F-02: could not construct an expired-key fixture"
  fi
  GNUPGHOME="$saved_gnupghome"

  sigexp_home="$REM_ROOT/sigexp-gnupg"
  mkdir -p "$sigexp_home"
  chmod 700 "$sigexp_home"
  saved_gnupghome="$GNUPGHOME"
  GNUPGHOME="$sigexp_home"
  gpg --batch --faked-system-time 20200101T000000 --passphrase '' --quick-generate-key \
    'Rem SigExp <sigexp@example.invalid>' ed25519 sign 0 >/dev/null 2>&1 || true
  gpg_fpr_sigexp="$(gpg --batch --with-colons --list-secret-keys 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }')"
  gpg --batch --faked-system-time 20200101T010000 --default-sig-expire 1d --yes --armor \
    --detach-sign --local-user "$gpg_fpr_sigexp" --output "$REM_ROOT/sigexp.sig" \
    "$REM_ROOT/gpg-data" >/dev/null 2>&1 || true
  if [[ -n "$gpg_fpr_sigexp" && -f "$REM_ROOT/sigexp.sig" ]]; then
    BACKUP_SIGNING_KEY="$gpg_fpr_sigexp"
    expect_failure_message "F-02: expired signature is rejected" \
      'expired|rejected|invalid' backup_signature_verify "$REM_ROOT/gpg-data" "$REM_ROOT/sigexp.sig"
  else
    fail "F-02: could not construct an expired-signature fixture"
  fi
  GNUPGHOME="$saved_gnupghome"

  gpg_fpr_sub="$(gpg_create_key "Rem Subkey")"
  gpg --batch --passphrase '' --quick-add-key "$gpg_fpr_sub" ed25519 sign 0 >/dev/null 2>&1 || true
  gpg_sign_file "$REM_ROOT/gpg-data" "$REM_ROOT/subkey.sig" "$gpg_fpr_sub"
  BACKUP_SIGNING_KEY="$gpg_fpr_sub"
  check "F-02: signature by an authorised signing subkey is accepted" \
    backup_signature_verify "$REM_ROOT/gpg-data" "$REM_ROOT/subkey.sig"

  saved_gnupghome="$GNUPGHOME"
  empty_gnupg="$REM_ROOT/empty-gnupg"
  mkdir -p "$empty_gnupg"
  chmod 700 "$empty_gnupg"
  GNUPGHOME="$empty_gnupg"
  BACKUP_SIGNING_KEY="$gpg_fpr_a"
  expect_failure_message "F-02: missing public key is rejected" \
    'gpg rejected|unavailable|invalid' backup_signature_verify "$REM_ROOT/gpg-data" "$REM_ROOT/a.sig"
  GNUPGHOME="$saved_gnupghome"

  gpg_sign_file "$REM_ROOT/gpg-data" "$REM_ROOT/multi1.sig" "$gpg_fpr_a"
  gpg_sign_file "$REM_ROOT/gpg-data" "$REM_ROOT/multi2.sig" "$gpg_fpr_a"
  cat "$REM_ROOT/multi1.sig" "$REM_ROOT/multi2.sig" >"$REM_ROOT/multi.sig"
  BACKUP_SIGNING_KEY="$gpg_fpr_a"
  expect_failure_message "F-02: multiple signatures are rejected as ambiguous" \
    'ambiguous|invalid' backup_signature_verify "$REM_ROOT/gpg-data" "$REM_ROOT/multi.sig"

  BACKUP_SIGNING_KEY="$saved_signing_key"
fi

# --- F-03 restore TOCTOU and atomic replacement ----------------------------
rem_setup
rem_v2_snapshot "toctou-benign"
snap="$REM_SNAPSHOT"
printf 'EVIL-AFTER-VERIFY\n' >"$REM_ROOT/evil"
printf '.gitconfig\tfile\t%s\t%s\t0600\tfiles/.gitconfig\t-\n' \
  "$(stat -c '%s' "$REM_ROOT/evil")" "$(file_sha256 "$REM_ROOT/evil")" >"$REM_ROOT/evil.manifest"
printf 'SYSTEM-INIT-BACKUP-V2\t1\n' >"$REM_ROOT/evil.signed-manifest"
cat "$REM_ROOT/evil.manifest" >>"$REM_ROOT/evil.signed-manifest"
printf 'toctou-original\n' >"$TARGET_HOME/.zshrc"
saved_signing_key="$BACKUP_SIGNING_KEY"
gpg() {
  local rc
  /usr/bin/gpg "$@"; rc=$?
  if [[ " $* " == *" --verify "* ]]; then
    cp -- "$REM_ROOT/evil.signed-manifest" "$snap/manifest.v2"
    cp -- "$REM_ROOT/evil" "$snap/files/.gitconfig"
  fi
  return "$rc"
}
check "F-03: manifest replacement after verification does not change restored content" \
  backup_restore_snapshot "$snap"
unset -f gpg
expect_eq "F-03: restored content came from the verified private copy" \
  "toctou-benign" "$(cat "$TARGET_HOME/.zshrc")"
[[ ! -e "$TARGET_HOME/.gitconfig" ]] \
  && pass "F-03: swapped manifest destination was not installed" \
  || fail "F-03: swapped manifest destination was installed"
BACKUP_SIGNING_KEY="$saved_signing_key"

rem_setup
rem_v2_snapshot "stage-benign"
snap="$REM_SNAPSHOT"
printf 'STAGE-SWAPPED\n' >"$REM_ROOT/evil-stage"
printf 'stage-original\n' >"$TARGET_HOME/.zshrc"
mv() {
  if [[ "${1:-}" == "-fT" && "${2:-}" == "--" && "${3:-}" == */new ]]; then
    cp -- "$REM_ROOT/evil-stage" "$3"
  fi
  command mv "$@"
}
expect_failure_message "F-03: staged payload replacement is detected" \
  'failed verification|changed before commit' backup_restore_snapshot "$snap"
unset -f mv
expect_eq "F-03: staged replacement did not overwrite the original" \
  "stage-original" "$(cat "$TARGET_HOME/.zshrc")"

rem_setup
rem_v2_snapshot "symlink-target"
snap="$REM_SNAPSHOT"
outside="$REM_ROOT/outside"
mkdir -p "$outside"
rm -f -- "$TARGET_HOME/.zshrc"
ln -s -- "$outside" "$TARGET_HOME/.zshrc"
check "F-03: symlink-to-directory destination is replaced atomically" \
  backup_restore_snapshot "$snap"
[[ -f "$TARGET_HOME/.zshrc" && ! -L "$TARGET_HOME/.zshrc" ]] \
  && pass "F-03: destination is a regular file after restore" \
  || fail "F-03: destination remained a symlink"
[[ -z "$(find "$outside" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  && pass "F-03: no file was written inside the symlink target directory" \
  || fail "F-03: restore wrote inside the symlink target directory"

rem_setup
commit_dest="$TARGET_HOME/.gitconfig"
commit_stage="$TARGET_HOME/.system-init-restore.commit-check"
printf 'committed-content\n' >"$commit_dest"
mkdir -p "$commit_stage"
chmod 700 "$commit_stage"
printf 'old-content\n' >"$commit_stage/old"
commit_size="$(stat -c '%s' "$commit_dest")"
commit_sha="$(file_sha256 "$commit_dest")"
printf 'attacker-content\n' >"$commit_dest"
expect_failure_message "F-03: destination replacement before commit is rejected" \
  'changed before commit' backup_restore_commit "$commit_dest" "$commit_stage" \
  file "$commit_size" "$commit_sha" 0600
[[ -f "$commit_stage/old" ]] \
  && pass "F-03: commit failure preserved the previous data" \
  || fail "F-03: commit failure deleted the previous data"

rem_setup
rem_v2_snapshot "hardlink-destination"
hardlink_victim="$REM_ROOT/hardlink-victim"
printf 'hardlink-victim-content\n' >"$hardlink_victim"
rm -f -- "$TARGET_HOME/.zshrc"
ln -- "$hardlink_victim" "$TARGET_HOME/.zshrc"
hardlink_victim_inode="$(stat -c '%i' "$hardlink_victim")"
check "F-03: hardlinked destination is replaced, not written through" \
  backup_restore_snapshot "$REM_SNAPSHOT"
expect_eq "F-03: hardlink target remains unchanged" "hardlink-victim-content" "$(cat "$hardlink_victim")"
expect_eq "F-03: restored content is the snapshot content" "hardlink-destination" "$(cat "$TARGET_HOME/.zshrc")"
[[ "$(stat -c '%i' "$TARGET_HOME/.zshrc")" != "$hardlink_victim_inode" ]] \
  && pass "F-03: restored destination is a distinct inode" \
  || fail "F-03: restored destination still shares the hardlink inode"

rem_setup
rem_v2_snapshot "concurrent-restore"
snap="$REM_SNAPSHOT"
printf 'concurrent-start\n' >"$TARGET_HOME/.zshrc"
state_lock_acquire "operation" || fail "F-03: could not acquire parent test lock"
expect_failure_message "F-03/F-11: a concurrent restore is refused by the lock" \
  'Another system-init operation' env \
    DEV_SETUP_TARGET_HOME="$TARGET_HOME" XDG_STATE_HOME="$REM_ROOT/state" \
    BACKUP_SIGNING_KEY="$BACKUP_SIGNING_KEY" GNUPGHOME="$GNUPGHOME" \
    bash -c 'source "$1/lib/logging.sh"; source "$1/lib/common.sh"; source "$1/lib/dotfiles.sh"; source "$1/lib/backups.sh"; backup_restore_snapshot "$2"' \
    _ "$ACTUAL_REPO" "$snap"
expect_failure_message "F-11: a concurrent backup is refused by the lock" \
  'Another system-init operation' env \
    DEV_SETUP_TARGET_HOME="$TARGET_HOME" XDG_STATE_HOME="$REM_ROOT/state" \
    BACKUP_SIGNING_KEY="$BACKUP_SIGNING_KEY" GNUPGHOME="$GNUPGHOME" \
    bash -c 'source "$1/lib/logging.sh"; source "$1/lib/common.sh"; source "$1/lib/backups.sh"; backup_init test' \
    _ "$ACTUAL_REPO"
recover_dest="$TARGET_HOME/.gitconfig"
recover_stage="$(rem_stage lock-recovery)"
printf 'lock-old\n' >"$recover_stage/old"
printf 'lock-current\n' >"$TARGET_HOME/.zshrc"
rm -f -- "$recover_dest"
recover_journal="$(rem_journal MOVED_ASIDE "$recover_dest" "$recover_stage" 1)"
expect_failure_message "F-11: journal recovery is refused while the lock is held" \
  'Another system-init operation' env \
    DEV_SETUP_TARGET_HOME="$TARGET_HOME" XDG_STATE_HOME="$REM_ROOT/state" \
    BACKUP_SIGNING_KEY="$BACKUP_SIGNING_KEY" GNUPGHOME="$GNUPGHOME" \
    bash -c 'source "$1/lib/logging.sh"; source "$1/lib/common.sh"; source "$1/lib/dotfiles.sh"; source "$1/lib/backups.sh"; backup_restore_recover_journal "$2"' \
    _ "$ACTUAL_REPO" "$recover_journal"
[[ -f "$recover_stage/old" && -f "$recover_journal" ]] \
  && pass "F-11: locked recovery preserved journal and staging data" \
  || fail "F-11: locked recovery modified state"

# Uninstall lock: a concurrent uninstall must not remove managed links.
rem_setup
ln -s -- "$ACTUAL_REPO/dotfiles/home/.zshrc" "$TARGET_HOME/.zshrc"
state_lock_acquire "operation" || fail "F-11: could not acquire uninstall test lock"
expect_failure_message "F-11: concurrent uninstall is refused by the lock" \
  'Another system-init operation' env \
    DEV_SETUP_TARGET_HOME="$TARGET_HOME" XDG_STATE_HOME="$REM_ROOT/state" \
    bash -c 'unset STATE_LOCK_HELD; exec "$1/uninstall.sh"' _ "$ACTUAL_REPO"
[[ -L "$TARGET_HOME/.zshrc" ]] \
  && pass "F-11: concurrent uninstall did not remove the managed link" \
  || fail "F-11: concurrent uninstall removed the managed link"
state_lock_release

rem_setup
owner_file="$REM_ROOT/lock-owner"
state_lock_owner_tuple "$$" >"$owner_file"
check "F-11: current process is recognized as the live lock owner" \
  state_lock_owner_is_live "$owner_file"
if [[ -r /proc/$$/stat && -r /proc/sys/kernel/random/boot_id ]]; then
  printf '$$\t0\t0\n' >"$owner_file"
  expect_failure "F-11: recycled PID with a different process start time is stale" \
    state_lock_owner_is_live "$owner_file"
else
  fail "F-11: /proc is required for lock-owner reuse test"
fi

# --- F-04 journal crash states ---------------------------------------------
rem_setup
printf 'crash-original\n' >"$TARGET_HOME/.zshrc"

prep_stage="$(rem_stage prepared-clean)"
st="$prep_stage"
printf 'never-installed\n' >"$st/new"
j="$(rem_journal PREPARED "$TARGET_HOME/.zshrc" "$st" 0)"
check "F-04: PREPARED with existing destination cleans an unmoved stage" \
  backup_restore_recover_journal "$j"
[[ ! -e "$st" && ! -e "$j" ]] \
  && pass "F-04: PREPARED cleanup removed stage and journal" \
  || fail "F-04: PREPARED cleanup left state behind"

st="$(rem_stage moving-aside)"
printf 'old-after-move\n' >"$st/old"
rm -f -- "$TARGET_HOME/.zshrc"
j="$(rem_journal MOVING_ASIDE "$TARGET_HOME/.zshrc" "$st" 1)"
check "F-04: MOVING_ASIDE recovers when destination is missing" \
  backup_restore_recover_journal "$j"
expect_eq "F-04: MOVING_ASIDE restored the old file" "old-after-move" "$(cat "$TARGET_HOME/.zshrc")"

st="$(rem_stage prepared-old)"
printf 'old-after-prepared\n' >"$st/old"
rm -f -- "$TARGET_HOME/.zshrc"
j="$(rem_journal PREPARED "$TARGET_HOME/.zshrc" "$st" 1)"
check "F-04: PREPARED with stage/old recovers a missing destination" \
  backup_restore_recover_journal "$j"
expect_eq "F-04: PREPARED recovered old content" "old-after-prepared" "$(cat "$TARGET_HOME/.zshrc")"

printf 'new-installed\n' >"$TARGET_HOME/.zshrc"
st="$(rem_stage new-installed)"
printf 'old-preserved\n' >"$st/old"
j="$(rem_journal NEW_INSTALLED "$TARGET_HOME/.zshrc" "$st" 1)"
expect_failure_message "F-04: NEW_INSTALLED with existing destination is unresolved" \
  'unresolved' backup_restore_recover_journal "$j"
[[ -f "$st/old" && -e "$j" ]] \
  && pass "F-04: unresolved state preserved stage and journal" \
  || fail "F-04: unresolved state was destroyed"

printf 'applied-new\n' >"$TARGET_HOME/.zshrc"
st="$(rem_stage applied)"
printf 'applied-old\n' >"$st/old"
j="$(rem_journal APPLIED "$TARGET_HOME/.zshrc" "$st" 1)"
expect_failure_message "F-04: APPLIED with existing destination is unresolved" \
  'unresolved' backup_restore_recover_journal "$j"

st="$(rem_stage rollback-failed)"
printf 'rollback-old\n' >"$st/old"
rm -f -- "$TARGET_HOME/.zshrc"
j="$(rem_journal ROLLBACK_FAILED "$TARGET_HOME/.zshrc" "$st" 1)"
check "F-04: ROLLBACK_FAILED recovers stage/old when destination is missing" \
  backup_restore_recover_journal "$j"
expect_eq "F-04: ROLLBACK_FAILED recovered content" "rollback-old" "$(cat "$TARGET_HOME/.zshrc")"

printf 'commit-new\n' >"$TARGET_HOME/.zshrc"
st="$(rem_stage commit-pending)"
printf 'commit-old\n' >"$st/old"
j="$(rem_journal COMMIT_PENDING "$TARGET_HOME/.zshrc" "$st" 1)"
expect_failure_message "F-04: COMMIT_PENDING with existing destination is unresolved" \
  'unresolved' backup_restore_recover_journal "$j"
st2="$(rem_stage commit-failed)"
printf 'commit-old-2\n' >"$st2/old"
j2="$(rem_journal COMMIT_FAILED "$TARGET_HOME/.zshrc" "$st2" 1)"
expect_failure_message "F-04: COMMIT_FAILED is unresolved" \
  'unresolved' backup_restore_recover_journal "$j2"

printf 'apply-cleaned\n' >"$TARGET_HOME/.zshrc"
st="$(rem_stage apply-failed-clean)"
printf 'staged-new\n' >"$st/new"
j="$(rem_journal APPLY_FAILED "$TARGET_HOME/.zshrc" "$st" 0)"
check "F-04: APPLY_FAILED before a move cleans an unused stage" \
  backup_restore_recover_journal "$j"
[[ ! -e "$st" ]] && pass "F-04: APPLY_FAILED cleanup removed stage" \
  || fail "F-04: APPLY_FAILED cleanup left stage"

st="$(rem_stage unknown)"
printf 'old\n' >"$st/old"
j="$(rem_journal NOT_A_STATUS "$TARGET_HOME/.zshrc" "$st" 1)"
expect_failure_message "F-04: unknown journal status is a recovery failure" \
  'Unknown journal status|unresolved' backup_restore_recover_journal "$j"

# --- F-04 repeated recovery idempotence ------------------------------------
rem_setup
first_dest="$TARGET_HOME/.p10k.zsh"
second_dest="$TARGET_HOME/.gitconfig"
first_stage="$(rem_stage idempotent-first)"
second_stage="$(rem_stage idempotent-second)"
printf 'first-old\n' >"$first_stage/old"
printf 'second-old\n' >"$second_stage/old"
rm -f -- "$first_dest" "$second_dest"
printf 'blocking-current\n' >"$second_dest"
idem_journal="$(rem_journal MOVED_ASIDE "$first_dest" "$first_stage" 1)"
printf 'MOVED_ASIDE\t%s\t%s\t1\n' "$second_dest" "$second_stage" >>"$idem_journal"
chmod 600 "$idem_journal"
expect_failure_message "F-04: partial recovery leaves only unresolved entries" \
  'unresolved' backup_restore_recover_journal "$idem_journal"
expect_eq "F-04: first entry recovered before partial failure" "first-old" "$(cat "$first_dest")"
rm -f -- "$second_dest"
check "F-04: recovery retry is idempotent for already recovered entries" \
  backup_restore_recover_journal "$idem_journal"
expect_eq "F-04: second entry recovered on retry" "second-old" "$(cat "$second_dest")"
expect_eq "F-04: first entry was not lost on retry" "first-old" "$(cat "$first_dest")"
[[ ! -e "$idem_journal" ]] && pass "F-04: idempotent recovery removed the journal" \
  || fail "F-04: idempotent recovery left the journal"

# --- F-06 journal confinement ----------------------------------------------
rem_setup
printf 'confined\n' >"$TARGET_HOME/.zshrc"
st="$(rem_stage traversal)"
printf 'traversal-old\n' >"$st/old"
outside_dest="$TARGET_HOME/../../../tmp/system-init-outside-recovery"
j="$(rem_journal MOVED_ASIDE "$outside_dest" "$st" 1)"
expect_failure_message "F-06: journal traversal is rejected" \
  'traversal|canonical|outside' backup_restore_recover_journal "$j"
[[ ! -e "$outside_dest" ]] && pass "F-06: traversal destination was not written" \
  || fail "F-06: traversal destination was written"

j="$(rem_journal MOVED_ASIDE "/tmp/system-init-outside-recovery" "$TARGET_HOME/.system-init-restore.never" 1)"
expect_failure_message "F-06: absolute destination outside HOME is rejected" \
  'outside TARGET_HOME' backup_restore_recover_journal "$j"

st="$(rem_stage stage-link-target)"
printf 'stage-target\n' >"$st/old"
ln -s -- "$st" "$TARGET_HOME/.system-init-restore.stage-link"
j="$(rem_journal MOVED_ASIDE "$TARGET_HOME/.zshrc" "$TARGET_HOME/.system-init-restore.stage-link" 1)"
expect_failure_message "F-06: symlinked staging directory is rejected" \
  'staging directory is missing or a symlink|not under' backup_restore_recover_journal "$j"

outside_journal="$TEST_TMP/outside-recovery.journal"
printf 'MOVED_ASIDE\t%s\t%s\t1\n' "$TARGET_HOME/.zshrc" "$st" >"$outside_journal"
chmod 600 "$outside_journal"
expect_failure_message "F-06: journal outside the canonical journal directory is rejected" \
  'outside the canonical journal directory' backup_restore_recover_journal "$outside_journal"

st="$(rem_stage ssh)"
printf 'ssh-key\n' >"$st/old"
mkdir -p "$TARGET_HOME/.ssh"
j="$(rem_journal MOVED_ASIDE "$TARGET_HOME/.ssh/authorized_keys" "$st" 1)"
expect_failure_message "F-06: .ssh/authorized_keys is rejected by the allowlist" \
  'approved managed target' backup_restore_recover_journal "$j"
[[ ! -e "$TARGET_HOME/.ssh/authorized_keys" ]] \
  && pass "F-06: unauthorized SSH key was not recovered" \
  || fail "F-06: unauthorized SSH key was recovered"

st="$(rem_stage perms)"
printf 'old\n' >"$st/old"
rm -f -- "$TARGET_HOME/.zshrc"
j="$(rem_journal MOVED_ASIDE "$TARGET_HOME/.zshrc" "$st" 1)"
chmod 644 "$j"
expect_failure_message "F-06: over-permissive journal is rejected" \
  'permissions' backup_restore_recover_journal "$j"

j="$(rem_journal MOVED_ASIDE "$TARGET_HOME/.zshrc" "$st" 1)"
ln -s -- "$j" "$JOURNAL_DIR/restore-symlink.journal"
expect_failure_message "F-06: symlinked journal is rejected" \
  'symlink' backup_restore_recover_journal "$JOURNAL_DIR/restore-symlink.journal"

j="$(rem_journal MOVED_ASIDE "$TARGET_HOME/.zshrc" "$st" 1)"
chmod 755 "$st"
expect_failure_message "F-06: wrongly permissioned staging directory is rejected" \
  'permissions' backup_restore_recover_journal "$j"

st="$(rem_stage old-dir)"
mkdir -p "$st/old"
j="$(rem_journal MOVED_ASIDE "$TARGET_HOME/.zshrc" "$st" 1)"
expect_failure_message "F-06: directory stage/old payload is rejected" \
  'directory payload' backup_restore_recover_journal "$j"

st="$(rem_stage old-link)"
ln -s -- /etc/passwd "$st/old"
j="$(rem_journal MOVED_ASIDE "$TARGET_HOME/.zshrc" "$st" 1)"
expect_failure_message "F-06: symlink stage/old payload is rejected" \
  'symlink payload' backup_restore_recover_journal "$j"

# --- F-07 gitconfig.local symlink ------------------------------------------
if command -v git >/dev/null 2>&1; then
  rem_setup
  victim="$REM_ROOT/victim"
  printf 'victim-content\n' >"$victim"
  ln -s -- "$victim" "$TARGET_HOME/.gitconfig.local"
  expect_failure_message "F-07: symlinked .gitconfig.local is rejected" \
    'symlink' git_identity_write_atomic "$TARGET_HOME/.gitconfig.local" "Test User" "test@example.invalid"
  expect_eq "F-07: symlink target remains unchanged" "victim-content" "$(cat "$victim")"
  [[ -L "$TARGET_HOME/.gitconfig.local" ]] \
    && pass "F-07: symlink was not replaced" \
    || fail "F-07: symlink was replaced"

  rm -f -- "$TARGET_HOME/.gitconfig.local"
  check "F-07: atomic writer creates a regular identity file" \
    git_identity_write_atomic "$TARGET_HOME/.gitconfig.local" "Test User" "test@example.invalid"
  [[ -f "$TARGET_HOME/.gitconfig.local" && ! -L "$TARGET_HOME/.gitconfig.local" ]] \
    && pass "F-07: identity file is a regular file" \
    || fail "F-07: identity file is not regular"
  expect_eq "F-07: identity file is mode 600" "600" "$(stat -c '%a' "$TARGET_HOME/.gitconfig.local")"
  expect_eq "F-07: identity content written" "Test User" \
    "$(git config --file "$TARGET_HOME/.gitconfig.local" --get user.name)"
else
  fail "F-07: git is required for the atomic identity regression test"
fi

# --- F-08 empty/partial snapshots and pruning -------------------------------
rem_setup
empty_home="$REM_ROOT/empty-home"
empty_state="$REM_ROOT/empty-state"
mkdir -p "$empty_home"
empty_output="$(DEV_SETUP_TARGET_HOME="$empty_home" XDG_STATE_HOME="$empty_state" \
  "$ACTUAL_REPO/scripts/backup.sh" 2>&1)" || empty_rc=$? 
empty_rc="${empty_rc:-0}"
if (( empty_rc == 0 )) && ! find "$empty_state/system-init/backups" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
  pass "F-08: empty backup does not publish a snapshot"
else
  fail "F-08: empty backup published a snapshot or returned failure (rc=$empty_rc)"
fi

rem_setup
mkdir -p "$TARGET_HOME/.zshrc"
partial_output="$(DEV_SETUP_TARGET_HOME="$TARGET_HOME" XDG_STATE_HOME="$REM_ROOT/state" \
  "$ACTUAL_REPO/scripts/backup.sh" 2>&1)" && partial_rc=0 || partial_rc=$?
if (( partial_rc != 0 )) && ! backup_latest | grep -q .; then
  pass "F-08: partial backup fails and is not selected as latest"
else
  fail "F-08: partial backup did not fail closed (rc=$partial_rc)"
fi
if ! find "$REM_ROOT/state/system-init/backups" -name 'manifest.v2' -print -quit 2>/dev/null | grep -q .; then
  pass "F-08: partial backup did not publish an authenticated manifest"
else
  fail "F-08: partial backup published an authenticated manifest"
fi
rm -rf -- "$TARGET_HOME/.zshrc"

rem_setup
rem_v2_snapshot "complete-old"
complete_snap="$REM_SNAPSHOT"
complete_path="$BACKUP_RUN_DIR"
BACKUP_RUN_DIR=""
backup_init "incomplete-new" >/dev/null
incomplete_path="$BACKUP_RUN_DIR"
latest="$(backup_latest)"
expect_eq "F-08: backup_latest skips an incomplete newer snapshot" "$complete_path" "$latest"

prune_home="$REM_ROOT/prune-home"
prune_backups_dir="$REM_ROOT/prune-state/system-init/backups"
mkdir -p "$prune_home" "$prune_backups_dir"
for prune_name in 20260101T000000Z 20260102T000000Z; do
  mkdir -p "$prune_backups_dir/$prune_name/files"
  printf '%s\t%s\tfile\n' "/tmp/payload" "$prune_backups_dir/$prune_name/files/payload" \
    >"$prune_backups_dir/$prune_name/manifest.tsv"
  printf 'created=test\n' >"$prune_backups_dir/$prune_name/metadata.conf"
done
BACKUP_DIR="$prune_backups_dir"
DOTFILES_BACKUP_KEEP=1
ORIGINAL_SAFE_RM="$(declare -f safe_rm_rf)"
safe_rm_rf() { return 1; }
expect_failure_message "F-08: pruning failure is reported" 'Failed to prune' prune_backups
eval "$ORIGINAL_SAFE_RM"
[[ -d "$prune_backups_dir/20260102T000000Z" ]] \
  && pass "F-08: prune failure preserved the snapshot" \
  || fail "F-08: prune failure deleted the snapshot"

rem_setup
rem_v2_snapshot "metadata-missing"
missing_metadata_snap="$REM_SNAPSHOT"
rm -f -- "$missing_metadata_snap/metadata.conf"
expect_failure "F-08: snapshot without metadata is treated as incomplete" \
  backup_snapshot_path "$missing_metadata_snap"

# --- F-09 legacy/empty false success ---------------------------------------
rem_setup
legacy_unread="$BACKUP_DIR/20260101T000000Z"
mkdir -p "$legacy_unread/files"
printf 'legacy\n' >"$legacy_unread/files/.zshrc"
printf '%s\t%s\tfile\n' "$TARGET_HOME/.zshrc" "$legacy_unread/files/.zshrc" >"$legacy_unread/manifest.tsv"
printf 'created=test\n' >"$legacy_unread/metadata.conf"
chmod 000 "$legacy_unread/manifest.tsv"
RESTORE_ALLOW_LEGACY=1
expect_failure_message "F-09: unreadable legacy manifest is rejected" \
  'Could not open' backup_restore_snapshot "$legacy_unread"
chmod 600 "$legacy_unread/manifest.tsv"

legacy_empty="$BACKUP_DIR/20260102T000000Z"
mkdir -p "$legacy_empty/files"
: >"$legacy_empty/manifest.tsv"
printf 'created=test\n' >"$legacy_empty/metadata.conf"
expect_failure_message "F-09: empty legacy snapshot is rejected" \
  'empty' backup_restore_snapshot "$legacy_empty"

v2_empty="$BACKUP_DIR/20260103T000000Z"
mkdir -p "$v2_empty/files"
printf 'SYSTEM-INIT-BACKUP-V2\t1\n' >"$v2_empty/manifest.v2"
printf 'created=test\ncomplete=1\n' >"$v2_empty/metadata.conf"
RESTORE_ALLOW_UNSIGNED=1
expect_failure_message "F-09: empty v2 snapshot is rejected" \
  'empty' backup_restore_snapshot "$v2_empty"
RESTORE_ALLOW_UNSIGNED=0
RESTORE_ALLOW_LEGACY=0

# --- F-10 uninstall removal failures ---------------------------------------
rem_setup
ln -s -- "$ACTUAL_REPO/dotfiles/home/.zshrc" "$TARGET_HOME/.zshrc"
chmod 0500 "$TARGET_HOME"
uninstall_output="$(DEV_SETUP_TARGET_HOME="$TARGET_HOME" XDG_STATE_HOME="$REM_ROOT/state" \
  "$ACTUAL_REPO/uninstall.sh" --purge-state 2>&1)" && uninstall_rc=0 || uninstall_rc=$?
chmod 0700 "$TARGET_HOME"
if (( uninstall_rc != 0 )) && [[ -L "$TARGET_HOME/.zshrc" ]] \
  && grep -q 'Could not remove managed symlink' <<<"$uninstall_output" \
  && [[ -d "$REM_ROOT/state/system-init" ]]; then
  pass "F-10: failed uninstall removal returns nonzero and preserves the path"
else
  fail "F-10: failed uninstall removal was reported as success"
fi
if [[ -d "$REM_ROOT/state/system-init" ]] \
  && grep -q 'Refusing to purge state because the uninstall recorded failures' <<<"$uninstall_output"; then
  pass "F-10: failed removal prevents state purge"
else
  fail "F-10: failed removal did not prevent state purge"
fi

# --- F-05 failed restore preserves state -----------------------------------
rem_setup
legacy_state_snap="$BACKUP_DIR/20260101T000000Z"
mkdir -p "$legacy_state_snap/files"
printf 'snapshot\n' >"$legacy_state_snap/files/.zshrc"
printf '%s\t%s\tfile\n' "$TARGET_HOME/.zshrc" "$legacy_state_snap/files/.zshrc" >"$legacy_state_snap/manifest.tsv"
printf 'created=test\n' >"$legacy_state_snap/metadata.conf"
printf 'home\n' >"$TARGET_HOME/.zshrc"
uninstall_output="$(DEV_SETUP_TARGET_HOME="$TARGET_HOME" XDG_STATE_HOME="$REM_ROOT/state" \
  "$ACTUAL_REPO/uninstall.sh" --restore-backups --purge-state 2>&1)" && uninstall_rc=0 || uninstall_rc=$?
if (( uninstall_rc != 0 )) && [[ -d "$legacy_state_snap" ]] \
  && [[ -f "$legacy_state_snap/manifest.tsv" ]] \
  && grep -q 'Refusing to purge state' <<<"$uninstall_output"; then
  pass "F-05: failed restore preserves backups and refuses purge"
else
  fail "F-05: failed restore did not preserve recovery state (rc=$uninstall_rc)"
fi

# --- F-12 Flatpak URL verification -----------------------------------------
flatpak_fake_remote="flathub"
flatpak_fake_url="https://dl.flathub.org/repo/"
flatpak_fake_present=1
flatpak() {
  if [[ "${1:-}" == "remotes" ]]; then
    if [[ " $* " == *" --columns=name,url "* ]]; then
      if (( flatpak_fake_present == 1 )); then
        printf '%s\t%s\n' "$flatpak_fake_remote" "$flatpak_fake_url"
      fi
    else
      printf 'Name\n'
      (( flatpak_fake_present == 1 )) && printf '%s\n' "$flatpak_fake_remote"
    fi
    return 0
  fi
  return 0
}
FLATPAK_REMOTE=flathub
FLATPAK_REPO_URL="$FLATPAK_FLATHUB_LEGACY_REPO_FILE"
check "F-12: dl Flathub repository matches the legacy descriptor" \
  flatpak_remote_url_matches "$FLATPAK_REMOTE" "$FLATPAK_REPO_URL"
FLATPAK_REPO_URL="$FLATPAK_FLATHUB_REPO_FILE"
check "F-12: dl Flathub repository matches the current descriptor" \
  flatpak_remote_url_matches "$FLATPAK_REMOTE" "$FLATPAK_REPO_URL"
FLATPAK_REPO_URL="$FLATPAK_FLATHUB_REPO_URL"
check "F-12: dl Flathub repository URL matches itself" \
  flatpak_remote_url_matches "$FLATPAK_REMOTE" "$FLATPAK_REPO_URL"
flatpak_fake_url="$FLATPAK_FLATHUB_LEGACY_REPO_URL"
check "F-12: legacy Flathub repository URL matches the current URL" \
  flatpak_remote_url_matches "$FLATPAK_REMOTE" "$FLATPAK_REPO_URL"

flatpak_fake_url="https://evil.example.invalid/repo/"
expect_failure "F-12: an unexpected detected URL is rejected" \
  flatpak_remote_url_matches "$FLATPAK_REMOTE" "$FLATPAK_REPO_URL"
FLATPAK_REPO_URL="https://evil.example.invalid/repo/"
flatpak_fake_url="https://evil.example.invalid/repo/"
expect_failure "F-12: an unapproved expected URL is rejected even when detected matches" \
  flatpak_remote_url_matches "$FLATPAK_REMOTE" "$FLATPAK_REPO_URL"

flatpak_fake_url="https://evil.example.invalid/repo/"
FLATPAK_REPO_URL="$FLATPAK_FLATHUB_REPO_FILE"
flatpak_fake_present=1
F12_CAPTURE="$TEST_TMP/f12-capture"
rm -f -- "$F12_CAPTURE"
ORIGINAL_RUN_SUDO="$(declare -f run_sudo)"
run_sudo() { printf '%s\n' "$@" >"$F12_CAPTURE"; return 0; }
flatpak_ensure_output="$(flatpak_remote_ensure 2>&1)" && flatpak_ensure_rc=0 || flatpak_ensure_rc=$?
if (( flatpak_ensure_rc != 0 )) \
  && grep -Fq "Expected: $FLATPAK_REPO_URL" <<<"$flatpak_ensure_output" \
  && grep -Fq 'Detected: https://evil.example.invalid/repo/' <<<"$flatpak_ensure_output" \
  && [[ ! -e "$F12_CAPTURE" ]]; then
  pass "F-12: existing unexpected remote fails closed without overwrite"
else
  fail "F-12: existing unexpected remote was not rejected safely (rc=$flatpak_ensure_rc: ${flatpak_ensure_output//$'\n'/ | })"
fi

flatpak_fake_present=0
rm -f -- "$F12_CAPTURE"
check "F-12: missing remote is added with the expected URL" flatpak_remote_ensure
captured="$(cat "$F12_CAPTURE" 2>/dev/null || true)"
expect_match "F-12: remote-add uses the configured official descriptor" \
  $'(^|\n)remote-add\n--if-not-exists\n--system\n--\nflathub\nhttps://dl\\.flathub\\.org/repo/flathub\\.flatpakrepo($|\n)' \
  "$captured"

FLATPAK_REMOTE=fedora
FLATPAK_REPO_URL="oci+https://registry.fedoraproject.org"
flatpak_fake_remote=fedora
flatpak_fake_url="$FLATPAK_REPO_URL"
flatpak_fake_present=1
check "F-12: Fedora Flatpaks OCI remote still verifies" \
  flatpak_remote_url_matches "$FLATPAK_REMOTE" "$FLATPAK_REPO_URL"
flatpak_fake_url="oci+https://registry.fedoraproject.org#testing"
expect_failure "F-12: Fedora testing remote is not accepted as the stable remote" \
  flatpak_remote_url_matches "$FLATPAK_REMOTE" "$FLATPAK_REPO_URL"

flatpak_fake_url="$FLATPAK_REPO_URL"
flatpak_fake_present=0
rm -f -- "$F12_CAPTURE"
check "F-12: missing Fedora Flatpaks remote is added unchanged" flatpak_remote_ensure
captured="$(cat "$F12_CAPTURE" 2>/dev/null || true)"
expect_match "F-12: Fedora remote-add remains unchanged" \
  $'(^|\n)remote-add\n--if-not-exists\n--system\n--\nfedora\noci\\+https://registry\\.fedoraproject\\.org($|\n)' \
  "$captured"

eval "$ORIGINAL_RUN_SUDO"
unset -f flatpak
FLATPAK_REMOTE=flathub
FLATPAK_REPO_URL="$FLATPAK_FLATHUB_REPO_FILE"

# --- F-13 Git configuration isolation --------------------------------------
if command -v git >/dev/null 2>&1; then
  rem_setup
  git_repo="$REM_ROOT/git-repo"
  git init -q "$git_repo"
  git -C "$git_repo" config user.name "Test"
  git -C "$git_repo" config user.email "test@example.invalid"
  printf 'safe\n' >"$git_repo/file"
  git -C "$git_repo" add file
  git -C "$git_repo" commit -q -m one
  git -C "$git_repo" config core.sshCommand /bin/false
  expect_failure "F-13: unsafe core.sshCommand is rejected" git_checkout_config_safe "$git_repo"
  git -C "$git_repo" config --unset core.sshCommand
  git -C "$git_repo" config filter.evil.clean /bin/false
  expect_failure "F-13: executable filter configuration is rejected" git_checkout_config_safe "$git_repo"
  git -C "$git_repo" config --unset filter.evil.clean

  malicious_home="$REM_ROOT/git-home"
  mkdir -p "$malicious_home"
  printf '[core]\n\tfsmonitor = %s\n' "$REM_ROOT/git-marker" >"$malicious_home/.gitconfig"
  HOME="$malicious_home" git_safe -C "$git_repo" status --porcelain >/dev/null 2>&1 || true
  [[ ! -e "$REM_ROOT/git-marker" ]] \
    && pass "F-13: git_safe ignores malicious global configuration" \
    || fail "F-13: git_safe executed malicious global configuration"
  if [[ "$( 
    export GIT_DIR="/does/not/exist" GIT_WORK_TREE="/etc" GIT_INDEX_FILE="/does/not/exist"
    export GIT_OBJECT_DIRECTORY="/does/not/exist" GIT_SSH_COMMAND="/bin/false"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=/bin/false
    git_safe -C "$git_repo" rev-parse --is-inside-work-tree 2>/dev/null
  )" == "true" ]]; then
    pass "F-13: git_safe ignores hostile Git environment variables"
  else
    fail "F-13: git_safe accepted hostile Git environment variables"
  fi
else
  fail "F-13: git is required for Git isolation regression tests"
fi

# --- F-14 empty module selections ------------------------------------------
EXPECT_FAILURE_RC=2
expect_failure_message "F-14: --module=, is rejected" 'no valid module names' \
  "$ACTUAL_REPO/install.sh" --list --module=,
expect_failure_message "F-14: --module=,, is rejected" 'no valid module names' \
  "$ACTUAL_REPO/install.sh" --list --module=,,
check "F-14: valid --module list still works" \
  "$ACTUAL_REPO/install.sh" --list --module=core
expect_failure_message "F-14: unknown module is rejected" 'Unknown module' \
  "$ACTUAL_REPO/install.sh" --list --module=does-not-exist
EXPECT_FAILURE_RC=1

# --- F-15 doctor runtime inspection is read-only ---------------------------
rem_setup
ORIGINAL_MISE_VERIFY="$(declare -f mise_verify_runtimes_readonly)"
ORIGINAL_MISE_TRUSTED="$(declare -f mise_binary_trusted)"
ORIGINAL_MISE_RUN="$(declare -f mise_run)"
ORIGINAL_PARSE_RUNTIMES="$(declare -f parse_runtimes)"
mise_binary_trusted() { return 0; }
parse_runtimes() { printf 'node 26.13.0\n'; }
mise_run() {
  printf '%s\n' "$*" >>"$REM_ROOT/mise-args"
  if [[ "${1:-}" == "ls" && "${2:-}" == "--installed" ]]; then
    printf 'node 26.13.0\n'
    return 0
  fi
  return 1
}
check "F-15: read-only runtime inspection succeeds without exec" mise_verify_runtimes_readonly
if grep -q 'ls --installed' "$REM_ROOT/mise-args" && ! grep -q 'exec' "$REM_ROOT/mise-args"; then
  pass "F-15: doctor runtime inspection does not invoke mise exec"
else
  fail "F-15: doctor runtime inspection invoked a mutating mise command"
fi
eval "$ORIGINAL_MISE_VERIFY"
eval "$ORIGINAL_MISE_TRUSTED"
eval "$ORIGINAL_MISE_RUN"
eval "$ORIGINAL_PARSE_RUNTIMES"

# --- F-17 repository fast path and multi-key allow-list ---------------------
rem_setup
fake_repo="$REM_ROOT/fake-repo"
fake_repo_file="$fake_repo/platforms/fedora/repos/vscode.repo"
mkdir -p "$(dirname -- "$fake_repo_file")" "$REM_ROOT/fake-etc"
printf '[test]\nname=test\n' >"$fake_repo_file"
fake_repo_sha="$(file_sha256 "$fake_repo_file")"
cp -- "$fake_repo_file" "$REM_ROOT/fake-etc/vscode.repo"
saved_repo_root="$REPO_ROOT"
saved_selected=("${SELECTED_MODULES[@]}")
saved_vscode_sha="$VSCODE_REPO_SHA256"
saved_fedora_repo_dir="$FEDORA_REPO_DIR"
ORIGINAL_FEDORA_INSTALL_KEY="$(declare -f fedora_install_key)"
ORIGINAL_DNF_MAKECACHE="$(declare -f dnf_makecache)"
fedora_install_key() { return 0; }
dnf_makecache() { return 0; }
REPO_ROOT="$fake_repo"
SELECTED_MODULES=(editors)
VSCODE_REPO_SHA256="$fake_repo_sha"
FEDORA_REPO_DIR="$REM_ROOT/fake-etc"
check "F-17: repository fast path verifies the pinned source hash" fedora_ensure_repos
printf 'tampered\n' >>"$fake_repo_file"
cp -- "$fake_repo_file" "$REM_ROOT/fake-etc/vscode.repo"
expect_failure_message "F-17: repository fast path rejects a tampered source" 'pinned SHA-256' \
  fedora_ensure_repos
eval "$ORIGINAL_FEDORA_INSTALL_KEY"
eval "$ORIGINAL_DNF_MAKECACHE"
REPO_ROOT="$saved_repo_root"
SELECTED_MODULES=("${saved_selected[@]}")
VSCODE_REPO_SHA256="$saved_vscode_sha"
FEDORA_REPO_DIR="$saved_fedora_repo_dir"
expect_match "F-17: Brave key allow-list includes all primary fingerprints" \
  'DBF1A116C220B8C7164F98230686B78420038257.*47D32A74E9A9E013A4B4926C68D513D36A73CD96.*B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0' \
  "$(fedora_key_fingerprints brave)"

# --- F-16 status distinguishes payload integrity ---------------------------
rem_setup
rem_v2_snapshot "status-payload"
snap="$REM_SNAPSHOT"
rm -f -- "$snap/files/.zshrc"
expect_eq "F-16: signed snapshot with missing payload is not simply signed" \
  "invalid-payload" "$(backup_snapshot_status "$snap")"
[[ -z "$(backup_latest)" ]] \
  && pass "F-16: backup_latest ignores a snapshot with invalid payloads" \
  || fail "F-16: backup_latest selected a snapshot with invalid payloads"

# --- F-17 filesystem/parser hardening --------------------------------------
rem_setup
safe_rm_target="$REM_ROOT/safe-rm-target"
mkdir -p "$safe_rm_target"
printf 'keep\n' >"$safe_rm_target/keep"
ORIGINAL_HAVE_COMMAND="$(declare -f have_command)"
have_command() { [[ "$1" != "findmnt" ]] && command -v "$1" >/dev/null 2>&1; }
expect_failure_message "F-17: recursive deletion fails closed without findmnt" \
  'mount-point inspection is unavailable' safe_rm_rf "$safe_rm_target"
eval "$ORIGINAL_HAVE_COMMAND"
[[ -f "$safe_rm_target/keep" ]] \
  && pass "F-17: failed safe_rm_rf preserved the target tree" \
  || fail "F-17: failed safe_rm_rf deleted the target tree"
findmnt() { printf '%s\n' "$safe_rm_target/mounted-child"; }
expect_failure_message "F-17: recursive deletion refuses a child mount point" \
  'mount point' safe_rm_rf "$safe_rm_target"
unset -f findmnt
[[ -f "$safe_rm_target/keep" ]] \
  && pass "F-17: child-mount refusal preserved the target tree" \
  || fail "F-17: child-mount refusal deleted the target tree"

if command -v tar >/dev/null 2>&1; then
  archive_src="$REM_ROOT/archive-src"
  mkdir -p "$archive_src/evil"
  printf 'escape\n' >"$archive_src/evil/file"
  tar -czf "$REM_ROOT/evil.tar.gz" -C "$archive_src" \
    --transform='s|^evil|../escape|' evil >/dev/null 2>&1 || true
  expect_failure_message "F-17: archive path traversal is rejected" \
    'unsafe path' extract_archive "$REM_ROOT/evil.tar.gz" "$REM_ROOT/archive-dest"
  [[ ! -e "$REM_ROOT/escape" ]] \
    && pass "F-17: archive traversal did not write outside the destination" \
    || fail "F-17: archive traversal wrote outside the destination"
else
  fail "F-17: tar is required for archive traversal regression test"
fi

expect_eq "F-17: C1 control characters are removed from metadata" "31m" \
  "$(backup_sanitize_text $'\x9b31m')"
expect_failure "F-17: impossible snapshot date is rejected" \
  backup_snapshot_name_is_valid "20260230T000000Z"

rem_setup
unsafe_mode="$REM_ROOT/unsafe-mode"
mkdir -p "$unsafe_mode/files"
empty_sha="$(printf '' | sha256sum | awk '{ print $1 }')"
printf 'SYSTEM-INIT-BACKUP-V2\t1\n' >"$unsafe_mode/manifest.v2"
printf '.zshrc\tfile\t0\t%s\t0644\tfiles/.zshrc\t-\n' "$empty_sha" >>"$unsafe_mode/manifest.v2"
printf 'created=test\ncomplete=1\n' >"$unsafe_mode/metadata.conf"
expect_failure "F-17: permissive 0644 manifest mode is rejected" \
  backup_v2_manifest_validate "$unsafe_mode"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n'
printf 'Security regression summary: %d passed, %d failed, %d skipped\n' "$PASSES" "$FAILURES" "$SKIPS"
if (( FAILURES > 0 )); then
  printf 'Test log: %s\n' "$TEST_LOG"
  exit 1
fi
