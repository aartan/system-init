#!/usr/bin/env bash
# Terminal module post-install hook.
# shellcheck shell=bash

module_post_install() {
  zsh_install_frameworks || return 1
  zsh_set_login_shell || return 1
}
