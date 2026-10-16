#!/usr/bin/env bash
# Fedora platform adapter.
# shellcheck shell=bash

platform_specific_validate() {
  local failed=0

  if [[ -z "$FEDORA_VERSION" ]]; then
    record_failure "Could not determine the Fedora release."
    failed=1
  elif ! [[ "$FEDORA_VERSION" =~ ^[0-9]+$ ]]; then
    record_failure "Unsupported Fedora release identifier: $FEDORA_VERSION"
    failed=1
  elif (( FEDORA_VERSION < FEDORA_MIN_VERSION )); then
    record_failure "Fedora $FEDORA_VERSION is too old; Fedora $FEDORA_MIN_VERSION or newer is required."
    failed=1
  fi

  if ! platform_arch_supported; then
    record_failure "Unsupported architecture: $PLATFORM_ARCH (x86_64 or aarch64 required)."
    failed=1
  fi

  if [[ ! -d /run/systemd/system ]]; then
    record_failure "systemd is not running as PID 1; Fedora service management is unavailable."
    failed=1
  fi

  return "$failed"
}

platform_specific_preflight() {
  if ! have_command dnf; then
    record_failure "dnf is required on Fedora."
    return 1
  fi
  if ! have_command systemctl; then
    record_failure "systemctl is required on Fedora."
    return 1
  fi
  return 0
}

platform_specific_init() {
  log_info "Configuring Fedora package repositories..."
  fedora_ensure_repos
}

platform_specific_post_install() {
  fedora_flatpak_remote_ensure || record_warning "Flatpak remote could not be verified."
  return 0
}
