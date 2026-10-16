#!/usr/bin/env bash
# Virtualization module post-install hook.
# shellcheck shell=bash

module_post_install() {
  if [[ "$ENABLE_VIRTUALIZATION_SERVICES" != "1" ]]; then
    log_info "Virtualization service enablement is disabled in config/settings.conf."
    return 0
  fi

  if [[ "$DRY_RUN" != "1" && ! -e /dev/kvm ]]; then
    record_warning "/dev/kvm is missing. Enable AMD-V/Intel VT-x in firmware for KVM acceleration."
  fi

  fedora_libvirt_sockets_enable || return 1
  fedora_libvirt_network_check
}
