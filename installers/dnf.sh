#!/usr/bin/env bash
# DNF package adapter.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_DNF_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_DNF_SOURCED=1

dnf_package_installed() {
  # Query provides so virtual names such as zlib-devel resolve correctly on
  # releases where zlib-ng-compat-devel supplies them.
  rpm -q --whatprovides -- "$1" >/dev/null 2>&1
}

dnf_install() {
  local -a missing=()
  local package

  for package in "$@"; do
    if ! package_name_is_valid "$package"; then
      log_error "Refusing invalid DNF package name: $package"
      return 1
    fi
    if dnf_package_installed "$package"; then
      log_debug "DNF package already installed: $package"
    else
      missing+=("$package")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    log_debug "All requested DNF packages are already installed."
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo dnf install -y -- ${missing[*]}"
    return 0
  fi

  run_sudo dnf install -y -- "${missing[@]}"
}

dnf_remove() {
  local package
  for package in "$@"; do
    if ! package_name_is_valid "$package"; then
      log_error "Refusing invalid DNF package name: $package"
      return 1
    fi
  done

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo dnf remove -y -- $*"
    return 0
  fi
  run_sudo dnf remove -y -- "$@"
}

dnf_update() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo dnf upgrade --refresh -y"
    return 0
  fi
  run_sudo dnf upgrade --refresh -y
}

dnf_makecache() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo dnf makecache"
    return 0
  fi
  run_sudo dnf makecache
}

dnf_repo_ensure() {
  local source_file="$1"
  local target_file="$2"
  local expected_sha="${3:-}"
  local installed_sha stage_dir staged source_to_install

  require_file "$source_file" || return 1
  if [[ -L "$source_file" ]]; then
    log_error "Refusing a symlinked repository definition: $source_file"
    return 1
  fi
  if [[ -n "$expected_sha" ]]; then
    if [[ "$(file_sha256 "$source_file")" != "$expected_sha" ]]; then
      log_error "Repository definition does not match its pinned SHA-256: $source_file"
      return 1
    fi
  fi
  if [[ -L "$target_file" ]]; then
    log_error "Refusing to replace a symlinked repository file: $target_file"
    return 1
  fi

  if [[ -f "$target_file" ]] && cmp -s -- "$source_file" "$target_file"; then
    log_debug "DNF repository already up to date: $target_file"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo install -D -m0644 $(log_cmd "$source_file") $(log_cmd "$target_file")"
    return 0
  fi

  source_to_install="$source_file"
  if [[ -n "$expected_sha" ]]; then
    stage_dir="$(mktemp -d -- "${TMPDIR:-/tmp}/system-init-repo.XXXXXXXX")" || {
      log_error "Could not create a private staging directory for: $source_file"
      return 1
    }
    staged="$stage_dir/repo"
    if ! cp -- "$source_file" "$staged" \
      || [[ "$(file_sha256 "$staged" 2>/dev/null || true)" != "$expected_sha" ]]; then
      rm -rf -- "$stage_dir"
      log_error "Repository definition changed during verification: $source_file"
      return 1
    fi
    source_to_install="$staged"
  fi

  if ! run_sudo install -D -m0644 -- "$source_to_install" "$target_file"; then
    if [[ -n "${stage_dir:-}" ]]; then
      rm -rf -- "$stage_dir"
    fi
    return 1
  fi
  if [[ -n "${stage_dir:-}" ]]; then
    rm -rf -- "$stage_dir"
  fi

  if [[ -n "$expected_sha" ]]; then
    installed_sha="$(run_sudo sha256sum -- "$target_file" 2>/dev/null | awk '{ print $1; exit }')"
    if [[ "$installed_sha" != "$expected_sha" ]]; then
      run_sudo rm -f -- "$target_file" \
        || log_error "Could not remove the unpinned repository definition: $target_file"
      log_error "Installed repository definition does not match its pinned SHA-256: $target_file"
      return 1
    fi
  fi
}
