#!/usr/bin/env bash
# mise installation and runtime management.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_MISE_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_MISE_SOURCED=1

MISE_BIN="${TARGET_HOME}/.local/bin/mise"

mise_installed_version() {
  [[ -x "$MISE_BIN" ]] || return 1
  "$MISE_BIN" --version 2>/dev/null | awk 'NR == 1 { print $1; exit }'
}

mise_install_binary() {
  local installed
  installed="$(mise_installed_version || true)"

  if [[ "$installed" == "$MISE_VERSION" ]]; then
    log_debug "mise $MISE_VERSION is already installed."
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "download mise v${MISE_VERSION}, verify SHA-256, install to ${TARGET_HOME}/.local/bin/mise"
    return 0
  fi

  require_command tar || return 1
  require_command curl || return 1
  make_tmp_dir

  local archive="$TMP_DIR/mise.tar.xz"
  local extract_dir="$TMP_DIR/mise"
  local share_dir="$TARGET_HOME/.local/share/mise"

  download_verify "$MISE_URL" "$archive" "$MISE_SHA256" || return 1
  extract_archive "$archive" "$extract_dir" || return 1

  if [[ ! -f "$extract_dir/mise/bin/mise" ]]; then
    log_error "mise archive does not contain mise/bin/mise"
    return 1
  fi

  install -d -m 0755 "$TARGET_HOME/.local/bin"
  install -m 0755 "$extract_dir/mise/bin/mise" "$MISE_BIN"

  if [[ -d "$extract_dir/mise/share" ]]; then
    install -d -m 0755 "$share_dir"
    cp -a "$extract_dir/mise/share/." "$share_dir/"
  fi

  install -d -m 0755 "$TARGET_HOME/.local/share/man/man1"
  if [[ -f "$extract_dir/mise/man/man1/mise.1" ]]; then
    install -m 0644 "$extract_dir/mise/man/man1/mise.1" \
      "$TARGET_HOME/.local/share/man/man1/mise.1"
  fi

  installed="$(mise_installed_version || true)"
  if [[ "$installed" != "$MISE_VERSION" ]]; then
    log_error "mise installation verification failed (got '${installed:-none}')"
    return 1
  fi

  log_success "Installed mise $MISE_VERSION"
}

mise_run() {
  # Run mise with the target home as HOME so that global config and data
  # directories are deterministic even when the installer is invoked with an
  # explicit DEV_SETUP_TARGET_HOME.
  HOME="$TARGET_HOME" "$MISE_BIN" "$@"
}

mise_install_runtimes() {
  local tool version

  if [[ "$DRY_RUN" == "1" ]]; then
    while read -r tool version; do
      [[ -z "$tool" ]] && continue
      log_dry "mise use --global ${tool}@${version}"
    done < <(parse_runtimes)
    return 0
  fi

  mise_install_binary || return 1

  while read -r tool version; do
    [[ -z "$tool" ]] && continue
    if ! mise_run use --global "${tool}@${version}"; then
      record_failure "mise failed to install ${tool} ${version}"
      continue
    fi
    log_success "mise: ${tool} ${version}"
  done < <(parse_runtimes)

  mise_verify_runtimes
}

mise_verify_runtimes() {
  local failed=0
  local tool version installed

  while read -r tool version; do
    [[ -z "$tool" ]] && continue
    case "$tool" in
      node) installed="$(mise_run exec -- node --version 2>/dev/null | sed 's/^v//')" ;;
      python) installed="$(mise_run exec -- python --version 2>/dev/null | awk '{print $2}')" ;;
      pnpm) installed="$(mise_run exec -- pnpm --version 2>/dev/null)" ;;
      *) installed="$(mise_run exec -- "$tool" --version 2>/dev/null | head -1)" ;;
    esac

    if [[ "$installed" != "$version" ]]; then
      record_failure "Runtime verification failed: ${tool} expected ${version}, got ${installed:-none}"
      failed=1
    else
      log_debug "Runtime verified: ${tool} ${installed}"
    fi
  done < <(parse_runtimes)

  if (( failed == 0 )); then
    log_success "All mise-managed runtimes verified."
  fi
  return "$failed"
}
