#!/usr/bin/env bash
# Create a backup snapshot of managed configuration files.
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
# shellcheck source=../lib/dotfiles.sh
source "$REPO_ROOT/lib/dotfiles.sh"
# shellcheck source=../lib/backups.sh
source "$REPO_ROOT/lib/backups.sh"
trap 'state_lock_release' EXIT

usage() {
  cat <<'EOF'
Usage: ./scripts/backup.sh [OPTIONS]

Back up manifest-managed dotfiles to a timestamped snapshot outside the repo.

Options:
  --dry-run   Show what would be backed up; change nothing.
  -h, --help  Show this help.
EOF
}

while (( $# > 0 )); do
  case "$1" in
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
modules_resolve || exit 2

init_state_dirs
logging_init
[[ "$DRY_RUN" == "1" ]] || state_lock_acquire "operation" || exit 1

log_section "system-init backup"
log_info "Target home: $TARGET_HOME"

backup_init "manual-backup" || exit 1

count=0
entries="$(dotfiles_entries)" || {
  backup_snapshot_mark_incomplete || true
  backup_discard_snapshot || true
  record_failure "Dotfiles manifest validation failed."
  exit 1
}

while IFS=$'\t' read -r module _strategy _source_rel target_rel; do
  [[ -z "${module:-}" ]] && continue
  target_abs="$TARGET_HOME/$target_rel"
  if [[ ! -e "$target_abs" && ! -L "$target_abs" ]]; then
    log_debug "Skipping missing path: $target_abs"
    continue
  fi
  if ! backup_path "$target_abs" "dotfile"; then
    backup_snapshot_mark_incomplete || true
    record_failure "Failed to back up $target_abs"
    break
  fi
  count=$((count + 1))
done <<<"$entries"

if (( ${#FAILED_ITEMS[@]} > 0 )); then
  backup_snapshot_mark_incomplete || true
  log_error "Backup completed with failures; snapshot remains incomplete and will not be selected as latest."
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log_dry "Would back up $count path(s)."
  exit 0
fi

if (( count == 0 )) || (( BACKUP_ENTRY_COUNT == 0 )); then
  backup_discard_snapshot || {
    record_failure "Could not remove the empty backup snapshot."
    exit 1
  }
  log_warn "No managed paths were available; no snapshot was created."
  exit 0
fi

if ! backup_finalize; then
  backup_snapshot_mark_incomplete || true
  log_error "Backup snapshot did not verify; refusing to prune older backups."
  exit 1
fi

if ! prune_backups; then
  record_failure "Backup pruning failed."
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log_dry "Would back up $count path(s)."
else
  log_success "Backed up $count path(s) to $BACKUP_RUN_DIR"
fi
