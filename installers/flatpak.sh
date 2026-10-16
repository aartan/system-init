#!/usr/bin/env bash
# Flatpak adapter.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_FLATPAK_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_FLATPAK_SOURCED=1

flatpak_package_installed() {
  flatpak info -- "$1" >/dev/null 2>&1
}

flatpak_remote_ensure() {
  local remote="${FLATPAK_REMOTE:-flathub}"
  local url="${FLATPAK_REPO_URL:-https://flathub.org/repo/flathub.flatpakrepo}"

  if ! have_command flatpak; then
    record_failure "flatpak is not installed; cannot manage Flatpak applications."
    return 1
  fi

  if flatpak remotes --system 2>/dev/null | awk 'NR > 0 { print $1 }' | grep -Fxq "$remote"; then
    log_debug "Flatpak remote already present: $remote"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak remote-add --if-not-exists --system $remote $url"
    return 0
  fi

  run_sudo flatpak remote-add --if-not-exists --system "$remote" "$url"
}

flatpak_install() {
  local -a missing=()
  local app
  local remote="${FLATPAK_REMOTE:-flathub}"

  for app in "$@"; do
    if flatpak_package_installed "$app"; then
      log_debug "Flatpak already installed: $app"
    else
      missing+=("$app")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    log_debug "All requested Flatpak applications are already installed."
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak install --system -y --noninteractive $remote ${missing[*]}"
    return 0
  fi

  run_sudo flatpak install --system -y --noninteractive "$remote" "${missing[@]}"
}

flatpak_remove() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak uninstall --system -y $*"
    return 0
  fi
  run_sudo flatpak uninstall --system -y "$@"
}

flatpak_update() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak update --system -y"
    return 0
  fi
  run_sudo flatpak update --system -y
}
