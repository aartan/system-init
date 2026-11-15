#!/usr/bin/env bash
# Update Fedora packages, Flatpak apps, and mise-managed runtimes.
set -Eeuo pipefail

if (( EUID == 0 )); then
  printf 'system-init: refusing to run as root. Run this as your normal user; sudo is requested only when needed.\n' >&2
  exit 1
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_ROOT

# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/platform.sh
source "$REPO_ROOT/lib/platform.sh"
# shellcheck source=../lib/packages.sh
source "$REPO_ROOT/lib/packages.sh"
# shellcheck source=../lib/modules.sh
source "$REPO_ROOT/lib/modules.sh"
# shellcheck source=../lib/backups.sh
source "$REPO_ROOT/lib/backups.sh"
trap 'state_lock_release' EXIT
# shellcheck source=installers/dnf.sh
source "$REPO_ROOT/installers/dnf.sh"
# shellcheck source=installers/flatpak.sh
source "$REPO_ROOT/installers/flatpak.sh"
# shellcheck source=installers/mise.sh
source "$REPO_ROOT/installers/mise.sh"

SKIP_PACKAGES=0
SKIP_RUNTIMES=0
SKIP_REPO=0

usage() {
  cat <<'EOF'
Usage: ./scripts/update.sh [OPTIONS]

Update system packages, Flatpak applications, the system-init Git checkout, and
the runtime versions pinned in config/runtimes.conf. Pins are never changed
automatically.

Options:
  --dry-run         Show commands without changing the system.
  --skip-packages   Do not run dnf or Flatpak updates.
  --skip-runtimes   Do not reinstall mise runtimes.
  --skip-repo       Do not pull the system-init Git checkout.
  -h, --help        Show this help.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-packages)
      SKIP_PACKAGES=1
      ;;
    --skip-runtimes)
      SKIP_RUNTIMES=1
      ;;
    --skip-repo)
      SKIP_REPO=1
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
modules_resolve || exit 2

init_state_dirs
[[ "$DRY_RUN" == "1" ]] || state_lock_acquire "operation" || exit 1
logging_init

log_section "system-init update"
log_info "Platform: $PLATFORM_NAME"

if [[ "$DRY_RUN" == "1" ]]; then
  log_warn "Dry-run mode: no changes will be made."
fi

if [[ "$SKIP_PACKAGES" != "1" ]]; then
  platform_sudo_prepare || exit 1

  if [[ "$PLATFORM" == "fedora" ]]; then
    dnf_update || record_failure "DNF update failed."
  fi

  if have_command flatpak; then
    flatpak_update || record_failure "Flatpak update failed."
  fi
else
  log_info "Skipping system package updates."
fi

if [[ "$SKIP_REPO" != "1" ]]; then
  if ! git_checkout_owned_by_user "$REPO_ROOT"; then
    record_failure "Refusing to update a checkout whose .git or directory is not a user-owned real directory."
  elif git_safe -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log_dry "git_safe -C $(log_cmd "$REPO_ROOT") pull --ff-only"
    elif git_safe -C "$REPO_ROOT" pull --ff-only; then
      log_success "Updated the system-init Git checkout."
    else
      record_failure "Could not fast-forward the system-init Git checkout."
    fi
  else
    log_info "No Git remote configured; skipping repository update."
  fi
fi

if [[ "$SKIP_RUNTIMES" != "1" ]]; then
  mise_install_runtimes || record_failure "Runtime update failed."
else
  log_info "Skipping runtime updates."
fi

if (( ${#FAILED_ITEMS[@]} > 0 )); then
  log_error "Update completed with failures."
  exit 1
fi

state_lock_release
log_success "Update complete."
printf 'Run ./scripts/doctor.sh to verify the workstation.\n'
