#!/usr/bin/env bash
# Platform detection and adapter loading.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_PLATFORM_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_PLATFORM_SOURCED=1

PLATFORM=""
PLATFORM_NAME=""
PLATFORM_SUPPORTED=0
PLATFORM_PACKAGE_MANAGERS=""
PLATFORM_ARCH=""
FEDORA_VERSION=""
# Consumed by platforms/fedora/platform.sh.
# shellcheck disable=SC2034
FEDORA_MIN_VERSION=43

platform_detect() {
  local kernel
  kernel="$(uname -s)"
  PLATFORM_ARCH="$(uname -m)"

  case "$kernel" in
    Linux)
      if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" == "fedora" ]]; then
          PLATFORM="fedora"
          # shellcheck disable=SC2034
          FEDORA_VERSION="${VERSION_ID:-}"
        else
          PLATFORM="linux-unsupported"
        fi
      else
        PLATFORM="linux-unsupported"
      fi
      ;;
    Darwin)
      PLATFORM="macos"
      ;;
    *)
      PLATFORM="unsupported"
      ;;
  esac
}

platform_load() {
  local config_file="$REPO_ROOT/platforms/$PLATFORM/platform.conf"
  if [[ ! -f "$config_file" ]]; then
    log_error "No platform adapter for '$PLATFORM'."
    return 1
  fi

  # shellcheck disable=SC1090
  source "$config_file"

  if [[ "$PLATFORM_SUPPORTED" != "1" ]]; then
    log_error "$PLATFORM_NAME support is scaffolded but not enabled in this release."
    log_error "This repository currently implements Fedora only. macOS support is Phase 2."
    return 1
  fi

  local adapter="$REPO_ROOT/platforms/$PLATFORM/platform.sh"
  if [[ ! -f "$adapter" ]]; then
    log_error "Platform adapter file missing: $adapter"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$adapter"

  local support
  for support in packages.sh system.sh; do
    if [[ -f "$REPO_ROOT/platforms/$PLATFORM/$support" ]]; then
      # shellcheck disable=SC1090
      source "$REPO_ROOT/platforms/$PLATFORM/$support"
    fi
  done
}

platform_validate() {
  if declare -F platform_specific_validate >/dev/null 2>&1; then
    platform_specific_validate
  fi
}

platform_preflight() {
  if declare -F platform_specific_preflight >/dev/null 2>&1; then
    platform_specific_preflight
  fi
}

platform_init() {
  if declare -F platform_specific_init >/dev/null 2>&1; then
    platform_specific_init
  fi
}

platform_post_install() {
  if declare -F platform_specific_post_install >/dev/null 2>&1; then
    platform_specific_post_install
  fi
}

platform_sudo_prepare() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "would validate sudo access"
    return 0
  fi

  if ! sudo_binary_valid; then
    log_error "sudo is required at $SUDO_BIN (absolute, executable, non-symlink)."
    return 1
  fi

  if "$SUDO_BIN" -n true >/dev/null 2>&1; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    log_error "sudo needs a password, but stdin is not a terminal."
    log_error "Run the installer interactively, or configure passwordless sudo."
    return 1
  fi

  log_info "Requesting sudo access for package and system changes..."
  "$SUDO_BIN" -v
}

platform_arch_supported() {
  case "$PLATFORM_ARCH" in
    x86_64|aarch64) return 0 ;;
    *) return 1 ;;
  esac
}

platform_arch() {
  printf '%s\n' "$PLATFORM_ARCH"
}

platform_supported_managers() {
  printf '%s\n' "$PLATFORM_PACKAGE_MANAGERS"
}
