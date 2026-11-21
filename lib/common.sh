#!/usr/bin/env bash
# Shared helpers for system-init.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_COMMON_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_COMMON_SOURCED=1

# Repository scripts must never resolve privileged commands through a
# user-controlled PATH. Fedora keeps the system-only PATH. macOS needs the
# validated Homebrew prefix for brew, bash and the requested CLI tools.
if [[ "$(uname -s)" == "Darwin" ]]; then
  PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
else
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
fi
export PATH

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"

# shellcheck source=compat.sh
source "$REPO_ROOT/lib/compat.sh"
# shellcheck source=report.sh
source "$REPO_ROOT/lib/report.sh"

# Resolve the target home without rejecting a legitimate symlinked $HOME.
# Existing components are followed so the canonical spelling is used for state
# and backup paths; a missing target is still normalised lexically so callers
# can report a useful validation error.
target_home_resolve() {
  local home="${1:-$TARGET_HOME}"
  [[ -n "$home" && "$home" == /* ]] || return 1
  path_resolve "$home"
}

TARGET_HOME="${DEV_SETUP_TARGET_HOME:-$HOME}"
if _resolved_target_home="$(target_home_resolve "$TARGET_HOME")"; then
  TARGET_HOME="$_resolved_target_home"
fi
unset _resolved_target_home

# Used by the backup and shell installers.
# shellcheck disable=SC2034
TARGET_USER="${DEV_SETUP_TARGET_USER:-$(id -un)}"

# State lives under the canonical home (or XDG_STATE_HOME). Resolving existing
# symlink components here keeps init_private_dir useful while still permitting
# users who store state on a separate, symlinked volume.
_state_base="${XDG_STATE_HOME:-$TARGET_HOME/.local/state}"
if [[ "$_state_base" != /* ]]; then
  _state_base="$TARGET_HOME/.local/state"
fi
if _resolved_state_base="$(path_resolve "$_state_base" 2>/dev/null)"; then
  _state_base="$_resolved_state_base"
fi
unset _resolved_state_base
STATE_DIR="$_state_base/system-init"
unset _state_base

LOG_DIR="$STATE_DIR/logs"
BACKUP_DIR="$STATE_DIR/backups"
JOURNAL_DIR="$STATE_DIR/journal"
TMP_DIR=""
DRY_RUN="${DRY_RUN:-0}"
DEBUG="${DEBUG:-0}"
SUDO_BIN=/usr/bin/sudo

# shellcheck source=../config/settings.conf
source "$REPO_ROOT/config/settings.conf"
# shellcheck source=../config/pins.conf
source "$REPO_ROOT/config/pins.conf"
# shellcheck source=../config/profiles.conf
source "$REPO_ROOT/config/profiles.conf"

FAILED_ITEMS=()
WARNED_ITEMS=()
SELECTED_MODULES=()
# Used by record_failure and module hooks in sourced files.
# shellcheck disable=SC2034
CURRENT_MODULE=""

record_failure() {
  FAILED_ITEMS+=("${CURRENT_MODULE:-global}: $*")
  log_error "$*"
}

record_warning() {
  WARNED_ITEMS+=("${CURRENT_MODULE:-global}: $*")
  log_warn "$*"
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

module_name_is_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
}

package_name_is_valid() {
  local package="${1:-}"
  [[ -n "$package" && "$package" != -* && "$package" != */* && "$package" != *[[:space:]]* ]]
}

# Conservative account-name check. This is deliberately narrower than the
# possible contents of /etc/passwd: the value is passed to getent, chsh and
# usermod, so a leading '-' or shell/option syntax must never be accepted.
target_user_is_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]
}

sudo_binary_valid() {
  [[ "$SUDO_BIN" == /* && -f "$SUDO_BIN" && -x "$SUDO_BIN" && ! -L "$SUDO_BIN" ]]
}

require_command() {
  if ! have_command "$1"; then
    record_failure "Required command not found: $1"
    return 1
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    record_failure "Required file not found: $1"
    return 1
  fi
}

module_selected() {
  local wanted="$1"
  local module
  for module in "${SELECTED_MODULES[@]}"; do
    [[ "$module" == "$wanted" ]] && return 0
  done
  return 1
}

module_packages_file() {
  printf '%s/modules/%s/packages.%s\n' "$REPO_ROOT" "$1" "$PLATFORM"
}

module_metadata_value() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file" \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

module_depends() {
  module_metadata_value "$REPO_ROOT/modules/$1/module.conf" "MODULE_DEPENDS" || true
}

module_description() {
  module_metadata_value "$REPO_ROOT/modules/$1/module.conf" "MODULE_DESCRIPTION" || true
}

module_description_or_default() {
  local description
  description="$(module_description "$1")"
  printf '%s\n' "${description:-No description}"
}

now_timestamp() {
  date -u '+%Y%m%dT%H%M%SZ'
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "$(log_cmd "$@")"
    return 0
  fi
  log_debug "exec: $(log_cmd "$@")"
  "$@"
}

run_sudo() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo $(log_cmd "$@")"
    return 0
  fi
  if ! sudo_binary_valid; then
    log_error "Refusing to run sudo: expected an absolute, non-symlink executable at $SUDO_BIN."
    return 1
  fi
  log_debug "exec: sudo $(log_cmd "$@")"
  "$SUDO_BIN" -- "$@"
}

ensure_dir() {
  local directory="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "mkdir -p $(log_cmd "$directory")"
    return 0
  fi
  mkdir -p -- "$directory"
}

# Run Git without repository-controlled configuration executing commands.
# core.hooksPath=/dev/null disables hooks (notably post-merge and
# reference-transaction during updates); fsmonitor and untracked-cache are
# disabled explicitly because both are read from repository-local config.
git_safe() {
  local ssh_command=/usr/bin/ssh
  [[ -x "$ssh_command" ]] || ssh_command=ssh
  env \
    -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u GIT_NAMESPACE \
    -u GIT_CEILING_DIRECTORIES -u GIT_CONFIG -u GIT_CONFIG_COUNT \
    -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_SYSTEM -u GIT_SSH \
    -u GIT_SSH_COMMAND -u GIT_SSH_VARIANT -u GIT_ASKPASS -u SSH_ASKPASS \
    -u GIT_PROXY_COMMAND -u GIT_ALLOW_PROTOCOL -u GIT_EXTERNAL_DIFF \
    -u GIT_PAGER -u GIT_EDITOR -u GIT_SEQUENCE_EDITOR -u GIT_SSL_NO_VERIFY \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    git --no-pager \
    -c core.fsmonitor=false \
    -c core.untrackedCache=false \
    -c core.hooksPath=/dev/null \
    -c "core.sshCommand=$ssh_command" \
    -c protocol.ext.allow=never \
    -c core.attributesFile=/dev/null \
    -c credential.helper= \
    -c diff.external= \
    -c core.pager=cat \
    "$@"
}

# Reject repository-local configuration that can execute commands or redirect
# transport. Includes are rejected because Git itself follows them.
git_checkout_config_safe() {
  local path="${1:-}"
  local config keys
  config="$path/.git/config"
  [[ -f "$config" && ! -L "$config" ]] || return 1
  keys="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_CONFIG \
    -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
    git config --file "$config" --list 2>/dev/null | sed 's/=.*//')" || return 1
  if grep -Eiq '^(core\.sshcommand|core\.fsmonitor|core\.hookspath|core\.attributesfile|filter\..*\.(clean|smudge|process)|url\..*\.insteadof|credential\.helper|diff\.external|protocol\.ext\.allow|include\.path|includeif\..*)$' <<<"$keys"; then
    return 1
  fi
  return 0
}

git_checkout_permissions_safe() {
  local path="${1:-}"
  local perms item
  for item in "$path" "$path/.git" "$path/.git/config"; do
    perms="$(file_mode "$item" 2>/dev/null)" || return 1
    [[ "$perms" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$perms & 022) == 0 )) || return 1
  done
  return 0
}

git_checkout_metadata_safe() {
  local path="${1:-}"
  [[ -n "$path" && -d "$path/.git" && ! -L "$path" && ! -L "$path/.git" ]]
}

git_checkout_owned_by_user() {
  local path="${1:-}"
  local uid current

  git_checkout_metadata_safe "$path" || return 1
  uid="$(id -u)"
  current="$(file_owner_uid "$path" 2>/dev/null)" || return 1
  [[ "$current" == "$uid" ]] || return 1
  current="$(file_owner_uid "$path/.git" 2>/dev/null)" || return 1
  [[ "$current" == "$uid" ]] || return 1
  git_checkout_permissions_safe "$path" || return 1
  git_checkout_config_safe "$path"
}

path_has_symlink_component() {
  local path="$1"
  local root="${2:-/}"
  local relative current component
  local -a components=()

  [[ "$path" == /* && "$root" == /* ]] || return 1
  if [[ "$root" == "/" ]]; then
    [[ "$path" == /* ]] || return 1
  else
    [[ "$path" == "$root" || "$path" == "$root"/* ]] || return 1
  fi

  relative="${path#"$root"}"
  relative="${relative#/}"
  current="$root"
  [[ "$current" == "/" ]] && current=""

  IFS='/' read -r -a components <<<"$relative"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == "." ]] && continue
    # Treat parent traversal as unsafe. Callers that need canonical paths must
    # resolve and validate them before asking this predicate.
    [[ "$component" == ".." ]] && return 0
    current="${current}/${component}"
    if [[ -L "$current" ]]; then
      return 0
    fi
    [[ -e "$current" ]] || break
  done
  return 1
}

init_private_dir() {
  local directory="$1"

  [[ "$directory" == /* ]] || {
    log_error "Private directory path must be absolute: $directory"
    return 1
  }
  [[ "$directory" != *..* ]] || {
    log_error "Private directory path must not contain '..': $directory"
    return 1
  }
  if path_has_symlink_component "$directory" /; then
    log_error "Refusing to use a private directory with a symlinked path: $directory"
    return 1
  fi

  # Create new path components owner-only from the start; a plain mkdir under
  # a permissive umask can leave a short window where another local user can
  # traverse a state/backup directory.
  local old_umask
  old_umask="$(umask)"
  umask 077
  mkdir -p "$directory"
  local mkdir_rc=$?
  umask "$old_umask"
  (( mkdir_rc == 0 )) || return 1
  [[ ! -L "$directory" ]] || {
    log_error "Refusing to use a symlink as a private directory: $directory"
    return 1
  }
  chmod_mode 700 "$directory"
}

# Create a directory exclusively. Returns 0 only if this process created it.
create_private_dir_exclusive() {
  local directory="${1:-}"
  local old_umask

  [[ -n "$directory" && "$directory" == /* && "$directory" != *..* ]] || return 1
  [[ ! -L "$directory" ]] || return 1
  old_umask="$(umask)"
  umask 077
  if mkdir "$directory" 2>/dev/null; then
    umask "$old_umask"
  else
    local rc=$?
    umask "$old_umask"
    return "$rc"
  fi
  chmod_mode 700 "$directory"
}

# Serialize destructive state operations. This is an advisory lock: it cannot
# stop a same-UID process that deliberately edits the repository or state, but
# it prevents two normal entrypoints from interleaving snapshots and journals.
STATE_LOCK_FD=""
STATE_LOCK_HELD=0
STATE_LOCK_DIR=""

# Format: pid<TAB>process-start-time<TAB>boot-id. The start time avoids
# treating a recycled PID as a live owner of a stale fallback lock.
state_lock_owner_tuple() {
  local pid="${1:-}"
  local start="" boot=""

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  start="$(process_start_time "$pid" 2>/dev/null || true)"
  boot="$(boot_identity 2>/dev/null || true)"
  printf '%s\t%s\t%s\n' "$pid" "$start" "$boot"
}

state_lock_owner_is_live() {
  local pidfile="$1"
  local owner_pid owner_start owner_boot current_start current_boot

  [[ -f "$pidfile" && ! -L "$pidfile" ]] || return 1
  IFS=$'\t' read -r owner_pid owner_start owner_boot <"$pidfile" || true
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null || return 1
  if [[ -n "$owner_start" ]]; then
    current_start="$(process_start_time "$owner_pid" 2>/dev/null || true)"
    [[ -n "$current_start" && "$current_start" == "$owner_start" ]] || return 1
  fi
  if [[ -n "$owner_boot" ]]; then
    current_boot="$(boot_identity 2>/dev/null || true)"
    [[ -n "$current_boot" && "$current_boot" == "$owner_boot" ]] || return 1
  fi
  return 0
}

state_lock_acquire() {
  local name="${1:-operation}"
  local lockfile

  (( STATE_LOCK_HELD == 1 )) && return 0
  [[ "$DRY_RUN" != "1" ]] || return 0
  init_private_dir "$STATE_DIR" || return 1
  lockfile="$STATE_DIR/${name}.lock"
  if have_command flock; then
    exec {STATE_LOCK_FD}>"$lockfile" || return 1
    chmod_mode 600 "$lockfile" 2>/dev/null || true
    if ! flock -n "$STATE_LOCK_FD"; then
      log_error "Another system-init operation is already running (lock: $lockfile)."
      eval "exec ${STATE_LOCK_FD}>&-"
      STATE_LOCK_FD=""
      return 1
    fi
    STATE_LOCK_HELD=1
    return 0
  fi

  # Portable fallback. A stale lock is detected by PID liveness.
  STATE_LOCK_DIR="$STATE_DIR/${name}.lock.d"
  local attempt=0
  while ! create_private_dir_exclusive "$STATE_LOCK_DIR"; do
    if ! state_lock_owner_is_live "$STATE_LOCK_DIR/pid"; then
      rm -rf -- "$STATE_LOCK_DIR" 2>/dev/null || true
      continue
    fi
    attempt=$((attempt + 1))
    (( attempt < 5 )) || {
      log_error "Another system-init operation is already running (lock: $STATE_LOCK_DIR)."
      return 1
    }
  done
  state_lock_owner_tuple "$$" >"$STATE_LOCK_DIR/pid" || return 1
  chmod_mode 600 "$STATE_LOCK_DIR/pid" 2>/dev/null || true
  STATE_LOCK_HELD=1
}

state_lock_release() {
  (( STATE_LOCK_HELD == 1 )) || return 0
  if [[ -n "$STATE_LOCK_FD" ]]; then
    flock -u "$STATE_LOCK_FD" 2>/dev/null || true
    eval "exec ${STATE_LOCK_FD}>&-"
    STATE_LOCK_FD=""
  fi
  if [[ -n "$STATE_LOCK_DIR" && -d "$STATE_LOCK_DIR" ]]; then
    rm -rf -- "$STATE_LOCK_DIR" 2>/dev/null || true
    STATE_LOCK_DIR=""
  fi
  STATE_LOCK_HELD=0
}

# safe_rm_rf() lives in lib/compat.sh and uses the native mount/deletion
# primitives for the current platform.

# Atomically create or replace a private state file. The temporary file is
# created inside the already-validated parent directory, so a symlink planted
# at the final path is replaced rather than followed.
write_private_file() {
  local file="${1:-}"
  local dir tmp

  [[ -n "$file" && "$file" == /* ]] || {
    log_error "Private file path must be absolute: ${file:-<empty>}"
    return 1
  }
  [[ "$file" != *..* ]] || {
    log_error "Private file path must not contain '..': $file"
    return 1
  }

  dir="$(dirname -- "$file")"
  [[ -d "$dir" && ! -L "$dir" ]] || {
    log_error "Private file directory is unsafe: $dir"
    return 1
  }

  tmp="$(mktemp "$dir/.$(basename -- "$file").XXXXXXXX")" || return 1
  chmod_mode 600 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  # The platform-specific replace keeps a symlink at the destination from
  # being followed.
  if ! mv_replace "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

init_state_dirs() {
  if [[ "$TARGET_HOME" != /* || "$TARGET_HOME" == "/" || ! -d "$TARGET_HOME" ]]; then
    log_error "Refusing to initialize state for an unsafe or missing target home: ${TARGET_HOME:-<empty>}"
    return 1
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "would initialize state directory: $STATE_DIR"
    LOG_FILE=""
    return 0
  fi
  init_private_dir "$STATE_DIR" || return 1
  init_private_dir "$LOG_DIR" || return 1
  init_private_dir "$BACKUP_DIR" || return 1
  init_private_dir "$JOURNAL_DIR" || return 1
  # shellcheck disable=SC2034
  LOG_FILE="$LOG_DIR/${DEV_SETUP_LOG_PREFIX:-system-init}-$(now_timestamp).log"
}

state_dir_is_safe() {
  local resolved

  [[ -n "$STATE_DIR" && "$STATE_DIR" == /* && "$STATE_DIR" != *..* ]] || return 1
  [[ ! -L "$STATE_DIR" ]] || return 1
  if path_has_symlink_component "$STATE_DIR" /; then
    return 1
  fi

  resolved="$(path_canonicalize "$STATE_DIR" 2>/dev/null)" || return 1
  [[ "$(basename -- "$resolved")" == "system-init" ]]
}

cleanup_tmp() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
    TMP_DIR=""
  fi
}

make_tmp_dir() {
  local tmp_base
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "would create a temporary directory"
    TMP_DIR=""
    return 0
  fi

  tmp_base="${TMPDIR:-/tmp}"
  if [[ "$tmp_base" != /* || -L "$tmp_base" ]]; then
    log_error "Refusing to use an unsafe temporary directory base: $tmp_base"
    TMP_DIR=""
    return 1
  fi
  # macOS exposes /var and /tmp as symlinks. Canonicalize the base so the
  # symlink-component checks do not reject every temporary path.
  if [[ -d "$tmp_base" ]]; then
    tmp_base="$(path_canonicalize "$tmp_base" 2>/dev/null || printf '%s' "$tmp_base")"
  fi
  TMP_DIR="$(mktemp -d "$tmp_base/system-init.XXXXXXXX")" || {
    TMP_DIR=""
    return 1
  }
  if [[ -L "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
    TMP_DIR=""
    return 1
  fi
}

# Lexical containment: judge a managed path by where it lives, not by where a
# leaf symlink points. This is what backup/dotfile handling needs, and it stays
# consistent when $TARGET_HOME itself is a symlink.
path_is_under() {
  local path="${1:-}" root="${2:-}"
  local resolved_path resolved_root

  [[ -n "$path" && -n "$root" ]] || return 1

  resolved_root="$(path_lexical "$root" 2>/dev/null)" || return 1
  resolved_path="$(path_lexical "$path" 2>/dev/null)" || return 1

  if [[ "$resolved_root" == "/" ]]; then
    [[ "$resolved_path" == /* && "$resolved_path" != "/" ]]
  else
    [[ "$resolved_path" == "$resolved_root"/* ]]
  fi
}

# Resolved containment: follow existing symlink components. Use this when the
# question is whether an operation would actually land outside a trusted root.
path_resolves_under() {
  local path="${1:-}" root="${2:-}"
  local resolved_path resolved_root

  [[ -n "$path" && -n "$root" ]] || return 1

  resolved_root="$(path_resolve "$root" 2>/dev/null)" || return 1
  resolved_path="$(path_resolve "$path" 2>/dev/null)" || return 1
  [[ "$resolved_path" == "$resolved_root"/* ]]
}

download_verify() {
  local url="$1"
  local destination="$2"
  local expected="$3"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "download and verify $(log_cmd "$url") -> $(log_cmd "$destination")"
    return 0
  fi

  require_command curl || return 1
  log_info "Downloading $url"
  curl -q --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --output "$destination" -- "$url"

  local actual
  actual="$(file_sha256 "$destination")"
  if [[ "$actual" != "$expected" ]]; then
    log_error "Checksum mismatch for $url"
    log_error "expected: $expected"
    log_error "actual:   $actual"
    return 1
  fi
  log_success "Checksum verified: $(basename -- "$destination")"
}

archive_member_is_safe() {
  local member="${1:-}"
  [[ -n "$member" ]] || return 1
  [[ "$member" != /* ]] || return 1
  [[ ! "$member" =~ [[:cntrl:]] ]] || return 1
  [[ ! "$member" =~ (^|/)\.\.(/|$) ]] || return 1
  return 0
}

extract_archive() {
  local archive="$1"
  local destination="$2"
  local member members

  if path_has_symlink_component "$destination" /; then
    log_error "Refusing archive extraction through a symlinked destination: $destination"
    return 1
  fi
  run mkdir -p -- "$destination"
  if path_has_symlink_component "$destination" /; then
    log_error "Archive destination became unsafe: $destination"
    return 1
  fi
  case "$archive" in
    *.tar.xz|*.tar.gz|*.tgz|*.tar.bz2|*.tar.zst)
      if ! members="$(tar -tf "$archive" 2>/dev/null)"; then
        log_error "Could not list archive members: $archive"
        return 1
      fi
      while IFS= read -r member; do
        if ! archive_member_is_safe "$member"; then
          log_error "Refusing archive member with an unsafe path: $member"
          return 1
        fi
      done <<<"$members"
      tar --no-same-owner --no-same-permissions -xf "$archive" -C "$destination"
      ;;
    *.zip)
      require_command unzip || return 1
      if ! members="$(unzip -Z1 "$archive" 2>/dev/null)"; then
        log_error "Could not list archive members: $archive"
        return 1
      fi
      while IFS= read -r member; do
        if ! archive_member_is_safe "$member"; then
          log_error "Refusing archive member with an unsafe path: $member"
          return 1
        fi
      done <<<"$members"
      unzip -q "$archive" -d "$destination"
      ;;
    *)
      log_error "Unsupported archive type: $archive"
      return 1
      ;;
  esac
}

parse_runtimes() {
  local line key value file="$REPO_ROOT/config/runtimes.conf"

  # A platform-specific file replaces the shared pins. macOS intentionally
  # installs Node.js LTS only, while Fedora keeps the shared set.
  if [[ -n "${PLATFORM:-}" && -f "$REPO_ROOT/config/runtimes.$PLATFORM.conf" ]]; then
    file="$REPO_ROOT/config/runtimes.$PLATFORM.conf"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    value="$(printf '%s' "$value" | tr -d '[:space:]')"
    [[ -z "$key" || -z "$value" ]] && continue
    printf '%s %s\n' "$key" "$value"
  done <"$file"
}

runtime_version() {
  local wanted="$1"
  parse_runtimes | awk -v tool="$wanted" '$1 == tool { print $2; exit }'
}

# Snapshot directories created by backup_init use this format. Ordering by
# name rather than mtime makes pruning immune to timestamp manipulation.
backup_snapshot_name_is_valid() {
  local name="${1:-}"
  local stamp human stamp_epoch now_epoch

  [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$ ]] || return 1
  stamp="${name%%-*}"
  human="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}"
  timestamp_valid "$human" || return 1
  stamp_epoch="$(timestamp_epoch "$human" 2>/dev/null)" || return 1
  now_epoch="$(date -u '+%s' 2>/dev/null)" || return 1
  # Reject future-dated names beyond a small clock-skew allowance; a future
  # name would otherwise occupy a retention slot and win --latest.
  (( stamp_epoch <= now_epoch + 3600 ))
}

prune_backups() {
  local keep="${DOTFILES_BACKUP_KEEP:-10}"
  local backup_root entry resolved
  local -a valid=()
  local index failed=0

  [[ "$keep" =~ ^[0-9]+$ ]] || return 0
  (( keep == 0 )) && return 0
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" ]] || return 0
  backup_root="$(path_canonicalize "$BACKUP_DIR" 2>/dev/null)" || return 0

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    resolved="$(backup_snapshot_path "$entry" 2>/dev/null)" || {
      log_debug "Preserving invalid or incomplete snapshot: $entry"
      continue
    }
    backup_snapshot_has_entries "$resolved" || {
      log_debug "Preserving empty snapshot: $resolved"
      continue
    }
    case "$(backup_snapshot_status "$resolved")" in
      signed|unsigned-v2|legacy-unverified) ;;
      *)
        log_debug "Preserving snapshot with unverified or invalid contents: $resolved"
        continue
        ;;
    esac
    valid+=("$resolved")
  done < <(list_backup_runs)

  # list_backup_runs is newest-first. Never remove below the keep count and
  # never count invalid/empty snapshots as retention slots.
  for (( index = keep; index < ${#valid[@]}; index++ )); do
    entry="${valid[$index]}"
    if [[ "$(dirname -- "$entry")" != "$backup_root" || -L "$entry" ]]; then
      log_warn "Refusing to prune a snapshot outside $BACKUP_DIR: $entry"
      continue
    fi
    if ! safe_rm_rf "$entry"; then
      log_error "Failed to prune backup snapshot: $entry"
      failed=1
    fi
  done
  return "$failed"
}

list_backup_runs() {
  [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" ]] || return 0
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d ! -type l -print \
    | while IFS= read -r entry; do
        backup_snapshot_name_is_valid "$(basename -- "$entry")" && printf '%s\n' "$entry"
      done \
    | sort -r
}
