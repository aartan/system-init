#!/usr/bin/env bash
# macOS system integration helpers.
# shellcheck shell=bash

POSTGRES_APP="/Applications/Postgres.app"
POSTGRES_BIN_DIR="$POSTGRES_APP/Contents/Versions/latest/bin"

macos_brew_service_started() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  brew services list 2>/dev/null \
    | awk -v n="$name" '$1 == n { print $2; exit }' \
    | grep -qx started
}

macos_brew_service_start() {
  local name="$1"

  [[ -n "$name" ]] || return 1
  if macos_brew_service_started "$name"; then
    log_debug "Homebrew service already started: $name"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "brew services start $name"
    return 0
  fi
  brew services start "$name" || return 1
  log_success "Started Homebrew service: $name"
}

macos_postgresql_enable() {
  local attempt=0

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "open -a Postgres.app and wait for pg_isready"
    return 0
  fi

  if [[ ! -d "$POSTGRES_APP" ]]; then
    record_failure "Postgres.app is not installed at $POSTGRES_APP."
    return 1
  fi

  if [[ -x "$POSTGRES_BIN_DIR/pg_isready" ]] \
    && "$POSTGRES_BIN_DIR/pg_isready" -q >/dev/null 2>&1; then
    log_debug "PostgreSQL is already accepting connections."
    return 0
  fi

  if ! open -a Postgres.app; then
    record_failure "Could not launch Postgres.app."
    return 1
  fi

  while (( attempt < 60 )); do
    if [[ -x "$POSTGRES_BIN_DIR/pg_isready" ]] \
      && "$POSTGRES_BIN_DIR/pg_isready" -q >/dev/null 2>&1; then
      log_success "PostgreSQL is accepting connections."
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  record_failure "Postgres.app did not become ready within 60 seconds."
  return 1
}

macos_valkey_enable() {
  macos_brew_service_start valkey || {
    record_failure "Failed to start Valkey with Homebrew services."
    return 1
  }
}

macos_virtualization_accel_check() {
  local hv
  hv="$(sysctl -n kern.hv_support 2>/dev/null || printf '0')"
  if [[ "$hv" == "1" ]]; then
    log_success "Apple Hypervisor framework is available."
  else
    record_warning "Apple Hypervisor framework is unavailable; UTM will run without hardware acceleration."
  fi
}

macos_virtualization_services_enable() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "verify that UTM is installed in /Applications"
    return 0
  fi
  if [[ -d "/Applications/UTM.app" ]]; then
    log_success "UTM is installed."
  else
    record_failure "UTM is not installed in /Applications."
    return 1
  fi
}

macos_virtualization_network_check() {
  # UTM uses Apple's networking; there is no libvirt default network to check.
  return 0
}

macos_podman_machine_prepare() {
  local name="${PODMAN_MACHINE_NAME:-default}"
  local list state

  if ! package_name_is_valid "$name"; then
    record_failure "Invalid Podman machine name: $name"
    return 1
  fi

  if [[ "${PODMAN_MACHINE_AUTO:-1}" != "1" ]]; then
    log_info "Automatic Podman machine setup is disabled (PODMAN_MACHINE_AUTO=0)."
    report_skipped "Podman machine auto-setup"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "ensure Podman machine '$name' exists and is running (podman machine init/start)"
    return 0
  fi

  if ! have_command podman; then
    record_failure "podman is not installed; cannot prepare the Podman machine."
    return 1
  fi

  if ! list="$(podman machine list --format '{{.Name}} {{.Running}}' 2>/dev/null)"; then
    record_failure "Could not list Podman machines."
    return 1
  fi

  # Podman appends "*" to the default machine name in formatted output.
  if awk -v n="$name" '
    {
      machine = $1
      sub(/\*$/, "", machine)
      if (machine == n) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' <<<"$list"; then
    state="$(awk -v n="$name" '
      {
        machine = $1
        sub(/\*$/, "", machine)
        if (machine == n) { print $2; exit }
      }
    ' <<<"$list")"
    if [[ "$state" == "true" ]]; then
      log_debug "Podman machine '$name' is already running."
      report_present "Podman machine '$name'"
    else
      log_info "Starting existing Podman machine '$name'..."
      podman machine start "$name" || {
        record_failure "Failed to start Podman machine '$name'."
        return 1
      }
      report_installed "Podman machine '$name' start"
    fi
  else
    log_info "Initializing Podman machine '$name'..."
    podman machine init "$name" || {
      record_failure "Failed to initialize Podman machine '$name'."
      return 1
    }
    podman machine start "$name" || {
      record_failure "Failed to start Podman machine '$name'."
      return 1
    }
    report_installed "Podman machine '$name'"
  fi

  if podman info >/dev/null 2>&1; then
    log_success "Podman machine '$name' is ready."
  else
    record_failure "Podman machine '$name' is running but 'podman info' failed."
    return 1
  fi
}
