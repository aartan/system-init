#!/usr/bin/env bash
# Containers module post-install hook.
# shellcheck shell=bash

module_post_install() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "verify rootless Podman and podman-compose"
    return 0
  fi

  if podman info >/dev/null 2>&1; then
    local rootless
    rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
    if [[ "$rootless" == "true" ]]; then
      log_success "Podman is working rootless."
    else
      record_warning "Podman is installed but did not report rootless mode."
    fi
  else
    record_warning "Podman is installed but 'podman info' failed; open a new login session and retry."
  fi

  if have_command podman-compose && podman-compose --version >/dev/null 2>&1; then
    log_success "podman-compose is available."
  else
    record_warning "podman-compose is not available on PATH."
  fi
}
