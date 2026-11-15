#!/usr/bin/env bash
# Atomic Git identity file handling.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_GIT_IDENTITY_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_GIT_IDENTITY_SOURCED=1

# Git config invocations must not be redirected by the caller's environment.
git_identity_config() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u GIT_CONFIG \
    -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_GLOBAL \
    -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_NOSYSTEM \
    git config "$@"
}

# Write user.name/user.email into a protected temporary regular file, validate
# the result, then atomically replace the destination. A symlink leaf is
# rejected rather than followed.
git_identity_write_atomic() {
  local target="${1:-}"
  local name="${2:-}"
  local email="${3:-}"
  local dir tmp written_name written_email

  [[ -n "$target" && "$target" == /* ]] || {
    log_error "Git identity destination must be an absolute path."
    return 1
  }
  [[ -n "$name" && -n "$email" ]] || {
    log_error "Git identity name and email must be non-empty."
    return 1
  }
  if [[ -L "$target" ]]; then
    log_error "Refusing to write Git identity through a symlink: $target"
    return 1
  fi
  if [[ -d "$target" && ! -L "$target" ]]; then
    log_error "Refusing to replace a directory with a Git identity file: $target"
    return 1
  fi
  dir="$(dirname -- "$target")"
  [[ -d "$dir" && ! -L "$dir" ]] || {
    log_error "Git identity destination directory is unsafe: $dir"
    return 1
  }

  tmp="$(mktemp -- "$dir/.gitconfig.local.XXXXXXXX")" || return 1
  chmod 600 -- "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [[ -f "$target" ]]; then
    if ! cp -- "$target" "$tmp"; then
      log_error "Could not copy the existing Git identity file."
      rm -f -- "$tmp"
      return 1
    fi
  fi

  if ! git_identity_config --file "$tmp" --replace-all user.name "$name"; then
    log_error "Failed to write Git user.name."
    rm -f -- "$tmp" "$tmp.lock"
    return 1
  fi
  if ! git_identity_config --file "$tmp" --replace-all user.email "$email"; then
    log_error "Failed to write Git user.email."
    rm -f -- "$tmp" "$tmp.lock"
    return 1
  fi
  written_name="$(git_identity_config --file "$tmp" --get user.name 2>/dev/null || true)"
  written_email="$(git_identity_config --file "$tmp" --get user.email 2>/dev/null || true)"
  if [[ "$written_name" != "$name" || "$written_email" != "$email" ]]; then
    log_error "Git identity verification failed in the temporary file."
    rm -f -- "$tmp" "$tmp.lock"
    return 1
  fi
  chmod 600 -- "$tmp" || { rm -f -- "$tmp" "$tmp.lock"; return 1; }
  if ! mv -fT -- "$tmp" "$target"; then
    log_error "Could not atomically install the Git identity file."
    rm -f -- "$tmp" "$tmp.lock"
    return 1
  fi
  rm -f -- "$tmp.lock"
  return 0
}
