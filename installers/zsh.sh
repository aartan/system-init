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

# Git is always invoked through git_safe (lib/common.sh), which disables
# repository-local fsmonitor, untracked-cache and hook execution.

zsh_git_clone_at() {
  local url="$1"
  local destination="$2"
  local commit="$3"
  local current status

  if [[ -L "$destination" ]]; then
    record_failure "Refusing to use a symlinked framework checkout: $destination"
    return 1
  fi

  if [[ -e "$destination/.git" || -L "$destination/.git" ]]; then
    if [[ ! -d "$destination/.git" || -L "$destination/.git" ]]; then
      record_failure "Refusing a checkout whose .git metadata is not a real directory: $destination"
      return 1
    fi
    if ! git_checkout_owned_by_user "$destination"; then
      record_failure "Refusing a checkout not owned by the current user: $destination"
      return 1
    fi
    current="$(git_safe -C "$destination" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$current" != "$commit" ]]; then
      record_failure "Existing checkout at $destination is at ${current:-unknown}, not the pinned ${commit}."
      return 1
    fi
    if ! status="$(git_safe -C "$destination" status --porcelain --untracked-files=normal 2>/dev/null)"; then
      record_failure "Could not inspect the working tree at $destination."
      return 1
    fi
    if [[ -n "$status" ]]; then
      record_failure "Existing checkout at $destination has local modifications; refusing to continue."
      return 1
    fi
    log_debug "Pinned checkout already present: $destination"
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

  if path_has_symlink_component "$(dirname -- "$destination")" "$TARGET_HOME"; then
    record_failure "Refusing to clone through a symlinked parent: $destination"
    return 1
  fi

  install -d -m 0755 "$(dirname -- "$destination")" || return 1
  if ! git_safe clone --quiet -- "$url" "$destination"; then
    rm -rf -- "$destination"
    record_failure "Failed to clone $url"
    return 1
  fi
  if ! git_safe -C "$destination" checkout --quiet "$commit"; then
    rm -rf -- "$destination"
    record_failure "Failed to check out pinned commit $commit in $destination"
    return 1
  fi

  current="$(git_safe -C "$destination" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$current" != "$commit" ]]; then
    rm -rf -- "$destination"
    record_failure "Checkout verification failed at $destination (expected ${commit}, got ${current:-unknown})."
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

  if ! target_user_is_valid "$TARGET_USER"; then
    record_failure "Invalid target user name: ${TARGET_USER:-<empty>}"
    return 1
  fi

  current_shell="$(getent -- passwd "$TARGET_USER" | awk -F: '{ print $7 }')"

  if [[ "$current_shell" == "$ZSH_TARGET_BIN" ]]; then
    log_debug "Login shell is already $ZSH_TARGET_BIN"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo chsh -s $ZSH_TARGET_BIN $TARGET_USER"
    return 0
  fi

  if have_command chsh; then
    if ! run_sudo chsh -s "$ZSH_TARGET_BIN" "$TARGET_USER"; then
      record_failure "Failed to change the login shell for $TARGET_USER to $ZSH_TARGET_BIN"
      return 1
    fi
  elif have_command usermod; then
    if ! run_sudo usermod -s "$ZSH_TARGET_BIN" "$TARGET_USER"; then
      record_failure "Failed to change the login shell for $TARGET_USER to $ZSH_TARGET_BIN"
      return 1
    fi
  else
    record_failure "Neither chsh nor usermod is available to change the login shell."
    return 1
  fi

  current_shell="$(getent -- passwd "$TARGET_USER" | awk -F: '{ print $7 }')"
  if [[ "$current_shell" != "$ZSH_TARGET_BIN" ]]; then
    record_failure "Login shell for $TARGET_USER is ${current_shell:-unknown}, expected $ZSH_TARGET_BIN."
    return 1
  fi

  log_success "Changed login shell to $ZSH_TARGET_BIN"
  log_info "Log out and back in for the new login shell to apply to existing sessions."
}
