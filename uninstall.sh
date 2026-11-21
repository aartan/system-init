#!/usr/bin/env bash
# Remove system-init managed links and, explicitly, optional components.
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
export DEV_SETUP_BOOTSTRAP_READONLY=1
bootstrap_run "$@"

# shellcheck source=lib/logging.sh
source "$REPO_ROOT/lib/logging.sh"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/platform.sh
source "$REPO_ROOT/lib/platform.sh"
# shellcheck source=lib/packages.sh
source "$REPO_ROOT/lib/packages.sh"
# shellcheck source=lib/modules.sh
source "$REPO_ROOT/lib/modules.sh"
# shellcheck source=lib/dotfiles.sh
source "$REPO_ROOT/lib/dotfiles.sh"
# shellcheck source=lib/backups.sh
source "$REPO_ROOT/lib/backups.sh"
trap 'state_lock_release' EXIT
# shellcheck source=installers/dnf.sh
source "$REPO_ROOT/installers/dnf.sh"
# shellcheck source=installers/flatpak.sh
source "$REPO_ROOT/installers/flatpak.sh"
# shellcheck source=installers/brew.sh
source "$REPO_ROOT/installers/brew.sh"
# shellcheck source=installers/alacritty.sh
source "$REPO_ROOT/installers/alacritty.sh"

REMOVE_PACKAGES=0
RESTORE_BACKUPS=0
PURGE_STATE=0
ASSUME_YES=0
# Explicit flags only; do not inherit a permissive environment default.
RESTORE_ALLOW_LEGACY=0
RESTORE_ALLOW_UNSIGNED=0

PROTECTED_BREW=(
  bash
  git
  git-lfs
  curl
  ca-certificates
  openssl@3
  gnupg
  tar
  gzip
  xz
)

PROTECTED_DNF=(
  sudo
  curl
  ca-certificates
  openssl
  gnupg2
  tar
  gzip
  xz
  git
  flatpak
  bash
  coreutils
  dnf
  rpm
  systemd
  glibc
  passwd
  shadow-utils
  kernel
  kernel-core
)

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [OPTIONS]

By default this removes only managed dotfile links. Nothing else is touched.

Options:
  --restore-backups  Restore the newest backup snapshot first.
  --allow-legacy     Allow restoring an unverified v1 snapshot (explicit).
  --allow-unsigned   Allow restoring an unsigned v2 snapshot (hashes only).
  --packages         Remove declared Flatpak apps and non-protected DNF packages.
  --yes, -y          Skip the package-removal confirmation prompt.
  --non-interactive  Never prompt; implies --yes.
  --purge-state      Delete all system-init backups, logs, and state (explicit).
  --dry-run          Show actions without changing anything.
  -h, --help         Show this help.

Oh My Zsh, Powerlevel10k, mise, fonts, Postgres.app data, and user project
files are never removed by this script. On macOS, protected Homebrew formulae
such as bash, git, curl, and openssl@3 are kept.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --restore-backups)
      RESTORE_BACKUPS=1
      ;;
    --allow-legacy)
      RESTORE_ALLOW_LEGACY=1
      ;;
    --allow-unsigned)
      RESTORE_ALLOW_UNSIGNED=1
      ;;
    --packages)
      REMOVE_PACKAGES=1
      ;;
    --yes|-y)
      ASSUME_YES=1
      ;;
    --non-interactive)
      ASSUME_YES=1
      ;;
    --purge-state)
      PURGE_STATE=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

platform_detect
platform_load || exit 1
# shellcheck disable=SC2119
modules_resolve || exit 2

init_state_dirs
[[ "$DRY_RUN" == "1" ]] || state_lock_acquire "operation" || exit 1
logging_init

log_section "system-init uninstall"
if [[ "$DRY_RUN" == "1" ]]; then
  log_warn "Dry-run mode: nothing will be removed."
fi

restore_failed=0
if [[ "$RESTORE_BACKUPS" == "1" ]]; then
  snapshot="$(backup_latest)"
  if [[ -z "$snapshot" ]]; then
    record_failure "No backup snapshot is available to restore."
    restore_failed=1
  else
    log_info "Restoring newest snapshot before unlinking: $snapshot"
    if ! backup_restore_snapshot "$snapshot"; then
      record_failure "Backup restore failed."
      restore_failed=1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Managed dotfiles
# ---------------------------------------------------------------------------
log_section "Managed dotfiles"
removed=0
kept=0

if (( restore_failed == 1 )); then
  log_error "Skipping managed dotfile removal because backup restoration did not complete."
fi

entries=""
if (( restore_failed == 0 )); then
  entries="$(dotfiles_entries)" || {
    record_failure "Dotfiles manifest validation failed."
    entries=""
  }
fi

while IFS=$'\t' read -r module strategy source_rel target_rel; do
  [[ -z "${module:-}" ]] && continue
  source_abs="$REPO_ROOT/$source_rel"
  target_abs="$TARGET_HOME/$target_rel"

  if [[ "$strategy" == "symlink" ]]; then
    if dotfiles_target_is_managed "$source_abs" "$target_abs"; then
      if [[ "$DRY_RUN" == "1" ]]; then
        log_dry "remove symlink $(log_cmd "$target_abs")"
        removed=$((removed + 1))
      elif rm -f -- "$target_abs"; then
        log_success "Removed symlink $target_rel"
        removed=$((removed + 1))
      else
        record_failure "Could not remove managed symlink: $target_abs"
      fi
    else
      log_debug "Not removing unmanaged path: $target_abs"
      kept=$((kept + 1))
    fi
  else
    if dotfiles_copy_matches "$source_abs" "$target_abs"; then
      if [[ "$DRY_RUN" == "1" ]]; then
        log_dry "remove copied file $(log_cmd "$target_abs")"
        removed=$((removed + 1))
      elif rm -f -- "$target_abs"; then
        log_success "Removed copied file $target_rel"
        removed=$((removed + 1))
      else
        record_failure "Could not remove managed copied file: $target_abs"
      fi
    else
      kept=$((kept + 1))
    fi
  fi
done <<<"$entries"

if (( restore_failed == 1 )); then
  log_info "No managed dotfiles were removed."
elif [[ "$DRY_RUN" == "1" ]]; then
  log_dry "$removed managed path(s) would be removed; $kept unmanaged path(s) would be kept."
else
  log_info "$removed managed path(s) removed; $kept unmanaged path(s) kept."
fi

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
if [[ "$REMOVE_PACKAGES" == "1" && "$restore_failed" == "1" ]]; then
  log_error "Skipping package removal because backup restoration did not complete."
  log_error "Installed packages and application data were preserved."
elif [[ "$REMOVE_PACKAGES" == "1" ]]; then
  log_section "Declared packages"
  flatpak_apps=()
  dnf_packages=()
  brew_formulae=()
  cask_apps=()
  macos_apps=()

  for module in "${SELECTED_MODULES[@]}"; do
    file="$(packages_module_file "$module")"
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      read -r manager package optional <<<"$line"
      [[ -z "${manager:-}" || -z "${package:-}" ]] && continue
      if ! package_name_is_valid "$package"; then
        record_failure "Refusing invalid package name '$package' in $file."
        continue
      fi
      if [[ -n "${optional:-}" && "$optional" != "optional" ]]; then
        record_failure "Unknown package flag '$optional' in $file."
        continue
      fi
      case "$manager" in
        flatpak)
          if flatpak_package_installed "$package"; then
            flatpak_apps+=("$package")
          fi
          ;;
        dnf)
          if dnf_package_installed "$package"; then
            protected=0
            for item in "${PROTECTED_DNF[@]}"; do
              [[ "$item" == "$package" ]] && protected=1
            done
            if (( protected == 0 )); then
              dnf_packages+=("$package")
            fi
          fi
          ;;
        brew)
          if brew_package_installed "$package"; then
            protected=0
            for item in "${PROTECTED_BREW[@]}"; do
              [[ "$item" == "$package" ]] && protected=1
            done
            if (( protected == 0 )); then
              brew_formulae+=("$package")
            fi
          fi
          ;;
        cask)
          if brew_cask_installed "$package"; then
            cask_apps+=("$package")
          fi
          ;;
      esac
    done <"$file"
  done

  if [[ "$PLATFORM" == "macos" ]] && alacritty_installed_app >/dev/null 2>&1; then
    macos_apps+=("alacritty")
  fi

  if (( ${#flatpak_apps[@]} == 0 && ${#dnf_packages[@]} == 0 && ${#brew_formulae[@]} == 0 && ${#cask_apps[@]} == 0 && ${#macos_apps[@]} == 0 )); then
    log_info "No removable declared packages are installed."
  else
    printf 'Flatpak apps: %s\n' "${flatpak_apps[*]:-none}"
    printf 'DNF packages: %s\n' "${dnf_packages[*]:-none}"
    printf 'Homebrew formulae: %s\n' "${brew_formulae[*]:-none}"
    printf 'Homebrew casks: %s\n' "${cask_apps[*]:-none}"
    printf 'macOS apps: %s\n' "${macos_apps[*]:-none}"

    if [[ "$DRY_RUN" == "1" ]]; then
      (( ${#flatpak_apps[@]} > 0 )) && log_dry "flatpak uninstall ${flatpak_apps[*]}"
      (( ${#dnf_packages[@]} > 0 )) && log_dry "sudo dnf remove ${dnf_packages[*]}"
      (( ${#brew_formulae[@]} > 0 )) && log_dry "brew uninstall ${brew_formulae[*]}"
      (( ${#cask_apps[@]} > 0 )) && log_dry "brew uninstall --cask ${cask_apps[*]}"
      (( ${#macos_apps[@]} > 0 )) && alacritty_remove
    else
      confirmed=1
      if [[ "$ASSUME_YES" != "1" ]]; then
        if [[ -t 0 ]]; then
          printf 'Remove these packages? Type yes to continue: '
          read -r answer
          [[ "$answer" == "yes" ]] || confirmed=0
        else
          confirmed=0
          record_failure "Refusing package removal without --yes on a non-interactive terminal."
        fi
      fi

      if [[ "$confirmed" == "1" ]]; then
        if (( ${#flatpak_apps[@]} > 0 )); then
          flatpak_remove "${flatpak_apps[@]}" || record_failure "Flatpak removal failed."
        fi
        if (( ${#dnf_packages[@]} > 0 )); then
          dnf_remove "${dnf_packages[@]}" || record_failure "DNF removal failed."
        fi
        if [[ " ${brew_formulae[*]} " == *" valkey "* ]]; then
          if brew_service_stop valkey; then
            log_debug "Stopped the Valkey service before package removal."
          fi
        fi
        if (( ${#brew_formulae[@]} > 0 )); then
          brew_remove_formulae "${brew_formulae[@]}" || record_failure "Homebrew formula removal failed."
        fi
        if (( ${#cask_apps[@]} > 0 )); then
          brew_remove_casks "${cask_apps[@]}" || record_failure "Homebrew cask removal failed."
        fi
        if [[ " ${macos_apps[*]} " == *" alacritty "* ]]; then
          alacritty_remove || record_failure "Alacritty removal failed."
        fi
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
if [[ "$PURGE_STATE" == "1" ]] && (( restore_failed == 1 || ${#FAILED_ITEMS[@]} > 0 )); then
  log_error "Refusing to purge state because the uninstall recorded failures."
  log_error "Backups, journals, and recovery staging data were preserved at: $STATE_DIR"
  record_failure "State purge refused after a failed uninstall operation."
elif [[ "$PURGE_STATE" == "1" ]]; then
  log_section "State and backups"
  if [[ -d "$STATE_DIR" ]]; then
    if ! state_dir_is_safe; then
      record_failure "Refusing to purge an unsafe state directory: $STATE_DIR"
    elif [[ "$DRY_RUN" == "1" ]]; then
      log_dry "delete $(log_cmd "$STATE_DIR")"
    elif safe_rm_rf "$STATE_DIR"; then
      log_success "Deleted $STATE_DIR"
    else
      record_failure "Could not delete $STATE_DIR"
    fi
  else
    log_info "No state directory exists."
  fi
fi

if (( ${#FAILED_ITEMS[@]} > 0 )); then
  log_error "Uninstall completed with failures."
  exit 1
fi

state_lock_release
if [[ "$DRY_RUN" == "1" ]]; then
  log_success "Dry-run complete. Nothing was removed."
elif (( ${#FAILED_ITEMS[@]} > 0 )); then
  log_error "Uninstall completed with failures; some paths or recovery material were preserved."
else
  log_success "Uninstall complete."
fi
log_info "Packages and system services are only changed by explicit flags."
