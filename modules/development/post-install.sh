#!/usr/bin/env bash
# Development module post-install hook.
# shellcheck shell=bash

module_post_install() {
  mise_install_runtimes
}
