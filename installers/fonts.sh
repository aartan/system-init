#!/usr/bin/env bash
# Nerd Fonts installation.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_FONTS_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_FONTS_SOURCED=1

FONT_DIR="${TARGET_HOME}/.local/share/fonts/JetBrainsMono"
FONT_REGULAR="$FONT_DIR/JetBrainsMonoNerdFont-Regular.ttf"

fonts_verify_installed() {
  [[ -f "$FONT_REGULAR" ]] || return 1
  [[ "$(file_sha256 "$FONT_REGULAR")" == "$NERD_FONTS_FONT_SHA256" ]]
}

fonts_install() {
  if fonts_verify_installed; then
    log_debug "Nerd Fonts v${NERD_FONTS_VERSION} JetBrainsMono is already installed."
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "download Nerd Fonts v${NERD_FONTS_VERSION}, verify SHA-256, install into $(log_cmd "$FONT_DIR")"
    log_dry "fc-cache -f $(log_cmd "$FONT_DIR")"
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
  local font
  for font in "$extract_dir"/*.ttf; do
    [[ -f "$font" ]] || continue
    install -m 0644 "$font" "$FONT_DIR/$(basename -- "$font")"
  done
  if [[ -f "$extract_dir/OFL.txt" ]]; then
    install -m 0644 "$extract_dir/OFL.txt" "$FONT_DIR/OFL.txt"
  fi
  if [[ -f "$extract_dir/README.md" ]]; then
    install -m 0644 "$extract_dir/README.md" "$FONT_DIR/README.md"
  fi

  if ! fonts_verify_installed; then
    log_error "Font installation verification failed."
    return 1
  fi

  if have_command fc-cache; then
    fc-cache -f "$FONT_DIR" >/dev/null 2>&1 || log_warn "fc-cache failed; log out and back in to refresh fonts."
  else
    log_warn "fc-cache is not available; install fontconfig to refresh the font cache."
  fi

  log_success "Installed Nerd Fonts v${NERD_FONTS_VERSION} JetBrainsMono."
}
