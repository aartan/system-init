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
    log_dry "sudo dnf install -y ${missing[*]}"
    return 0
  fi

  run_sudo dnf install -y "${missing[@]}"
}

dnf_remove() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo dnf remove -y $*"
    return 0
  fi
  run_sudo dnf remove -y "$@"
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

  require_file "$source_file" || return 1

  if [[ -f "$target_file" ]]; then
    log_debug "DNF repository already present: $target_file"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo install -D -m0644 $(log_cmd "$source_file") $(log_cmd "$target_file")"
    return 0
  fi

  run_sudo install -D -m0644 -- "$source_file" "$target_file"
}
