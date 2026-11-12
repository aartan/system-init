#!/usr/bin/env bash
# system-init installer
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export REPO_ROOT

# shellcheck source=lib/logging.sh
source "$REPO_ROOT/lib/logging.sh"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/platform.sh
source "$REPO_ROOT/lib/platform.sh"
# shellcheck source=lib/backups.sh
source "$REPO_ROOT/lib/backups.sh"
# shellcheck source=lib/dotfiles.sh
source "$REPO_ROOT/lib/dotfiles.sh"
# shellcheck source=lib/packages.sh
source "$REPO_ROOT/lib/packages.sh"
# shellcheck source=lib/modules.sh
source "$REPO_ROOT/lib/modules.sh"
# shellcheck source=lib/validation.sh
source "$REPO_ROOT/lib/validation.sh"

# shellcheck source=installers/dnf.sh
source "$REPO_ROOT/installers/dnf.sh"
# shellcheck source=installers/flatpak.sh
source "$REPO_ROOT/installers/flatpak.sh"
# shellcheck source=installers/brew.sh
source "$REPO_ROOT/installers/brew.sh"
# shellcheck source=installers/mise.sh
source "$REPO_ROOT/installers/mise.sh"
# shellcheck source=installers/fonts.sh
source "$REPO_ROOT/installers/fonts.sh"
# shellcheck source=installers/zsh.sh
source "$REPO_ROOT/installers/zsh.sh"
# shellcheck source=installers/code.sh
source "$REPO_ROOT/installers/code.sh"

INSTALL_DOTFILES=1
REQUESTED_MODULES=()
SHOW_LIST=0
PROFILE=""
INSTALL_OK=0
IN_PROGRESS_FILE="$STATE_DIR/install.in-progress"

usage() {
  cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Install a development workstation. Without --profile or --module, an
interactive run prompts for the core or extended profile. A non-interactive
run defaults to core.

Options:
  --profile NAME     core (development defaults) or extended (all modules).
  --dry-run          Show every action without changing the system.
  --no-dotfiles      Install packages and system configuration only.
  --module NAME      Install NAME and its dependencies. Repeatable.
  --list             List modules, package counts, and descriptions.
  -h, --help         Show this help.

Examples:
  ./install.sh --profile core --dry-run
  ./install.sh --profile extended
  ./install.sh --module terminal --module databases
  ./install.sh --no-dotfiles
EOF
}

parse_args() {
  local argument module
  local -a modules=()

  while (( $# > 0 )); do
    argument="$1"
    case "$argument" in
      --dry-run)
        DRY_RUN=1
        ;;
      --no-dotfiles)
        INSTALL_DOTFILES=0
        ;;
      --module)
        if (( $# < 2 )); then
          log_error "--module requires a module name."
          exit 2
        fi
        modules=()
        shift
        IFS=',' read -r -a modules <<<"$1"
        if (( ${#modules[@]} == 0 )); then
          log_error "--module requires a non-empty module name."
          exit 2
        fi
        for module in "${modules[@]}"; do
          module="${module//[[:space:]]/}"
          [[ -z "$module" ]] && continue
          REQUESTED_MODULES+=("$module")
        done
        ;;
      --module=*)
        modules=()
        IFS=',' read -r -a modules <<<"${argument#--module=}"
        if (( ${#modules[@]} == 0 )); then
          log_error "--module requires a non-empty module name."
          exit 2
        fi
        for module in "${modules[@]}"; do
          module="${module//[[:space:]]/}"
          [[ -z "$module" ]] && continue
          REQUESTED_MODULES+=("$module")
        done
        ;;
      --profile)
        if (( $# < 2 )); then
          log_error "--profile requires a name."
          exit 2
        fi
        shift
        PROFILE="$1"
        ;;
      --profile=*)
        PROFILE="${argument#--profile=}"
        ;;
      --list)
        SHOW_LIST=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $argument"
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

validate_profile_args() {
  if [[ -n "$PROFILE" && ${#REQUESTED_MODULES[@]} -gt 0 ]]; then
    log_error "Use either --profile or --module, not both."
    exit 2
  fi

  if [[ -n "$PROFILE" ]]; then
    case "$PROFILE" in
      core|extended) ;;
      *)
        log_error "Unknown profile: $PROFILE (expected core or extended)."
        exit 2
        ;;
    esac
  fi
}

select_profile() {
  local choice

  if [[ -n "$PROFILE" ]]; then
    return 0
  fi
  if (( ${#REQUESTED_MODULES[@]} > 0 )); then
    return 0
  fi
  if [[ "$SHOW_LIST" == "1" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    PROFILE=core
    log_info "No interactive terminal; using the core profile."
    return 0
  fi

  printf '\nInstallation profile:\n'
  printf '  1) Core development\n'
  printf '  2) Extended workstation (adds browsers, productivity apps, virtualization)\n'

  while true; do
    printf 'Select [1/2] (default 1): '
    if ! read -r choice; then
      printf '\n'
      PROFILE=core
      break
    fi
    case "$choice" in
      1|"")
        PROFILE=core
        break
        ;;
      2)
        PROFILE=extended
        break
        ;;
      *)
        printf 'Enter 1 or 2.\n'
        ;;
    esac
  done
}

apply_profile() {
  local module

  (( ${#REQUESTED_MODULES[@]} > 0 )) && return 0
  [[ -z "$PROFILE" ]] && return 0

  while IFS= read -r module; do
    [[ -z "$module" ]] && continue
    REQUESTED_MODULES+=("$module")
  done < <(modules_profile_modules "$PROFILE")
}

prompt_restart() {
  local answer

  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ -t 0 ]] || return 0

  printf '\n'
  log_info "A restart is recommended to apply shell, session, and service changes."
  printf 'Restart now? [y/N] '
  if ! read -r answer; then
    printf '\n'
    return 0
  fi

  case "$answer" in
    [yY]|[yY][eE][sS])
      log_info "Restarting..."
      run_sudo systemctl reboot || log_warn "Could not restart automatically; restart manually."
      ;;
    *)
      printf 'Log out and back in, then run ./scripts/doctor.sh to verify the setup.\n'
      ;;
  esac
}

show_summary() {
  local item

  printf '\n'
  log_section "Installation summary"

  if (( ${#FAILED_ITEMS[@]} > 0 )); then
    log_error "Completed with ${#FAILED_ITEMS[@]} failure(s):"
    for item in "${FAILED_ITEMS[@]}"; do
      printf '  - %s\n' "$item"
    done
  elif [[ "$DRY_RUN" == "1" ]]; then
    log_success "Dry-run validated all requested modules without recorded failures."
  else
    log_success "All requested modules completed without recorded failures."
  fi

  if (( ${#WARNED_ITEMS[@]} > 0 )); then
    printf '\n'
    log_warn "${#WARNED_ITEMS[@]} warning(s):"
    for item in "${WARNED_ITEMS[@]}"; do
      printf '  - %s\n' "$item"
    done
  fi

  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    printf '\nLog: %s\n' "$LOG_FILE"
  fi
  if [[ -n "${BACKUP_RUN_DIR:-}" && -d "$BACKUP_RUN_DIR" ]]; then
    printf 'Backups: %s\n' "$BACKUP_RUN_DIR"
  fi
}

on_error() {
  local status=$?
  local line="$1"
  trap - ERR
  log_error "Unexpected failure at install.sh line ${line} (status ${status})."
  show_summary
  exit "$status"
}

on_exit() {
  local status=$?
  trap - EXIT
  cleanup_tmp
  if [[ "$INSTALL_OK" != "1" && -f "$IN_PROGRESS_FILE" ]]; then
    log_warn "Installation did not finish cleanly. The in-progress marker remains at:"
    log_warn "  $IN_PROGRESS_FILE"
    log_warn "Rerunning ./install.sh is safe; existing files are backed up, not overwritten."
  fi
  exit "$status"
}

main() {
  parse_args "$@"

  platform_detect
  case "$PLATFORM" in
    fedora|macos) ;;
    linux-unsupported)
      log_error "This Linux distribution is not supported. Fedora is required."
      exit 1
      ;;
    *)
      log_error "Unsupported operating system: $(uname -s)."
      exit 1
      ;;
  esac

  platform_load || exit 1
  validate_profile_args

  if [[ "$SHOW_LIST" != "1" ]]; then
    select_profile
    if [[ -n "$PROFILE" ]]; then
      modules_profile_validate "$PROFILE" || exit 2
      apply_profile
    fi
  fi

  modules_resolve "${REQUESTED_MODULES[@]}" || exit 2

  if [[ "$SHOW_LIST" == "1" ]]; then
    printf 'Platform: %s (%s)\n' "$PLATFORM_NAME" "$PLATFORM_ARCH"
    printf 'Modules:\n\n'
    modules_list
    exit 0
  fi

  trap 'on_error $LINENO' ERR
  trap 'on_exit' EXIT

  if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "Dry-run mode: no files, packages, services, or state will be changed."
  fi

  init_state_dirs
  logging_init

  log_section "system-init installer"
  log_info "Platform: $PLATFORM_NAME ($PLATFORM_ARCH)"
  log_info "Target home: $TARGET_HOME"
  if [[ -n "$PROFILE" ]]; then
    log_info "Profile: $PROFILE"
  fi
  log_info "Modules: ${SELECTED_MODULES[*]}"

  validation_preflight || {
    show_summary
    exit 1
  }

  platform_sudo_prepare || {
    record_failure "sudo access is required for packages and system configuration."
    show_summary
    exit 1
  }

  if [[ "$DRY_RUN" != "1" ]]; then
    printf 'started=%s\npid=%s\nmodules=%s\n' \
      "$(now_timestamp)" "$$" "${SELECTED_MODULES[*]}" >"$IN_PROGRESS_FILE"
    chmod 600 "$IN_PROGRESS_FILE"
  fi

  CURRENT_MODULE="backup"
  log_section "Pre-install backup"
  if [[ "$INSTALL_DOTFILES" == "1" ]]; then
    if ! backup_dotfile_targets; then
      record_failure "Pre-install backup failed; refusing to change dotfiles."
      show_summary
      exit 1
    fi
  else
    log_info "Skipping pre-install dotfile backup (--no-dotfiles)."
  fi

  CURRENT_MODULE="platform"
  log_section "Platform setup"
  if ! platform_init; then
    record_failure "Platform repository setup failed."
  fi

  modules_run

  if [[ "$INSTALL_DOTFILES" == "1" ]]; then
    local count
    count="$(dotfiles_count 2>/dev/null || printf '0')"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      CURRENT_MODULE="dotfiles"
      log_section "Dotfiles"
      dotfiles_install || record_failure "Dotfile installation failed."
    else
      log_info "No dotfiles apply to the selected modules."
    fi
  else
    log_info "Skipping dotfiles (--no-dotfiles)."
  fi

  CURRENT_MODULE="platform"
  log_section "Platform post-install"
  platform_post_install || record_failure "Platform post-install checks failed."

  prune_backups

  show_summary

  if (( ${#FAILED_ITEMS[@]} > 0 )); then
    exit 1
  fi

  INSTALL_OK=1
  if [[ "$DRY_RUN" != "1" ]]; then
    rm -f -- "$IN_PROGRESS_FILE"
  fi

  printf '\n'
  if [[ "$DRY_RUN" == "1" ]]; then
    log_success "Dry-run complete. No changes were made."
    printf 'Next steps:\n'
    printf '  1. Review the dry-run output above.\n'
    printf '  2. Run ./install.sh without --dry-run to apply.\n'
  else
    log_success "system-init installation complete."
    printf 'Next steps:\n'
    printf '  1. Restart or log out and back in to apply the new login shell.\n'
    printf '  2. Verify the workstation with: ./scripts/doctor.sh\n'
    printf '  3. Review backups at: %s\n' "$BACKUP_DIR"
    prompt_restart
  fi
}

main "$@"
