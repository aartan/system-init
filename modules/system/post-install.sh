#!/usr/bin/env bash
# System module post-install hook.
# shellcheck shell=bash

module_post_install() {
  if [[ "$ENABLE_KEYD" != "1" ]]; then
    log_info "keyd is disabled in config/settings.conf; skipping."
    return 0
  fi

  keyd_install
}
