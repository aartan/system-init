#!/usr/bin/env bash
# Fedora system integration helpers.
# shellcheck shell=bash

fedora_service_is_enabled() {
  systemctl is-enabled "$1" >/dev/null 2>&1
}

fedora_service_is_active() {
  systemctl is-active "$1" >/dev/null 2>&1
}

fedora_service_enable_now() {
  local unit="$1"

  if fedora_service_is_enabled "$unit" && fedora_service_is_active "$unit"; then
    log_debug "Service already enabled and active: $unit"
    return 0
  fi

  if fedora_service_is_enabled "$unit"; then
    run_sudo systemctl start "$unit" || return 1
  else
    run_sudo systemctl enable --now "$unit" || return 1
  fi
  if [[ "$DRY_RUN" != "1" ]]; then
    log_success "Service enabled and started: $unit"
  fi
}

fedora_postgresql_init() {
  local data_dir=/var/lib/pgsql/data

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "initialize the PostgreSQL cluster with postgresql-setup --initdb only if ${data_dir}/PG_VERSION is absent"
    return 0
  fi

  if run_sudo test -s "$data_dir/PG_VERSION"; then
    log_debug "PostgreSQL cluster already initialized."
    return 0
  fi

  run_sudo postgresql-setup --initdb || {
    record_failure "PostgreSQL cluster initialization failed."
    return 1
  }
  log_success "Initialized the PostgreSQL cluster."
}

fedora_postgresql_enable() {
  fedora_postgresql_init || return 1
  fedora_service_enable_now postgresql.service || {
    record_failure "Failed to enable PostgreSQL."
    return 1
  }
}

fedora_valkey_enable() {
  fedora_service_enable_now valkey.service || {
    record_failure "Failed to enable Valkey."
    return 1
  }
}

fedora_libvirt_sockets_enable() {
  local -a units=(
    virtqemud.socket
    virtnetworkd.socket
    virtstoraged.socket
    virtlogd.socket
    virtlockd.socket
    virtnwfilterd.socket
  )
  local unit
  local failed=0

  for unit in "${units[@]}"; do
    if ! fedora_service_enable_now "$unit"; then
      record_failure "Failed to enable $unit"
      failed=1
    fi
  done

  return "$failed"
}

fedora_libvirt_network_check() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "verify the libvirt 'default' NAT network and start it if inactive"
    return 0
  fi

  local networks
  networks="$(run_sudo virsh -c qemu:///system net-list --all 2>/dev/null || true)"
  if ! grep -Eq '[[:space:]]default[[:space:]]' <<<"$networks"; then
    record_warning "The libvirt 'default' network is not defined; virt-manager can create one."
    return 0
  fi

  if grep -Eq '[[:space:]]default[[:space:]]+active' <<<"$networks"; then
    log_debug "libvirt default network is active."
    return 0
  fi

  run_sudo virsh -c qemu:///system net-start default || \
    record_warning "Could not start the libvirt 'default' network."
  run_sudo virsh -c qemu:///system net-autostart default || \
    record_warning "Could not autostart the libvirt 'default' network."
}

# Platform-neutral hooks used by module post-install scripts.
database_postgresql_enable() {
  fedora_postgresql_enable
}

database_valkey_enable() {
  fedora_valkey_enable
}

virtualization_accel_check() {
  if [[ "$DRY_RUN" != "1" && ! -e /dev/kvm ]]; then
    record_warning "/dev/kvm is missing. Enable AMD-V/Intel VT-x in firmware for KVM acceleration."
  fi
  return 0
}

virtualization_services_enable() {
  fedora_libvirt_sockets_enable
}

virtualization_network_check() {
  fedora_libvirt_network_check
}

container_runtime_prepare() {
  # Fedora runs Podman natively; the containers module verifies rootless mode.
  return 0
}
