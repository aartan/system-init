#!/usr/bin/env bash
# Shared helpers for system-init.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_COMMON_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_COMMON_SOURCED=1

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
TARGET_HOME="${DEV_SETUP_TARGET_HOME:-$HOME}"
# Used by the backup and shell installers.
# shellcheck disable=SC2034
TARGET_USER="${DEV_SETUP_TARGET_USER:-$(id -un)}"
STATE_DIR="${XDG_STATE_HOME:-$TARGET_HOME/.local/state}/system-init"
LOG_DIR="$STATE_DIR/logs"
BACKUP_DIR="$STATE_DIR/backups"
JOURNAL_DIR="$STATE_DIR/journal"
TMP_DIR=""
DRY_RUN="${DRY_RUN:-0}"
DEBUG="${DEBUG:-0}"

# shellcheck source=../config/settings.conf
source "$REPO_ROOT/config/settings.conf"
# shellcheck source=../config/pins.conf
source "$REPO_ROOT/config/pins.conf"

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
  log_debug "exec: sudo $(log_cmd "$@")"
  sudo -- "$@"
}

ensure_dir() {
  local directory="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "mkdir -p $(log_cmd "$directory")"
    return 0
  fi
  mkdir -p -- "$directory"
}

init_state_dirs() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "would initialize state directory: $STATE_DIR"
    LOG_FILE=""
    return 0
  fi
  mkdir -p -- "$LOG_DIR" "$BACKUP_DIR" "$JOURNAL_DIR"
  chmod 700 -- "$STATE_DIR" "$LOG_DIR" "$BACKUP_DIR" "$JOURNAL_DIR"
  # shellcheck disable=SC2034
  LOG_FILE="$LOG_DIR/${DEV_SETUP_LOG_PREFIX:-system-init}-$(now_timestamp).log"
}

cleanup_tmp() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
    TMP_DIR=""
  fi
}

make_tmp_dir() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "would create a temporary directory"
    TMP_DIR=""
    return 0
  fi
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/system-init.XXXXXXXX")"
}

path_is_under() {
  local path resolved_root resolved_path
  path="$1"
  # -s keeps the check lexical: a managed symlink must be judged by where it
  # lives, not by the path it points to.
  resolved_root="$(realpath -m -s -- "$2")"
  resolved_path="$(realpath -m -s -- "$path")"
  [[ "$resolved_path" == "$resolved_root" || "$resolved_path" == "$resolved_root"/* ]]
}

file_sha256() {
  sha256sum -- "$1" | awk '{print $1}'
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
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
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

extract_archive() {
  local archive="$1"
  local destination="$2"
  run mkdir -p -- "$destination"
  case "$archive" in
    *.tar.xz|*.tar.gz|*.tgz|*.tar.bz2|*.tar.zst)
      tar -xf "$archive" -C "$destination"
      ;;
    *.zip)
      require_command unzip || return 1
      unzip -q "$archive" -d "$destination"
      ;;
    *)
      log_error "Unsupported archive type: $archive"
      return 1
      ;;
  esac
}

parse_runtimes() {
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    value="$(printf '%s' "$value" | tr -d '[:space:]')"
    [[ -z "$key" || -z "$value" ]] && continue
    printf '%s %s\n' "$key" "$value"
  done <"$REPO_ROOT/config/runtimes.conf"
}

runtime_version() {
  local wanted="$1"
  parse_runtimes | awk -v tool="$wanted" '$1 == tool { print $2; exit }'
}

prune_backups() {
  local keep="${DOTFILES_BACKUP_KEEP:-10}"
  [[ "$keep" =~ ^[0-9]+$ ]] || return 0
  (( keep == 0 )) && return 0
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ -d "$BACKUP_DIR" ]] || return 0
  local count=0
  local entry
  while IFS= read -r entry; do
    count=$((count + 1))
    if (( count > keep )); then
      rm -rf -- "$entry"
    fi
  done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
    | sort -rn | awk '{ $1=""; sub(/^ /, ""); print }')
}

list_backup_runs() {
  [[ -d "$BACKUP_DIR" ]] || return 0
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
    | sort -rn | awk '{ $1=""; sub(/^ /, ""); print }'
}
