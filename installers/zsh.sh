#!/usr/bin/env bash
# Zsh framework installation.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_ZSH_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_ZSH_SOURCED=1

OMZ_DIR="${TARGET_HOME}/.oh-my-zsh"
P10K_DIR="$OMZ_DIR/custom/themes/powerlevel10k"
HISTORY_SUBSTRING_DIR="$OMZ_DIR/custom/plugins/history-substring-search"

ZSH_TARGET_BIN=/usr/bin/zsh

zsh_git_clone_at() {
  local url="$1"
  local destination="$2"
  local commit="$3"

  if [[ -d "$destination/.git" ]]; then
    local current
    current="$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$current" == "$commit" ]]; then
      log_debug "Pinned checkout already present: $destination"
    else
      record_warning "Existing checkout at $destination is at ${current:-unknown}, not the pinned ${commit}; leaving it unchanged."
    fi
    return 0
  fi

  if [[ -e "$destination" ]]; then
    record_failure "Cannot install into $destination: path exists and is not a Git checkout."
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "git clone $url $(log_cmd "$destination") && git checkout $commit"
    return 0
  fi

  require_command git || return 1
  install -d -m 0755 "$(dirname -- "$destination")"
  if ! git clone --quiet -- "$url" "$destination"; then
    record_failure "Failed to clone $url"
    return 1
  fi
  if ! git -C "$destination" checkout --quiet "$commit"; then
    record_failure "Failed to check out pinned commit $commit in $destination"
    return 1
  fi
  log_success "Installed $(basename -- "$destination") at ${commit:0:7}"
}

zsh_install_frameworks() {
  zsh_git_clone_at "https://github.com/ohmyzsh/ohmyzsh.git" "$OMZ_DIR" "$OH_MY_ZSH_COMMIT" || return 1
  zsh_git_clone_at "https://github.com/romkatv/powerlevel10k.git" "$P10K_DIR" "$P10K_COMMIT" || return 1
  zsh_git_clone_at \
    "https://github.com/zsh-users/zsh-history-substring-search.git" \
    "$HISTORY_SUBSTRING_DIR" \
    "$HISTORY_SUBSTRING_COMMIT" || return 1
}

zsh_set_login_shell() {
  local current_shell
  current_shell="$(getent passwd "$TARGET_USER" | awk -F: '{ print $7 }')"

  if [[ "$current_shell" == "$ZSH_TARGET_BIN" ]]; then
    log_debug "Login shell is already $ZSH_TARGET_BIN"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo chsh -s $ZSH_TARGET_BIN $TARGET_USER"
    return 0
  fi

  require_command chsh || return 1
  if ! run_sudo chsh -s "$ZSH_TARGET_BIN" "$TARGET_USER"; then
    record_failure "Failed to change the login shell for $TARGET_USER to $ZSH_TARGET_BIN"
    return 1
  fi
  log_success "Changed login shell to $ZSH_TARGET_BIN"
}
