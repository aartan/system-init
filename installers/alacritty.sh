#!/usr/bin/env bash
# Alacritty installation for macOS.
#
# Homebrew disabled the alacritty cask because the upstream app is ad-hoc
# signed and fails its Gatekeeper audit. Install the exact official release
# after verifying its pinned SHA-256 instead of bypassing Homebrew's check.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_ALACRITTY_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_ALACRITTY_SOURCED=1

ALACRITTY_APP_NAME="Alacritty.app"

alacritty_installed_app() {
  local candidate
  for candidate in "/Applications/$ALACRITTY_APP_NAME" "$TARGET_HOME/Applications/$ALACRITTY_APP_NAME"; do
    if [[ -d "$candidate" && ! -L "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

alacritty_install_target() {
  local installed
  if installed="$(alacritty_installed_app 2>/dev/null)"; then
    printf '%s\n' "$installed"
    return 0
  fi
  if [[ -w /Applications ]]; then
    printf '/Applications/%s\n' "$ALACRITTY_APP_NAME"
  else
    printf '%s/Applications/%s\n' "$TARGET_HOME" "$ALACRITTY_APP_NAME"
  fi
}

alacritty_app_version() {
  local app="$1"
  [[ -f "$app/Contents/Info.plist" ]] || return 1
  /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$app/Contents/Info.plist" 2>/dev/null
}

alacritty_installed_version() {
  local app
  app="$(alacritty_installed_app 2>/dev/null)" || return 1
  alacritty_app_version "$app"
}

alacritty_verify_installed() {
  [[ "$(alacritty_installed_version 2>/dev/null)" == "$ALACRITTY_VERSION" ]]
}

alacritty_install() {
  local dmg mount source_app stage target old version

  [[ "${PLATFORM:-fedora}" == "macos" ]] || return 0

  if alacritty_verify_installed; then
    log_debug "Alacritty $ALACRITTY_VERSION is already installed."
    report_present "Alacritty $ALACRITTY_VERSION"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "download Alacritty v${ALACRITTY_VERSION}, verify SHA-256, install ${ALACRITTY_APP_NAME}"
    return 0
  fi

  require_command curl || return 1
  require_command hdiutil || return 1
  require_command ditto || return 1
  make_tmp_dir || return 1

  dmg="$TMP_DIR/Alacritty.dmg"
  mount="$TMP_DIR/alacritty-mount"
  stage="$TMP_DIR/$ALACRITTY_APP_NAME"
  target="$(alacritty_install_target)"

  download_verify "$ALACRITTY_DMG_URL" "$dmg" "$ALACRITTY_DMG_SHA256" || return 1
  mkdir -p "$mount" || return 1

  if ! hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null 2>&1; then
    log_error "Could not mount the Alacritty disk image."
    return 1
  fi

  source_app="$mount/$ALACRITTY_APP_NAME"
  if [[ ! -d "$source_app" || -L "$source_app" ]]; then
    log_error "Alacritty disk image does not contain $ALACRITTY_APP_NAME."
    hdiutil detach "$mount" >/dev/null 2>&1 || true
    return 1
  fi

  version="$(alacritty_app_version "$source_app")"
  if [[ "$version" != "$ALACRITTY_VERSION" ]]; then
    log_error "Alacritty version mismatch: expected $ALACRITTY_VERSION, got ${version:-unknown}."
    hdiutil detach "$mount" >/dev/null 2>&1 || true
    return 1
  fi

  if ! ditto "$source_app" "$stage"; then
    log_error "Could not copy Alacritty from the disk image."
    hdiutil detach "$mount" >/dev/null 2>&1 || true
    return 1
  fi
  hdiutil detach "$mount" >/dev/null 2>&1 || true

  if have_command codesign && ! codesign --verify --deep --strict "$stage" >/dev/null 2>&1; then
    log_error "Alacritty code signature verification failed."
    return 1
  fi
  if [[ "$(alacritty_app_version "$stage")" != "$ALACRITTY_VERSION" ]]; then
    log_error "Staged Alacritty copy failed version verification."
    return 1
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    if [[ -L "$target" || ! -d "$target" ]]; then
      record_failure "Refusing to replace an unsafe Alacritty path: $target"
      return 1
    fi
    old="$target.previous-system-init"
    safe_rm_rf "$old" 2>/dev/null || true
    if ! mv "$target" "$old"; then
      record_failure "Could not move the existing Alacritty installation aside."
      return 1
    fi
  fi

  mkdir -p "$(dirname "$target")" || {
    [[ -n "${old:-}" ]] && mv "$old" "$target" 2>/dev/null || true
    return 1
  }
  if ! ditto "$stage" "$target"; then
    safe_rm_rf "$target" 2>/dev/null || true
    [[ -n "${old:-}" ]] && mv "$old" "$target" 2>/dev/null || true
    record_failure "Could not install Alacritty into $target."
    return 1
  fi

  if ! alacritty_verify_installed; then
    safe_rm_rf "$target" 2>/dev/null || true
    [[ -n "${old:-}" ]] && mv "$old" "$target" 2>/dev/null || true
    record_failure "Alacritty verification failed after installation."
    return 1
  fi

  if [[ -n "${old:-}" && -d "$old" ]]; then
    safe_rm_rf "$old" || log_warn "Could not remove the previous Alacritty copy: $old"
  fi

  log_success "Installed Alacritty $ALACRITTY_VERSION in $(dirname "$target")."
  report_installed "Alacritty $ALACRITTY_VERSION"
}

alacritty_remove() {
  local app

  app="$(alacritty_installed_app 2>/dev/null)" || return 0

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "remove $(log_cmd "$app")"
    return 0
  fi

  safe_rm_rf "$app" || {
    record_failure "Could not remove Alacritty from $app."
    return 1
  }
  log_success "Removed $app"
}
