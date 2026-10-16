#!/usr/bin/env bash
# keyd installation from a pinned source archive.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_KEYD_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_KEYD_SOURCED=1

KEYD_BIN=/usr/local/bin/keyd
KEYD_CONFIG=/etc/keyd/default.conf
KEYD_SERVICE=keyd.service

keyd_installed_version() {
  [[ -x "$KEYD_BIN" ]] || return 1
  "$KEYD_BIN" --version 2>/dev/null | awk 'NR == 1 { print $2; exit }'
}

keyd_binary_matches_pin() {
  local version
  version="$(keyd_installed_version || true)"
  [[ "$version" == "v${KEYD_VERSION}" ]]
}

keyd_config_matches_repo() {
  [[ -f "$KEYD_CONFIG" ]] || return 1
  local current expected
  current="$(file_sha256 "$KEYD_CONFIG" 2>/dev/null || true)"
  expected="$(file_sha256 "$REPO_ROOT/platforms/fedora/system/keyd.conf")"
  [[ "$current" == "$expected" ]]
}

keyd_build_install() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "download keyd v${KEYD_VERSION} source, verify SHA-256, build with make"
    log_dry "sudo make -C <keyd-source> install"
    return 0
  fi

  require_command gcc || return 1
  require_command make || return 1
  require_command tar || return 1

  make_tmp_dir

  local archive="$TMP_DIR/keyd.tar.gz"
  local source_dir="$TMP_DIR/keyd"

  download_verify "$KEYD_URL" "$archive" "$KEYD_SHA256" || return 1
  extract_archive "$archive" "$source_dir" || return 1

  local extracted
  extracted="$(find "$source_dir" -mindepth 1 -maxdepth 1 -type d -name 'keyd-*' -print -quit)"
  if [[ -z "$extracted" || ! -f "$extracted/Makefile" ]]; then
    log_error "keyd source archive has an unexpected layout."
    return 1
  fi

  if ! make -C "$extracted" -j"$(nproc)"; then
    log_error "keyd build failed."
    return 1
  fi

  if ! run_sudo make -C "$extracted" install; then
    log_error "keyd install failed."
    return 1
  fi

  if ! keyd_binary_matches_pin; then
    log_error "keyd version verification failed after install."
    return 1
  fi

  log_success "Built and installed keyd v${KEYD_VERSION} (${KEYD_COMMIT:0:7})."
}

keyd_install_config() {
  local changed=0

  if keyd_config_matches_repo; then
    log_debug "keyd configuration already matches the repository."
  else
    changed=1
    if [[ "$DRY_RUN" == "1" ]]; then
      log_dry "back up $(log_cmd "$KEYD_CONFIG") if present"
      log_dry "sudo install -D -m0644 platforms/fedora/system/keyd.conf $(log_cmd "$KEYD_CONFIG")"
    else
      if [[ -e "$KEYD_CONFIG" ]]; then
        backup_path "$KEYD_CONFIG" "system-config" || return 1
      fi
      run_sudo install -D -m0644 "$REPO_ROOT/platforms/fedora/system/keyd.conf" "$KEYD_CONFIG" || return 1
      log_success "Installed keyd configuration."
    fi
  fi

  if systemctl is-enabled "$KEYD_SERVICE" >/dev/null 2>&1; then
    log_debug "$KEYD_SERVICE is already enabled."
  else
    run_sudo systemctl enable "$KEYD_SERVICE" || return 1
  fi

  if systemctl is-active "$KEYD_SERVICE" >/dev/null 2>&1; then
    if [[ "$changed" == "1" ]]; then
      run_sudo systemctl restart "$KEYD_SERVICE" || return 1
      if [[ "$DRY_RUN" != "1" ]]; then
        log_success "Restarted $KEYD_SERVICE after configuration change."
      fi
    fi
  else
    run_sudo systemctl start "$KEYD_SERVICE" || return 1
  fi
}

keyd_install() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    log_error "keyd is only supported on Linux."
    return 1
  fi

  if keyd_binary_matches_pin; then
    log_debug "keyd v${KEYD_VERSION} is already installed."
  else
    keyd_build_install || return 1
  fi

  keyd_install_config || return 1
  if [[ "$DRY_RUN" != "1" ]]; then
    log_success "keyd is installed, configured, and active."
  else
    log_dry "keyd installation, configuration, and service state would be verified."
  fi
}
