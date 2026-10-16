#!/usr/bin/env bash
# Remove system-init managed links and, explicitly, optional components.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export REPO_ROOT

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
# shellcheck source=installers/dnf.sh
source "$REPO_ROOT/installers/dnf.sh"
# shellcheck source=installers/flatpak.sh
source "$REPO_ROOT/installers/flatpak.sh"
# shellcheck source=installers/keyd.sh
source "$REPO_ROOT/installers/keyd.sh"

REMOVE_PACKAGES=0
REMOVE_SYSTEM=0
RESTORE_BACKUPS=0
PURGE_STATE=0
ASSUME_YES=0

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
)

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [OPTIONS]

By default this removes only managed dotfile links. Nothing else is touched.

Options:
  --restore-backups  Restore the newest backup snapshot first.
  --system           Disable keyd and remove /etc/keyd/default.conf (explicit).
  --packages         Remove declared Flatpak apps and non-protected DNF packages.
  --yes              Skip the package-removal confirmation prompt.
  --purge-state      Delete all system-init backups, logs, and state (explicit).
  --dry-run          Show actions without changing anything.
  -h, --help         Show this help.

The keyd binary, Oh My Zsh, Powerlevel10k, mise, fonts, and user project files
are never removed by this script.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --restore-backups)
      RESTORE_BACKUPS=1
      ;;
    --system)
      REMOVE_SYSTEM=1
      ;;
    --packages)
      REMOVE_PACKAGES=1
      ;;
    --yes|-y)
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
logging_init

log_section "system-init uninstall"
if [[ "$DRY_RUN" == "1" ]]; then
  log_warn "Dry-run mode: nothing will be removed."
fi

if [[ "$RESTORE_BACKUPS" == "1" ]]; then
  snapshot="$(backup_latest)"
  if [[ -z "$snapshot" ]]; then
    record_failure "No backup snapshot is available to restore."
  else
    log_info "Restoring newest snapshot before unlinking: $snapshot"
    if [[ "$REMOVE_SYSTEM" == "1" && "$DRY_RUN" != "1" ]]; then
      if ! sudo -n true >/dev/null 2>&1; then
        if [[ -t 0 ]]; then
          sudo -v
        else
          record_failure "--restore-backups --system needs sudo, but stdin is not a terminal."
        fi
      fi
    fi
    backup_restore_snapshot "$snapshot" "$([[ "$REMOVE_SYSTEM" == "1" ]] && printf '1' || printf '0')" || \
      record_failure "Backup restore failed."
  fi
fi

# ---------------------------------------------------------------------------
# Managed dotfiles
# ---------------------------------------------------------------------------
log_section "Managed dotfiles"
entries="$(dotfiles_entries)" || {
  record_failure "Dotfiles manifest validation failed."
  entries=""
}

removed=0
kept=0

while IFS=$'\t' read -r module strategy source_rel target_rel; do
  [[ -z "${module:-}" ]] && continue
  source_abs="$REPO_ROOT/$source_rel"
  target_abs="$TARGET_HOME/$target_rel"

  if [[ "$strategy" == "symlink" ]]; then
    if dotfiles_target_is_managed "$source_abs" "$target_abs"; then
      if [[ "$DRY_RUN" == "1" ]]; then
        log_dry "remove symlink $(log_cmd "$target_abs")"
      else
        rm -f -- "$target_abs" && log_success "Removed symlink $target_rel"
      fi
      removed=$((removed + 1))
    else
      log_debug "Not removing unmanaged path: $target_abs"
      kept=$((kept + 1))
    fi
  else
    if dotfiles_copy_matches "$source_abs" "$target_abs"; then
      if [[ "$DRY_RUN" == "1" ]]; then
        log_dry "remove copied file $(log_cmd "$target_abs")"
      else
        rm -rf -- "$target_abs" && log_success "Removed copied file $target_rel"
      fi
      removed=$((removed + 1))
    else
      kept=$((kept + 1))
    fi
  fi
done <<<"$entries"

if [[ "$DRY_RUN" == "1" ]]; then
  log_dry "$removed managed path(s) would be removed; $kept unmanaged path(s) would be kept."
else
  log_info "$removed managed path(s) removed; $kept unmanaged path(s) kept."
fi

# ---------------------------------------------------------------------------
# keyd system configuration
# ---------------------------------------------------------------------------
if [[ "$REMOVE_SYSTEM" == "1" ]]; then
  log_section "keyd system configuration"
  if [[ -f "$KEYD_CONFIG" ]] && keyd_config_matches_repo; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log_dry "back up and remove $KEYD_CONFIG; disable keyd.service"
    else
      backup_path "$KEYD_CONFIG" "uninstall-system" || record_failure "Could not back up keyd config."
      run_sudo systemctl disable --now keyd.service || record_warning "Could not disable keyd.service."
      run_sudo rm -f -- "$KEYD_CONFIG" || record_failure "Could not remove $KEYD_CONFIG."
      log_success "Removed managed keyd configuration (binary left installed)."
    fi
  else
    log_warn "keyd configuration is absent or was modified; leaving it untouched."
  fi
fi

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
if [[ "$REMOVE_PACKAGES" == "1" ]]; then
  log_section "Declared packages"
  flatpak_apps=()
  dnf_packages=()

  for module in "${SELECTED_MODULES[@]}"; do
    file="$(packages_module_file "$module")"
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      read -r manager package optional <<<"$line"
      [[ -z "${manager:-}" || -z "${package:-}" ]] && continue
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
      esac
    done <"$file"
  done

  if (( ${#flatpak_apps[@]} == 0 && ${#dnf_packages[@]} == 0 )); then
    log_info "No removable declared packages are installed."
  else
    printf 'Flatpak apps: %s\n' "${flatpak_apps[*]:-none}"
    printf 'DNF packages: %s\n' "${dnf_packages[*]:-none}"

    if [[ "$DRY_RUN" == "1" ]]; then
      (( ${#flatpak_apps[@]} > 0 )) && log_dry "flatpak uninstall ${flatpak_apps[*]}"
      (( ${#dnf_packages[@]} > 0 )) && log_dry "sudo dnf remove ${dnf_packages[*]}"
    else
      confirmed=1
      if [[ "$ASSUME_YES" != "1" ]]; then
        if [[ -t 0 ]]; then
          printf 'Remove these packages? Type yes to continue: '
          read -r answer
          [[ "$answer" == "yes" ]] || confirmed=0
        else
          confirmed=0
          log_error "Refusing package removal without --yes on a non-interactive terminal."
        fi
      fi

      if [[ "$confirmed" == "1" ]]; then
        if (( ${#flatpak_apps[@]} > 0 )); then
          flatpak_remove "${flatpak_apps[@]}" || record_failure "Flatpak removal failed."
        fi
        if (( ${#dnf_packages[@]} > 0 )); then
          dnf_remove "${dnf_packages[@]}" || record_failure "DNF removal failed."
        fi
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
if [[ "$PURGE_STATE" == "1" ]]; then
  log_section "State and backups"
  if [[ -d "$STATE_DIR" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log_dry "delete $(log_cmd "$STATE_DIR")"
    else
      rm -rf -- "$STATE_DIR" && log_success "Deleted $STATE_DIR"
    fi
  else
    log_info "No state directory exists."
  fi
fi

if (( ${#FAILED_ITEMS[@]} > 0 )); then
  log_error "Uninstall completed with failures."
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log_success "Dry-run complete. Nothing was removed."
else
  log_success "Uninstall complete."
fi
log_info "Packages and system services are only changed by explicit flags."
