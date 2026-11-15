#!/usr/bin/env bash
# mise installation and runtime management.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_MISE_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_MISE_SOURCED=1

MISE_BIN="${TARGET_HOME}/.local/bin/mise"

# The pinned mise release is linux-x64. Never install or execute an x86-64
# binary on another architecture; aarch64 support requires independently
# verified arm64 archive and binary pins.
mise_arch_supported() {
  case "${PLATFORM_ARCH:-}" in
    x86_64) return 0 ;;
    *) return 1 ;;
  esac
}

mise_binary_trusted() {
  mise_arch_supported || return 1
  [[ -f "$MISE_BIN" && ! -L "$MISE_BIN" && -x "$MISE_BIN" ]] || return 1
  [[ -n "${MISE_BIN_SHA256:-}" ]] || return 1
  [[ "$(file_sha256 "$MISE_BIN" 2>/dev/null || true)" == "$MISE_BIN_SHA256" ]]
}

mise_installed_version() {
  mise_binary_trusted || return 1
  "$MISE_BIN" --version 2>/dev/null | awk 'NR == 1 { print $1; exit }'
}

mise_install_binary() {
  local installed

  if ! mise_arch_supported; then
    record_failure "mise is pinned to the linux-x64 release; refusing to install on ${PLATFORM_ARCH:-unknown}."
    return 1
  fi

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
  make_tmp_dir || return 1

  local archive="$TMP_DIR/mise.tar.xz"
  local extract_dir="$TMP_DIR/mise"
  local share_dir="$TARGET_HOME/.local/share/mise"
  local extracted_bin="$extract_dir/mise/bin/mise"
  local install_dir="$TARGET_HOME/.local/bin"

  download_verify "$MISE_URL" "$archive" "$MISE_SHA256" || return 1
  extract_archive "$archive" "$extract_dir" || return 1

  if [[ ! -f "$extracted_bin" || -L "$extracted_bin" ]]; then
    log_error "mise archive does not contain a regular mise/bin/mise binary"
    return 1
  fi
  if [[ -n "${MISE_BIN_SHA256:-}" ]]; then
    local extracted_sha
    extracted_sha="$(file_sha256 "$extracted_bin")"
    if [[ "$extracted_sha" != "$MISE_BIN_SHA256" ]]; then
      log_error "mise binary checksum mismatch (expected $MISE_BIN_SHA256, got $extracted_sha)"
      return 1
    fi
  fi

  if path_has_symlink_component "$install_dir" "$TARGET_HOME"; then
    log_error "Refusing to install mise through a symlinked directory: $install_dir"
    return 1
  fi
  install -d -m 0755 "$install_dir"
  install -m 0755 "$extracted_bin" "$MISE_BIN"
  if [[ -L "$MISE_BIN" ]] || ! mise_binary_trusted; then
    log_error "mise binary verification failed after installation."
    return 1
  fi

  if [[ -d "$extract_dir/mise/share" ]]; then
    if [[ -L "$share_dir" ]] || path_has_symlink_component "$share_dir" "$TARGET_HOME"; then
      log_error "Refusing to install mise share files through a symlinked directory: $share_dir"
      return 1
    fi
    install -d -m 0755 "$share_dir"
    if [[ -L "$share_dir" ]] || path_has_symlink_component "$share_dir" "$TARGET_HOME"; then
      log_error "mise share directory became unsafe: $share_dir"
      return 1
    fi
    cp -a "$extract_dir/mise/share/." "$share_dir/"
  fi

  local man_dir="$TARGET_HOME/.local/share/man/man1"
  if [[ -L "$man_dir" ]] || path_has_symlink_component "$man_dir" "$TARGET_HOME"; then
    log_error "Refusing to install mise manual pages through a symlinked directory: $man_dir"
    return 1
  fi
  install -d -m 0755 "$man_dir"
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
  # explicit DEV_SETUP_TARGET_HOME. Only an intact pinned binary is executed.
  if ! mise_binary_trusted; then
    log_error "Refusing to run mise: $MISE_BIN is missing, symlinked, or does not match the pinned checksum."
    return 1
  fi
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

# Read-only runtime inspection for doctor. This must not call `mise exec`,
# which can auto-install a missing runtime and mutate the user's state.
mise_verify_runtimes_readonly() {
  local failed=0
  local tool version installed output

  if ! mise_binary_trusted; then
    record_failure "mise binary is missing or does not match the pinned checksum."
    return 1
  fi

  while read -r tool version; do
    [[ -z "$tool" ]] && continue
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      record_failure "Runtime pin for ${tool} is not an exact version: ${version:-none}"
      failed=1
      continue
    fi
    output="$(MISE_OFFLINE=1 mise_run ls --installed "$tool" 2>/dev/null || true)"
    installed="$(awk -v t="$tool" '$1 == t { print $2; exit }' <<<"$output")"
    if [[ -z "$installed" ]]; then
      record_failure "Runtime is not installed or not inspectable: ${tool} (expected ${version})"
      failed=1
    elif [[ "$installed" != "$version" ]]; then
      record_failure "Runtime verification failed: ${tool} expected ${version}, got ${installed:-none}"
      failed=1
    else
      log_debug "Runtime verified (read-only): ${tool} ${installed}"
    fi
  done < <(parse_runtimes)

  if (( failed == 0 )); then
    log_success "All mise-managed runtimes are installed at their pinned versions."
  fi
  return "$failed"
}

mise_verify_runtimes() {
  local failed=0
  local tool version installed

  if ! mise_binary_trusted; then
    record_failure "mise binary is missing or does not match the pinned checksum."
    return 1
  fi

  while read -r tool version; do
    [[ -z "$tool" ]] && continue

    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      record_failure "Runtime pin for ${tool} is not an exact version: ${version:-none}"
      failed=1
      continue
    fi

    case "$tool" in
      node) installed="$(mise_run exec -- node --version 2>/dev/null | sed 's/^v//')" ;;
      python) installed="$(mise_run exec -- python --version 2>/dev/null | awk '{print $2}')" ;;
      pnpm) installed="$(mise_run exec -- pnpm --version 2>/dev/null)" ;;
      *) installed="$(mise_run exec -- "$tool" --version 2>/dev/null | head -1)" ;;
    esac

    installed="$(printf '%s\n' "$installed" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

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
