#!/usr/bin/env bash
# Homebrew adapter library.
# Homebrew is always run as the target user, never through sudo.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_BREW_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_BREW_SOURCED=1

export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"
export HOMEBREW_NO_ANALYTICS="${HOMEBREW_NO_ANALYTICS:-1}"

brew_prefix() {
  brew --prefix 2>/dev/null
}

brew_require() {
  if ! have_command brew; then
    log_error "Homebrew is not installed. Run ./install.sh to bootstrap it."
    return 1
  fi
}

brew_package_installed() {
  brew list --formula "$1" >/dev/null 2>&1
}

brew_cask_installed() {
  brew list --cask "$1" >/dev/null 2>&1
}

brew_install() {
  local -a missing=()
  local package

  brew_require || return 1

  for package in "$@"; do
    if brew_package_installed "$package"; then
      log_debug "Homebrew formula already installed: $package"
      report_present "brew:$package"
    else
      missing+=("$package")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "brew install ${missing[*]}"
    return 0
  fi

  if ! brew install "${missing[@]}"; then
    report_failed "brew:${missing[*]}"
    return 1
  fi
  for package in "${missing[@]}"; do
    report_installed "brew:$package"
  done
}

brew_cask_install() {
  local -a missing=()
  local package

  brew_require || return 1

  for package in "$@"; do
    if brew_cask_installed "$package"; then
      log_debug "Homebrew cask already installed: $package"
      report_present "cask:$package"
    else
      missing+=("$package")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "brew install --cask ${missing[*]}"
    return 0
  fi

  if ! brew install --cask "${missing[@]}"; then
    report_failed "cask:${missing[*]}"
    return 1
  fi
  for package in "${missing[@]}"; do
    report_installed "cask:$package"
  done
}

brew_remove_formulae() {
  [[ $# -gt 0 ]] || return 0
  brew_require || return 1
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "brew uninstall $*"
    return 0
  fi
  brew uninstall "$@"
}

brew_remove_casks() {
  [[ $# -gt 0 ]] || return 0
  brew_require || return 1
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "brew uninstall --cask $*"
    return 0
  fi
  brew uninstall --cask "$@"
}

brew_update() {
  brew_require || return 1
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "brew update && brew upgrade --formula && brew upgrade --cask"
    return 0
  fi
  brew update || return 1
  brew upgrade --formula || return 1
  brew upgrade --cask || return 1
}

brew_service_start() {
  local name="$1"
  brew_require || return 1
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "brew services start $name"
    return 0
  fi
  brew services start "$name"
}

brew_service_stop() {
  local name="$1"
  brew_require || return 1
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "brew services stop $name"
    return 0
  fi
  brew services stop "$name" 2>/dev/null || true
}
