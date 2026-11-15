#!/usr/bin/env bash
# VS Code extension management.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_CODE_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_CODE_SOURCED=1

VSCODE_EXTENSIONS=(
  "dbaeumer.vscode-eslint@${VSCODE_ESLINT_VERSION}"
  "esbenp.prettier-vscode@${VSCODE_PRETTIER_VERSION}"
)

code_extensions_install() {
  local extension installed

  if ! have_command code; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log_dry "install VS Code extensions after the code package is available"
      return 0
    fi
    record_failure "VS Code command 'code' is not available."
    return 1
  fi

  installed="$(code --list-extensions --show-versions 2>/dev/null || true)"

  for extension in "${VSCODE_EXTENSIONS[@]}"; do
    if grep -Fxiq -- "$extension" <<<"$installed"; then
      log_debug "VS Code extension already installed: $extension"
      continue
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      log_dry "code --install-extension $extension"
      continue
    fi

    if code --install-extension "$extension" --force >/dev/null 2>&1; then
      log_success "Installed VS Code extension: $extension"
    else
      record_failure "Failed to install VS Code extension: $extension"
    fi
  done
}
