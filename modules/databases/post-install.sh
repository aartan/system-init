#!/usr/bin/env bash
# Databases module post-install hook.
# shellcheck shell=bash

module_post_install() {
  if [[ "$ENABLE_DATABASE_SERVICES" != "1" ]]; then
    log_info "Database service enablement is disabled in config/settings.conf."
    report_skipped "database services"
    return 0
  fi

  database_postgresql_enable || return 1
  database_valkey_enable || return 1
}
