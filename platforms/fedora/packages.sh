#!/usr/bin/env bash
# Fedora-specific package repository helpers.
# shellcheck shell=bash

FEDORA_REPO_DIR=/etc/yum.repos.d
FEDORA_GPG_KEY_DIR=/etc/pki/rpm-gpg

fedora_repos_needed() {
  local needed=0

  if module_selected editors || module_selected browsers; then
    needed=1
  fi

  if packages_selected_managers | grep -Fxq flatpak; then
    needed=1
  fi

  printf '%s\n' "$needed"
}

fedora_key_sha256() {
  case "$1" in
    microsoft) printf '%s\n' "$MICROSOFT_GPG_SHA256" ;;
    brave) printf '%s\n' "$BRAVE_GPG_SHA256" ;;
    *) return 1 ;;
  esac
}

fedora_key_fingerprint() {
  case "$1" in
    microsoft) printf '%s\n' "$MICROSOFT_GPG_FINGERPRINT" ;;
    brave) printf '%s\n' "$BRAVE_GPG_FINGERPRINT" ;;
    *) return 1 ;;
  esac
}

# All primary fingerprints permitted in a pinned repository-key bundle. RPM
# trusts every key in the installed bundle, so the set must be explicit.
fedora_key_fingerprints() {
  case "$1" in
    microsoft) printf '%s\n' "${MICROSOFT_GPG_FINGERPRINTS:-$MICROSOFT_GPG_FINGERPRINT}" ;;
    brave) printf '%s\n' "${BRAVE_GPG_FINGERPRINTS:-$BRAVE_GPG_FINGERPRINT}" ;;
    *) return 1 ;;
  esac
}

fedora_repo_sha256() {
  case "$1" in
    vscode) printf '%s\n' "$VSCODE_REPO_SHA256" ;;
    brave) printf '%s\n' "$BRAVE_REPO_SHA256" ;;
    *) return 1 ;;
  esac
}

# Install a pinned repository key. The local key file is verified by SHA-256
# and, when gpg is available, by fingerprint before it is copied into place.
fedora_install_key() {
  local name="$1"
  local source_file="$2"
  local target_file="$3"
  local expected_sha expected_fpr actual_sha actual_fpr installed_sha allowed_fprs
  local stage_dir staged fpr

  require_file "$source_file" || return 1
  if [[ -L "$source_file" ]]; then
    record_failure "Repository key source is a symlink: $source_file"
    return 1
  fi
  if [[ -L "$target_file" ]]; then
    record_failure "Refusing to install a repository key over a symlink: $target_file"
    return 1
  fi

  expected_sha="$(fedora_key_sha256 "$name")" || {
    record_failure "No pinned SHA-256 for repository key '$name'."
    return 1
  }
  actual_sha="$(file_sha256 "$source_file" 2>/dev/null || true)"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    record_failure "Repository key '$name' does not match the pinned SHA-256."
    return 1
  fi

  expected_fpr="$(fedora_key_fingerprint "$name")" || {
    record_failure "No pinned fingerprint for repository key '$name'."
    return 1
  }
  if have_command gpg; then
    allowed_fprs="$(fedora_key_fingerprints "$name")" || return 1
    actual_fpr="$(gpg --batch --no-tty --show-keys --with-fingerprint --with-colons -- "$source_file" 2>/dev/null \
      | awk -F: '$1 == "fpr" { print $10; exit }')"
    if [[ "$actual_fpr" != "$expected_fpr" ]]; then
      record_failure "Repository key '$name' primary fingerprint mismatch (expected $expected_fpr, got ${actual_fpr:-none})."
      return 1
    fi
    while IFS= read -r fpr; do
      [[ -n "$fpr" ]] || continue
      if [[ " $allowed_fprs " != *" $fpr "* ]]; then
        record_failure "Repository key bundle '$name' contains an unpinned fingerprint: $fpr"
        return 1
      fi
    done < <(gpg --batch --no-tty --show-keys --with-fingerprint --with-colons -- "$source_file" 2>/dev/null \
      | awk -F: '$1 == "fpr" { print $10 }')
  fi

  if [[ -f "$target_file" ]] && cmp -s -- "$source_file" "$target_file"; then
    log_debug "Repository key already installed: $target_file"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo install -D -m0644 $(log_cmd "$source_file") $(log_cmd "$target_file")"
    return 0
  fi

  # Copy the verified bytes into a private staging directory and verify that
  # copy. The privileged install then reads the staged file, so replacing the
  # repository checkout after the initial check does not change what is
  # installed.
  stage_dir="$(mktemp -d -- "${TMPDIR:-/tmp}/system-init-key.XXXXXXXX")" || {
    record_failure "Could not create a private staging directory for repository key '$name'."
    return 1
  }
  staged="$stage_dir/key"
  if ! cp -- "$source_file" "$staged" \
    || [[ "$(file_sha256 "$staged" 2>/dev/null || true)" != "$expected_sha" ]]; then
    rm -rf -- "$stage_dir"
    record_failure "Repository key '$name' changed during verification."
    return 1
  fi

  if ! run_sudo install -D -m0644 -- "$staged" "$target_file"; then
    rm -rf -- "$stage_dir"
    return 1
  fi
  rm -rf -- "$stage_dir"

  # Re-hash the installed copy. If it differs, remove it rather than leaving a
  # repository key or definition that was never pinned.
  installed_sha="$(run_sudo sha256sum -- "$target_file" 2>/dev/null | awk '{ print $1; exit }')"
  if [[ "$installed_sha" != "$expected_sha" ]]; then
    run_sudo rm -f -- "$target_file" \
      || log_error "Could not remove the unpinned repository key: $target_file"
    record_failure "Installed repository key '$name' does not match the pinned SHA-256."
    return 1
  fi
}

fedora_ensure_repos() {
  local changed=0

  if module_selected editors; then
    local vscode_repo="$FEDORA_REPO_DIR/vscode.repo"
    fedora_install_key microsoft \
      "$REPO_ROOT/platforms/fedora/keys/microsoft.asc" \
      "$FEDORA_GPG_KEY_DIR/RPM-GPG-KEY-microsoft" || return 1
    if [[ "$(file_sha256 "$REPO_ROOT/platforms/fedora/repos/vscode.repo" 2>/dev/null || true)" != \
      "$(fedora_repo_sha256 vscode)" ]]; then
      record_failure "VS Code repository definition does not match its pinned SHA-256."
      return 1
    fi
    if [[ -f "$vscode_repo" ]] && cmp -s \
      "$REPO_ROOT/platforms/fedora/repos/vscode.repo" "$vscode_repo"; then
      log_debug "VS Code repository already configured."
    else
      dnf_repo_ensure "$REPO_ROOT/platforms/fedora/repos/vscode.repo" "$vscode_repo" \
        "$(fedora_repo_sha256 vscode)" || return 1
      changed=1
    fi
  fi

  if module_selected browsers; then
    local brave_repo="$FEDORA_REPO_DIR/brave-browser.repo"
    fedora_install_key brave \
      "$REPO_ROOT/platforms/fedora/keys/brave-core.asc" \
      "$FEDORA_GPG_KEY_DIR/RPM-GPG-KEY-brave" || return 1
    if [[ "$(file_sha256 "$REPO_ROOT/platforms/fedora/repos/brave-browser.repo" 2>/dev/null || true)" != \
      "$(fedora_repo_sha256 brave)" ]]; then
      record_failure "Brave repository definition does not match its pinned SHA-256."
      return 1
    fi
    if [[ -f "$brave_repo" ]] && cmp -s \
      "$REPO_ROOT/platforms/fedora/repos/brave-browser.repo" "$brave_repo"; then
      log_debug "Brave repository already configured."
    else
      dnf_repo_ensure "$REPO_ROOT/platforms/fedora/repos/brave-browser.repo" "$brave_repo" \
        "$(fedora_repo_sha256 brave)" || return 1
      changed=1
    fi
  fi

  if [[ "$changed" == "1" ]]; then
    dnf_makecache || return 1
  else
    log_debug "No new DNF repositories are required."
  fi
}

fedora_flatpak_remote_ensure() {
  if packages_selected_managers | grep -Fxq flatpak; then
    flatpak_remote_ensure || return 1
  fi
}
