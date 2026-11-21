#!/usr/bin/env bash
# Nerd Fonts installation.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_FONTS_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_FONTS_SOURCED=1

if [[ "$(uname -s)" == "Darwin" ]]; then
  # macOS scans the Fonts directory itself; do not rely on nested folders.
  FONT_DIR="${TARGET_HOME}/Library/Fonts"
else
  FONT_DIR="${TARGET_HOME}/.local/share/fonts/JetBrainsMono"
fi
FONT_REGULAR="$FONT_DIR/JetBrainsMonoNerdFont-Regular.ttf"

fonts_verify_installed() {
  [[ -f "$FONT_REGULAR" ]] || return 1
  [[ "$(file_sha256 "$FONT_REGULAR")" == "$NERD_FONTS_FONT_SHA256" ]]
}

# Replace an existing font or metadata file only after backing it up. The
# destination is a regular file in a validated, non-symlinked directory.
fonts_replace_file() {
  local source="$1"
  local destination="$2"

  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ -f "$destination" && ! -L "$destination" ]] && cmp -s "$source" "$destination"; then
      return 0
    fi
    if [[ -L "$destination" || ! -f "$destination" ]]; then
      record_failure "Refusing to replace an unsafe font path: $destination"
      return 1
    fi
    if ! declare -F backup_path >/dev/null 2>&1; then
      record_failure "Cannot back up the existing font before replacing it: $destination"
      return 1
    fi
    backup_path "$destination" "font-conflict" || return 1
    if [[ -n "${BACKUP_RUN_DIR:-}" && "${BACKUP_SNAPSHOT_COMPLETE:-0}" != "1" ]]; then
      backup_finalize || {
        record_failure "Could not finalize the font backup snapshot."
        return 1
      }
    fi
    rm -f -- "$destination" || return 1
  fi

  install -m 0644 "$source" "$destination"
}

fonts_install() {
  if fonts_verify_installed; then
    log_debug "Nerd Fonts v${NERD_FONTS_VERSION} JetBrainsMono is already installed."
    report_present "Nerd Fonts v${NERD_FONTS_VERSION} JetBrainsMono"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "download Nerd Fonts v${NERD_FONTS_VERSION}, verify SHA-256, install into $(log_cmd "$FONT_DIR")"
    if [[ "${PLATFORM:-fedora}" != "macos" ]]; then
      log_dry "fc-cache -f $(log_cmd "$FONT_DIR")"
    fi
    return 0
  fi

  require_command tar || return 1
  require_command curl || return 1
  make_tmp_dir || return 1

  local archive="$TMP_DIR/JetBrainsMono.tar.xz"
  local extract_dir="$TMP_DIR/fonts"
  local regular_extracted

  download_verify "$NERD_FONTS_URL" "$archive" "$NERD_FONTS_SHA256" || return 1
  extract_archive "$archive" "$extract_dir" || return 1

  regular_extracted="$extract_dir/JetBrainsMonoNerdFont-Regular.ttf"
  if [[ ! -f "$regular_extracted" ]]; then
    log_error "Nerd Fonts archive is missing the expected Regular font."
    return 1
  fi

  local regular_actual
  regular_actual="$(file_sha256 "$regular_extracted")"
  if [[ "$regular_actual" != "$NERD_FONTS_FONT_SHA256" ]]; then
    log_error "Nerd Fonts Regular font checksum mismatch."
    log_error "expected: $NERD_FONTS_FONT_SHA256"
    log_error "actual:   $regular_actual"
    return 1
  fi

  if [[ -L "$FONT_DIR" ]] || path_has_symlink_component "$FONT_DIR" "$TARGET_HOME"; then
    log_error "Refusing to install fonts through a symlinked directory: $FONT_DIR"
    return 1
  fi
  install -d -m 0755 "$FONT_DIR"
  if [[ -L "$FONT_DIR" ]] || path_has_symlink_component "$FONT_DIR" "$TARGET_HOME"; then
    log_error "Font installation directory became unsafe: $FONT_DIR"
    return 1
  fi
  local font destination
  for font in "$extract_dir"/*.ttf; do
    [[ -f "$font" ]] || continue
    destination="$FONT_DIR/$(basename -- "$font")"
    fonts_replace_file "$font" "$destination" || return 1
  done
  if [[ "${PLATFORM:-fedora}" != "macos" ]]; then
    if [[ -f "$extract_dir/OFL.txt" ]]; then
      fonts_replace_file "$extract_dir/OFL.txt" "$FONT_DIR/OFL.txt" || return 1
    fi
    if [[ -f "$extract_dir/README.md" ]]; then
      fonts_replace_file "$extract_dir/README.md" "$FONT_DIR/README.md" || return 1
    fi
  fi

  if ! fonts_verify_installed; then
    log_error "Font installation verification failed."
    return 1
  fi

  if [[ "${PLATFORM:-fedora}" == "macos" ]]; then
    log_debug "macOS reads fonts from ~/Library/Fonts without a cache refresh."
  elif have_command fc-cache; then
    fc-cache -f "$FONT_DIR" >/dev/null 2>&1 || log_warn "fc-cache failed; log out and back in to refresh fonts."
  else
    log_warn "fc-cache is not available; install fontconfig to refresh the font cache."
  fi

  log_success "Installed Nerd Fonts v${NERD_FONTS_VERSION} JetBrainsMono."
  report_installed "Nerd Fonts v${NERD_FONTS_VERSION} JetBrainsMono"
}
