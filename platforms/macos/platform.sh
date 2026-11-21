#!/usr/bin/env bash
# macOS platform adapter (Apple Silicon only).
# shellcheck shell=bash

MACOS_VERSION=""
MACOS_MAJOR=""

platform_specific_validate() {
  local failed=0

  if [[ "$(uname -s)" != "Darwin" ]]; then
    record_failure "The macOS adapter was loaded on a non-Darwin system."
    return 1
  fi

  MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || true)"
  MACOS_MAJOR="${MACOS_VERSION%%.*}"
  if ! [[ "$MACOS_MAJOR" =~ ^[0-9]+$ ]]; then
    record_failure "Could not determine the macOS version."
    failed=1
  elif (( MACOS_MAJOR < MACOS_MIN_VERSION )); then
    record_failure "macOS $MACOS_VERSION is too old; macOS $MACOS_MIN_VERSION or newer is required."
    failed=1
  fi

  if [[ "$PLATFORM_ARCH" != "aarch64" ]]; then
    record_failure "Unsupported architecture: $PLATFORM_ARCH (Apple Silicon arm64 is required)."
    failed=1
  fi

  if [[ ! -x /bin/zsh ]]; then
    record_failure "The system zsh at /bin/zsh is missing."
    failed=1
  fi

  return "$failed"
}

platform_specific_preflight() {
  if [[ ! -x "$BREW_BIN" ]]; then
    record_failure "Homebrew is required at $BREW_BIN; run install.sh to bootstrap it."
    return 1
  fi

  if ! "$BREW_BIN" --prefix >/dev/null 2>&1; then
    record_failure "Homebrew at $BREW_BIN is not usable."
    return 1
  fi

  if [[ "$("$BREW_BIN" --prefix 2>/dev/null)" != "$BREW_PREFIX" ]]; then
    record_failure "Homebrew is not installed at the expected Apple Silicon prefix $BREW_PREFIX."
    return 1
  fi

  return 0
}

platform_specific_init() {
  log_debug "macOS uses Homebrew formulae and casks; no repository setup is required."
  return 0
}

platform_specific_post_install() {
  return 0
}

# Platform-neutral service hooks used by module post-install scripts.
database_postgresql_enable() {
  macos_postgresql_enable
}

database_valkey_enable() {
  macos_valkey_enable
}

virtualization_accel_check() {
  macos_virtualization_accel_check
}

virtualization_services_enable() {
  macos_virtualization_services_enable
}

virtualization_network_check() {
  macos_virtualization_network_check
}

container_runtime_prepare() {
  macos_podman_machine_prepare
}
