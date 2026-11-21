#!/usr/bin/env bash
# Virtualization module post-install hook.
# shellcheck shell=bash

module_post_install() {
  if [[ "$ENABLE_VIRTUALIZATION_SERVICES" != "1" ]]; then
    log_info "Virtualization service enablement is disabled in config/settings.conf."
    report_skipped "virtualization services"
    return 0
  fi

  virtualization_accel_check
  virtualization_services_enable || return 1
  virtualization_network_check
}
