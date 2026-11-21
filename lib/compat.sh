#!/usr/bin/env bash
# Portable filesystem and process helpers.
#
# The shared code must run on Fedora (GNU tools) and macOS (BSD tools). This
# file centralises the small number of commands whose flags differ. Platform
# adapters may still use native tools directly.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_COMPAT_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_COMPAT_SOURCED=1

compat_kernel() {
  uname -s
}

compat_is_macos() {
  [[ "$(compat_kernel)" == "Darwin" ]]
}

compat_is_linux() {
  [[ "$(compat_kernel)" == "Linux" ]]
}

# Lexically normalise an absolute path. This deliberately does not resolve
# symlinks: callers use it for containment checks where the spelling matters.
path_lexical() {
  local path="${1:-}"
  local part result=""
  local -a parts=()

  [[ -n "$path" && "$path" == /* ]] || return 1
  IFS='/' read -r -a parts <<<"$path"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.)
        ;;
      ..)
        if [[ -n "$result" ]]; then
          result="${result%/*}"
        fi
        ;;
      *)
        result="$result/$part"
        ;;
    esac
  done
  printf '%s\n' "${result:-/}"
}

# Resolve an existing path, including a symlink leaf.
path_canonicalize() {
  local path="${1:-}"
  local dir base target

  [[ -n "$path" && "$path" == /* ]] || return 1
  [[ -e "$path" || -L "$path" ]] || return 1

  if realpath -e "$path" >/dev/null 2>&1; then
    realpath -e "$path"
    return 0
  fi
  if realpath "$path" >/dev/null 2>&1; then
    realpath "$path"
    return 0
  fi

  dir="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename "$path")"
  if [[ -L "$path" ]]; then
    target="$(readlink "$path" 2>/dev/null || true)"
    if [[ -n "$target" ]]; then
      if [[ "$target" == /* ]]; then
        path_canonicalize "$target"
      else
        path_canonicalize "$dir/$target"
      fi
      return 0
    fi
  fi
  printf '%s/%s\n' "${dir%/}" "$base"
}

# Resolve an absolute path that may not exist. Existing parent components are
# followed; the missing tail is normalised lexically.
path_resolve() {
  local path="${1:-}"
  local current suffix=""

  [[ -n "$path" && "$path" == /* ]] || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    path_canonicalize "$path"
    return 0
  fi

  current="$path"
  while [[ ! -e "$current" && ! -L "$current" && "$current" != "/" ]]; do
    suffix="/$(basename "$current")$suffix"
    current="$(dirname "$current")"
  done

  if [[ -e "$current" || -L "$current" ]]; then
    local resolved
    resolved="$(path_canonicalize "$current")" || return 1
    path_lexical "${resolved%/}$suffix"
  else
    path_lexical "$path"
  fi
}

file_sha256() {
  local file="${1:-}"
  if compat_is_macos || ! have_command sha256sum; then
    have_command shasum || return 1
    shasum -a 256 "$file" | awk '{ print $1; exit }'
  else
    sha256sum "$file" | awk '{ print $1; exit }'
  fi
}

string_sha256() {
  local value="${1:-}"
  if compat_is_macos || ! have_command sha256sum; then
    have_command shasum || return 1
    printf '%s' "$value" | shasum -a 256 | awk '{ print $1; exit }'
  else
    printf '%s' "$value" | sha256sum | awk '{ print $1; exit }'
  fi
}

file_size() {
  if compat_is_macos; then
    stat -f '%z' "$1"
  else
    stat -c '%s' "$1"
  fi
}

file_mode() {
  if compat_is_macos; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

file_owner_uid() {
  if compat_is_macos; then
    stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

timestamp_epoch() {
  local value="${1:-}"
  if date -u -d "$value" '+%s' >/dev/null 2>&1; then
    date -u -d "$value" '+%s'
  else
    date -u -j -f '%Y-%m-%d %H:%M:%S' "$value" '+%s' 2>/dev/null
  fi
}

timestamp_valid() {
  local value="${1:-}"
  local stamp epoch
  stamp="$(timestamp_epoch "$value" 2>/dev/null)" || return 1
  [[ "$stamp" =~ ^[0-9]+$ ]] || return 1
  epoch="$stamp"
  (( epoch >= 0 ))
}

timestamp_compact() {
  local epoch="${1:-}"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  if compat_is_macos; then
    date -u -r "$epoch" '+%Y%m%dT%H%M%SZ' 2>/dev/null
  else
    date -u -d "@$epoch" '+%Y%m%dT%H%M%SZ' 2>/dev/null
  fi
}

mv_replace() {
  local source="${1:-}"
  local destination="${2:-}"
  if compat_is_macos; then
    mv -fh "$source" "$destination"
  else
    mv -fT -- "$source" "$destination"
  fi
}

install_file() {
  local mode="${1:-0644}"
  local source="${2:-}"
  local destination="${3:-}"
  [[ -n "$source" && -n "$destination" ]] || return 1
  mkdir -p "$(dirname "$destination")" || return 1
  install -m "$mode" "$source" "$destination"
}

chmod_mode() {
  local mode="${1:-}"
  local path="${2:-}"
  [[ -n "$mode" && -n "$path" ]] || return 1
  if compat_is_macos; then
    chmod "$mode" "$path"
  else
    chmod "$mode" -- "$path"
  fi
}

make_temp_dir() {
  local base="${TMPDIR:-/tmp}"
  mktemp -d "$base/system-init.XXXXXXXX"
}

make_temp_file() {
  local base="${TMPDIR:-/tmp}"
  mktemp "$base/system-init.XXXXXXXX"
}

mount_points_all() {
  if compat_is_macos; then
    mount | sed -n 's/^.* on \(.*\) ([^()]*)$/\1/p'
  else
    findmnt -rn -o TARGET 2>/dev/null
  fi
}

mount_points_under() {
  local root="${1:-}"
  [[ -n "$root" && "$root" == /* ]] || return 1
  if compat_is_macos; then
    mount_points_all | awk -v root="$root" '
      $0 != root && (index($0, root "/") == 1) { print }
    '
  else
    findmnt -rn -o TARGET -R -- "$root" 2>/dev/null | awk -v root="$root" '$0 != root'
  fi
}

safe_rm_rf() {
  local target="${1:-}"
  local mount

  [[ -n "$target" && "$target" == /* && "$target" != "/" && "$target" != *..* ]] || return 1
  if path_has_symlink_component "$target" /; then
    log_error "Refusing recursive deletion through a symlinked path: $target"
    return 1
  fi
  [[ -e "$target" || -L "$target" ]] || return 0

  if compat_is_macos; then
    if [[ -L "$target" || ! -d "$target" ]]; then
      rm -f "$target"
      return $?
    fi
    if mount_points_all | grep -Fxq "$target"; then
      log_error "Refusing recursive deletion of a mount point: $target"
      return 1
    fi
    while IFS= read -r mount; do
      [[ -z "$mount" ]] && continue
      log_error "Refusing recursive deletion across mount point: $mount"
      return 1
    done < <(mount_points_under "$target")
    find "$target" -xdev -depth -delete
    return $?
  fi

  # Linux: fail closed if mount-point inspection is unavailable.
  if ! have_command findmnt || [[ ! -r /proc/self/mountinfo ]]; then
    log_error "Refusing recursive deletion: mount-point inspection is unavailable."
    return 1
  fi
  local target_mount
  if ! target_mount="$(findmnt -rn -o TARGET -T "$target" 2>/dev/null)"; then
    log_error "Refusing recursive deletion: cannot verify the target mount."
    return 1
  fi
  if [[ -n "$target_mount" && "$target_mount" == "$target" ]]; then
    log_error "Refusing recursive deletion of a mount point: $target"
    return 1
  fi
  while IFS= read -r mount; do
    [[ -z "$mount" || "$mount" == "$target" ]] && continue
    log_error "Refusing recursive deletion across mount point: $mount"
    return 1
  done < <(findmnt -rn -o TARGET -R -- "$target" 2>/dev/null || true)
  rm -rf --one-file-system -- "$target"
}

process_start_time() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if compat_is_macos; then
    ps -p "$pid" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  else
    local stat_line
    stat_line="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
    stat_line="${stat_line##*) }"
    awk '{ print $20 }' <<<"$stat_line"
  fi
}

boot_identity() {
  if compat_is_macos; then
    sysctl -n kern.boottime 2>/dev/null || true
  else
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
  fi
}

user_login_shell() {
  local user="${1:-}"
  [[ -n "$user" ]] || return 1
  if compat_is_macos; then
    dscl . -read "/Users/$user" UserShell 2>/dev/null | awk '{ print $2; exit }'
  else
    getent passwd "$user" 2>/dev/null | awk -F: '{ print $7; exit }'
  fi
}
