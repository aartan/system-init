#!/usr/bin/env bash
# Repository and environment validation.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_VALIDATION_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_VALIDATION_SOURCED=1

validation_environment() {
  local failed=0

  if (( EUID == 0 )); then
    record_failure "Do not run this installer as root. Run it as your normal user; sudo is requested only when needed."
    failed=1
  fi

  local bash_major="${BASH_VERSINFO[0]:-0}"
  if (( bash_major < 5 )); then
    record_failure "Bash 5 or newer is required (found ${BASH_VERSION:-unknown})."
    failed=1
  fi

  if [[ ! -d "$TARGET_HOME" ]]; then
    record_failure "Target home directory does not exist: $TARGET_HOME"
    failed=1
  fi

  if [[ ! -w "$TARGET_HOME" && "$DRY_RUN" != "1" ]]; then
    record_failure "Target home directory is not writable: $TARGET_HOME"
    failed=1
  fi

  local required=(
    config/settings.conf
    config/pins.conf
    config/runtimes.conf
    config/modules.conf
    dotfiles/manifest.tsv
    lib/common.sh
    lib/logging.sh
    lib/platform.sh
    lib/packages.sh
    lib/modules.sh
    lib/backups.sh
    lib/dotfiles.sh
  )
  local item
  for item in "${required[@]}"; do
    if [[ ! -f "$REPO_ROOT/$item" ]]; then
      record_failure "Missing repository file: $item"
      failed=1
    fi
  done

  return "$failed"
}

validation_required_commands() {
  # git is intentionally not required here: the core module installs it before
  # the shell-framework and LFS steps that need it.
  local -a commands=(curl tar sha256sum awk sed grep find realpath install)
  local command
  local failed=0

  if [[ "$PLATFORM" == "fedora" ]]; then
    commands+=(dnf rpm sudo systemctl)
  fi

  for command in "${commands[@]}"; do
    if ! have_command "$command"; then
      record_failure "Required command not found: $command"
      failed=1
    fi
  done
  return "$failed"
}

validation_package_manifests() {
  local module file line manager package optional
  local failed=0
  local -A seen=()

  for module in "${SELECTED_MODULES[@]}"; do
    file="$(packages_module_file "$module")"
    [[ -f "$file" ]] || continue

    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      read -r manager package optional <<<"$line"

      if [[ -z "${manager:-}" || -z "${package:-}" ]]; then
        record_failure "Malformed package declaration in $file: $line"
        failed=1
        continue
      fi

      if [[ -n "${optional:-}" && "$optional" != "optional" ]]; then
        record_failure "Unknown package flag '$optional' in $file: $line"
        failed=1
        continue
      fi

      case "$manager" in
        dnf|flatpak)
          if [[ "$PLATFORM" != "fedora" ]]; then
            record_failure "Package manager '$manager' is not valid on $PLATFORM ($file)."
            failed=1
          fi
          ;;
        brew|cask)
          if [[ "$PLATFORM" != "macos" ]]; then
            record_failure "Package manager '$manager' is not valid on $PLATFORM ($file)."
            failed=1
          fi
          ;;
        *)
          record_failure "Unsupported package manager '$manager' in $file."
          failed=1
          ;;
      esac

      local key="$manager:$package"
      if [[ -n "${seen[$key]:-}" ]]; then
        record_failure "Duplicate package declaration '$package' in $file."
        failed=1
      fi
      seen["$key"]=1
    done <"$file"
  done

  return "$failed"
}

validation_dotfiles() {
  if ! dotfiles_entries >/dev/null; then
    record_failure "Dotfiles manifest validation failed."
    return 1
  fi
  return 0
}

validation_secret_paths() {
  local failed=0
  local forbidden=(
    ".ssh"
    ".gnupg"
    ".zsh_history"
    ".bash_history"
    ".config/stripe"
    ".config/opencode/service.json"
    ".config/masar"
    ".claude"
    "Trust Tokens"
  )
  local item
  for item in "${forbidden[@]}"; do
    if [[ -e "$REPO_ROOT/$item" ]]; then
      record_failure "Repository contains a forbidden sensitive path: $item"
      failed=1
    fi
  done

  if find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o \
    -type f \( -name "*.pem" -o -name "*.key" -o -name "id_rsa" -o -name "id_ed25519" \) -print \
    | grep -q .; then
    record_failure "Repository contains private key material."
    failed=1
  fi

  return "$failed"
}

validation_preflight() {
  local failed=0

  validation_environment || failed=1
  validation_required_commands || failed=1
  modules_validate_all || failed=1
  validation_package_manifests || failed=1
  validation_dotfiles || failed=1
  validation_secret_paths || failed=1
  platform_validate || failed=1
  platform_preflight || failed=1

  if (( failed == 0 )); then
    log_success "Preflight validation passed."
  else
    log_error "Preflight validation failed."
  fi
  return "$failed"
}
