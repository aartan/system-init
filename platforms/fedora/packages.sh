#!/usr/bin/env bash
# Fedora-specific package repository helpers.
# shellcheck shell=bash

FEDORA_REPO_DIR=/etc/yum.repos.d

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

fedora_ensure_repos() {
  local changed=0

  if module_selected editors; then
    local vscode_repo="$FEDORA_REPO_DIR/vscode.repo"
    if [[ -f "$vscode_repo" ]]; then
      log_debug "VS Code repository already configured."
    else
      dnf_repo_ensure "$REPO_ROOT/platforms/fedora/repos/vscode.repo" "$vscode_repo" || return 1
      changed=1
    fi
  fi

  if module_selected browsers; then
    local brave_repo="$FEDORA_REPO_DIR/brave-browser.repo"
    if [[ -f "$brave_repo" ]]; then
      log_debug "Brave repository already configured."
    else
      dnf_repo_ensure "$REPO_ROOT/platforms/fedora/repos/brave-browser.repo" "$brave_repo" || return 1
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
