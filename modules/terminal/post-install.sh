#!/usr/bin/env bash
# Terminal module post-install hook.
# shellcheck shell=bash

module_post_install() {
  if [[ "$PLATFORM" == "macos" ]]; then
    alacritty_install || return 1
  fi
  zsh_install_frameworks || return 1
  zsh_set_login_shell || return 1
}
