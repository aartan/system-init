#!/usr/bin/env bash
# Databases module post-install hook.
# shellcheck shell=bash

module_post_install() {
  if [[ "$ENABLE_DATABASE_SERVICES" != "1" ]]; then
    log_info "Database service enablement is disabled in config/settings.conf."
    return 0
  fi

  fedora_postgresql_enable || return 1
  fedora_valkey_enable || return 1
}
