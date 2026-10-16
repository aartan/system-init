#!/usr/bin/env bash
# Homebrew adapter library for the future macOS phase.
# Fedora does not invoke these functions.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_BREW_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_BREW_SOURCED=1

brew_require() {
  if ! have_command brew; then
    log_error "Homebrew is not installed. macOS support is not enabled in this release."
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

  brew install "${missing[@]}"
}

brew_cask_install() {
  local -a missing=()
  local package

  brew_require || return 1

  for package in "$@"; do
    if brew_cask_installed "$package"; then
      log_debug "Homebrew cask already installed: $package"
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

  brew install --cask "${missing[@]}"
}

brew_update() {
  brew_require || return 1
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "brew update && brew upgrade"
    return 0
  fi
  brew update
  brew upgrade
}
