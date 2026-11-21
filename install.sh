#!/usr/bin/env bash
# system-init installer
set -Eeuo pipefail

# Refuse root before sourcing anything from the repository. Sudo is requested
# only for individual privileged commands after validation.
if (( EUID == 0 )); then
  printf 'system-init: refusing to run as root. Run this as your normal user; sudo is requested only when needed.\n' >&2
  exit 1
fi

# Resolve privileged commands only from trusted system directories. macOS
# applies its validated Homebrew PATH in lib/bootstrap.sh instead.
if [[ "$(uname -s)" != "Darwin" ]]; then
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export REPO_ROOT

# shellcheck source=lib/bootstrap.sh
source "$REPO_ROOT/lib/bootstrap.sh"
# Listing modules is read-only and must never bootstrap packages.
for _install_arg in "$@"; do
  [[ "$_install_arg" == "--list" ]] && export DEV_SETUP_BOOTSTRAP_READONLY=1
done
unset _install_arg
# Bootstrap is intentionally Bash 3.2-safe and re-execs Homebrew Bash 5.
bootstrap_run "$@"

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
# shellcheck source=lib/git_identity.sh
source "$REPO_ROOT/lib/git_identity.sh"

# shellcheck source=installers/dnf.sh
source "$REPO_ROOT/installers/dnf.sh"
# shellcheck source=installers/flatpak.sh
source "$REPO_ROOT/installers/flatpak.sh"
# shellcheck source=installers/brew.sh
source "$REPO_ROOT/installers/brew.sh"
# shellcheck source=installers/alacritty.sh
source "$REPO_ROOT/installers/alacritty.sh"
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
MODULE_OPTION_GIVEN=0
SHOW_LIST=0
PROFILE=""
NON_INTERACTIVE=0
INSTALL_OK=0
GIT_IDENTITY_NAME=""
GIT_IDENTITY_EMAIL=""
GIT_LOCAL_CONFIG="$TARGET_HOME/.gitconfig.local"
IN_PROGRESS_FILE="$STATE_DIR/install.in-progress"

usage() {
  cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Install a development workstation. An interactive run prompts for the core
or extended profile; non-interactive runs default to core.

Options:
  --profile NAME     core (development defaults) or extended (all modules and
                     optional desktop applications).
  --dry-run          Show every action without changing the system.
  --no-dotfiles      Install packages and system configuration only.
  --module NAME      Install NAME and its dependencies. Repeatable.
  --list             List modules, package counts, and descriptions.
  --yes, -y          Skip the one-time macOS Homebrew/Bash bootstrap
                     confirmation.
  --non-interactive  Never prompt; implies --yes. Uses the explicit profile or
                     core, and environment/global Git identity.
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
        MODULE_OPTION_GIVEN=1
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
        MODULE_OPTION_GIVEN=1
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
      --yes|-y)
        # Consumed by the macOS bootstrap; accepted here for a consistent CLI.
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
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
  if (( MODULE_OPTION_GIVEN == 1 )) && (( ${#REQUESTED_MODULES[@]} == 0 )); then
    log_error "--module was provided but contains no valid module names."
    exit 2
  fi

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

  # A fresh macOS bootstrap asks the same profile question before installing
  # Homebrew/Bash 5, then re-execs. Reuse that answer instead of asking twice.
  if [[ -n "${DEV_SETUP_BOOTSTRAP_PROFILE:-}" ]]; then
    case "$DEV_SETUP_BOOTSTRAP_PROFILE" in
      core|extended)
        PROFILE="$DEV_SETUP_BOOTSTRAP_PROFILE"
        log_info "Using the $PROFILE profile selected during bootstrap."
        return 0
        ;;
    esac
  fi

  if (( NON_INTERACTIVE == 1 )); then
    PROFILE=core
    log_info "Non-interactive run; using the core profile."
    return 0
  fi

  if [[ ! -t 0 ]]; then
    PROFILE=core
    log_info "No interactive terminal; using the core profile."
    return 0
  fi

  printf '\nInstallation profile:\n'
  printf '  1) Core development (required packages only)\n'
  printf '  2) Extended workstation (all modules, including optional desktop apps)\n'

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

git_identity_current() {
  local key="$1"
  local value=""

  if [[ -f "$GIT_LOCAL_CONFIG" ]]; then
    value="$(git_identity_config --file "$GIT_LOCAL_CONFIG" --get "$key" 2>/dev/null || true)"
  fi
  if [[ -z "$value" ]]; then
    value="$(HOME="$TARGET_HOME" git_identity_config --global --includes --get "$key" 2>/dev/null || true)"
  fi
  printf '%s\n' "$value"
}

prompt_git_identity() {
  local name email input

  [[ "$INSTALL_DOTFILES" == "1" ]] || return 0
  [[ "$DRY_RUN" == "1" ]] && return 0
  dotfiles_target_selected ".gitconfig" || return 0

  name="${DEV_SETUP_GIT_NAME:-$(git_identity_current user.name)}"
  email="${DEV_SETUP_GIT_EMAIL:-$(git_identity_current user.email)}"

  if (( NON_INTERACTIVE == 1 )) || [[ ! -t 0 ]]; then
    if [[ -n "$name" && -n "$email" ]]; then
      GIT_IDENTITY_NAME="$name"
      GIT_IDENTITY_EMAIL="$email"
      log_info "Using the configured Git identity for $name <$email>."
    else
      log_info "Non-interactive run; skipping the Git identity prompt."
    fi
    return 0
  fi

  printf '\nGit identity (used for commits):\n'

  printf '  Name'
  [[ -n "$name" ]] && printf ' [%s]' "$name"
  printf ': '
  if ! read -r input; then
    printf '\n'
    return 0
  fi
  [[ -n "$input" ]] && name="$input"

  printf '  Email'
  [[ -n "$email" ]] && printf ' [%s]' "$email"
  printf ': '
  if ! read -r input; then
    printf '\n'
    return 0
  fi
  [[ -n "$input" ]] && email="$input"

  if [[ -z "$name" || -z "$email" ]]; then
    log_warn "Git identity not set; configure it later in ~/.gitconfig.local."
    return 0
  fi

  GIT_IDENTITY_NAME="$name"
  GIT_IDENTITY_EMAIL="$email"
}

git_identity_apply() {
  local name="$GIT_IDENTITY_NAME"
  local email="$GIT_IDENTITY_EMAIL"
  local current_name current_email

  [[ "$INSTALL_DOTFILES" == "1" ]] || return 0
  [[ -n "$name" && -n "$email" ]] || return 0
  dotfiles_target_selected ".gitconfig" || return 0
  if [[ -L "$GIT_LOCAL_CONFIG" ]]; then
    record_failure "Refusing to write Git identity through a symlink: $GIT_LOCAL_CONFIG"
    return 1
  fi

  current_name="$(git_identity_config --file "$GIT_LOCAL_CONFIG" --get user.name 2>/dev/null || true)"
  current_email="$(git_identity_config --file "$GIT_LOCAL_CONFIG" --get user.email 2>/dev/null || true)"
  if [[ "$current_name" == "$name" && "$current_email" == "$email" ]]; then
    log_debug "Git identity already configured."
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "write Git identity to $(log_cmd "$GIT_LOCAL_CONFIG")"
    return 0
  fi

  if [[ -e "$GIT_LOCAL_CONFIG" ]]; then
    backup_path "$GIT_LOCAL_CONFIG" "git-identity" || return 1
    if [[ -n "${BACKUP_RUN_DIR:-}" && "${BACKUP_SNAPSHOT_COMPLETE:-0}" != "1" ]]; then
      backup_finalize || {
        record_failure "Could not finalize backup for the Git identity file."
        return 1
      }
    fi
  fi

  mkdir -p -- "$(dirname -- "$GIT_LOCAL_CONFIG")" || return 1
  if ! git_identity_write_atomic "$GIT_LOCAL_CONFIG" "$name" "$email"; then
    record_failure "Failed to write the Git identity atomically."
    return 1
  fi

  log_success "Configured Git identity for $name <$email>."
}

prompt_restart() {
  local answer

  [[ "$DRY_RUN" == "1" ]] && return 0
  # macOS has used /bin/zsh as the default login shell since Catalina, and the
  # installer only configures zsh. A new terminal is sufficient on macOS.
  [[ "$PLATFORM" == "macos" ]] && return 0
  (( NON_INTERACTIVE == 1 )) && return 0
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
  report_summary

  if (( ${#FAILED_ITEMS[@]} > 0 )); then
    log_error "Completed with ${#FAILED_ITEMS[@]} failure(s):"
    for item in "${FAILED_ITEMS[@]}"; do
      printf '  - %s\n' "$item"
    done
  elif [[ "$(report_count failed)" != "0" ]]; then
    log_error "Completed with $(report_count failed) failed component(s)."
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
  state_lock_release
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

  prompt_git_identity

  trap 'on_error $LINENO' ERR
  trap 'on_exit' EXIT

  if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "Dry-run mode: no files, packages, services, or state will be changed."
  fi

  init_state_dirs
  if [[ "$DRY_RUN" != "1" ]]; then
    state_lock_acquire "operation" || {
      record_failure "Another system-init operation is already running."
      show_summary
      exit 1
    }
  fi
  logging_init

  log_section "system-init installer"
  log_info "Platform: $PLATFORM_NAME ($PLATFORM_ARCH)"
  if [[ "$PLATFORM" == "macos" ]]; then
    if [[ "${DEV_SETUP_HOMEBREW_INSTALLED:-0}" == "1" ]]; then
      report_installed "Homebrew at $BREW_PREFIX"
    else
      report_present "Homebrew at $BREW_PREFIX"
    fi
    if [[ "${DEV_SETUP_BASH_INSTALLED:-0}" == "1" ]]; then
      report_installed "Bash 5 runtime at $BOOTSTRAP_BASH"
    else
      report_present "Bash 5 runtime at $BOOTSTRAP_BASH"
    fi
  fi
  log_info "Target home: $TARGET_HOME"
  if [[ -n "$PROFILE" ]]; then
    log_info "Profile: $PROFILE"
    if packages_optional_apps_enabled; then
      log_info "Optional desktop applications: enabled."
    else
      log_info "Optional desktop applications: disabled."
    fi
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
    if ! printf 'started=%s\npid=%s\nmodules=%s\n' \
      "$(now_timestamp)" "$$" "${SELECTED_MODULES[*]}" | write_private_file "$IN_PROGRESS_FILE"; then
      record_failure "Could not create the install-in-progress marker safely."
      show_summary
      exit 1
    fi
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
    report_skipped "dotfiles (--no-dotfiles)"
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

  CURRENT_MODULE="dotfiles"
  git_identity_apply || record_failure "Git identity setup failed."

  CURRENT_MODULE="platform"
  log_section "Platform post-install"
  platform_post_install || record_failure "Platform post-install checks failed."

  if (( ${#FAILED_ITEMS[@]} == 0 )) && [[ -n "${BACKUP_RUN_DIR:-}" ]] \
    && [[ "${BACKUP_SNAPSHOT_COMPLETE:-0}" == "1" ]]; then
    if ! prune_backups; then
      record_failure "Backup pruning failed."
    fi
  else
    log_info "Skipping backup pruning; no complete non-empty backup was created in this run."
  fi

  show_summary

  if (( ${#FAILED_ITEMS[@]} > 0 )) || [[ "$(report_count failed)" != "0" ]]; then
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
    if [[ "$PLATFORM" == "macos" ]]; then
      printf '  1. Open a new terminal to load the new shell configuration and fonts.\n'
    else
      printf '  1. Restart or log out and back in to apply the new login shell.\n'
    fi
    printf '  2. Verify the workstation with: ./scripts/doctor.sh\n'
    printf '  3. Review backups at: %s\n' "$BACKUP_DIR"
    prompt_restart
  fi
}

main "$@"
