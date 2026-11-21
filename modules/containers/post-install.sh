#!/usr/bin/env bash
# Containers module post-install hook.
# shellcheck shell=bash

module_post_install() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "prepare the container runtime and verify podman-compose"
    return 0
  fi

  container_runtime_prepare || return 1

  if podman info >/dev/null 2>&1; then
    if [[ "$PLATFORM" == "macos" ]]; then
      log_success "Podman machine is reachable."
    else
      local rootless
      rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
      if [[ "$rootless" == "true" ]]; then
        log_success "Podman is working rootless."
      else
        record_warning "Podman is installed but did not report rootless mode."
      fi
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
