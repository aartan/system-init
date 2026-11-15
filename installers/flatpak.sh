#!/usr/bin/env bash
# Flatpak adapter.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_FLATPAK_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_FLATPAK_SOURCED=1

flatpak_package_installed() {
  # Only a system installation is relevant to the privileged installer. A
  # user-level Flatpak with the same app ID must not shadow the system app.
  flatpak info --system -- "$1" >/dev/null 2>&1
}

# Return the URL configured for a system Flatpak remote, or empty if the
# remote is absent. Read-only; safe for doctor.
flatpak_system_remote_url() {
  local remote="${1:-${FLATPAK_REMOTE:-flathub}}"
  flatpak remotes --system --columns=name,url 2>/dev/null \
    | awk -v n="$remote" '$1 == n { print $2; exit }'
}

flatpak_remote_url_matches() {
  local remote="${1:-${FLATPAK_REMOTE:-flathub}}"
  local expected="${2:-${FLATPAK_REPO_URL:-https://flathub.org/repo/flathub.flatpakrepo}}"
  local actual
  actual="$(flatpak_system_remote_url "$remote")"
  [[ -n "$actual" && "$actual" == "$expected" ]]
}

flatpak_remote_ensure() {
  local remote="${FLATPAK_REMOTE:-flathub}"
  local url="${FLATPAK_REPO_URL:-https://flathub.org/repo/flathub.flatpakrepo}"

  if ! package_name_is_valid "$remote"; then
    log_error "Refusing invalid Flatpak remote name: $remote"
    return 1
  fi

  # Only accept HTTPS repository definitions. This blocks option injection and
  # prevents a modified settings file from pointing the system remote at a
  # local or attacker-controlled repository.
  if [[ "$url" != https://* || "$url" == *[[:space:]]* ]]; then
    log_error "Refusing invalid Flatpak repository URL: $url"
    return 1
  fi

  if ! have_command flatpak; then
    record_failure "flatpak is not installed; cannot manage Flatpak applications."
    return 1
  fi

  if flatpak remotes --system 2>/dev/null | awk 'NR > 0 { print $1 }' | grep -Fxq "$remote"; then
    if flatpak_remote_url_matches "$remote" "$url"; then
      log_debug "Flatpak remote already present with the expected URL: $remote"
      return 0
    fi
    log_error "Flatpak remote '$remote' exists with an unexpected URL; refusing to trust it."
    log_error "Expected: $url"
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak remote-add --if-not-exists --system $remote $url"
    return 0
  fi

  run_sudo flatpak remote-add --if-not-exists --system -- "$remote" "$url"
}

flatpak_install() {
  local -a missing=()
  local app
  local remote="${FLATPAK_REMOTE:-flathub}"

  if ! package_name_is_valid "$remote"; then
    log_error "Refusing invalid Flatpak remote name: $remote"
    return 1
  fi

  for app in "$@"; do
    if ! package_name_is_valid "$app"; then
      log_error "Refusing invalid Flatpak application name: $app"
      return 1
    fi
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

  run_sudo flatpak install --system -y --noninteractive "$remote" -- "${missing[@]}"
}

flatpak_remove() {
  local app
  for app in "$@"; do
    if ! package_name_is_valid "$app"; then
      log_error "Refusing invalid Flatpak application name: $app"
      return 1
    fi
  done

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak uninstall --system -y -- $*"
    return 0
  fi
  run_sudo flatpak uninstall --system -y -- "$@"
}

flatpak_update() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak update --system -y"
    return 0
  fi
  run_sudo flatpak update --system -y
}
