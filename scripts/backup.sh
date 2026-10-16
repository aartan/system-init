#!/usr/bin/env bash
# Create a backup snapshot of managed configuration files.
set -Eeuo pipefail

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

INCLUDE_SYSTEM=0

usage() {
  cat <<'EOF'
Usage: ./scripts/backup.sh [OPTIONS]

Back up manifest-managed dotfiles to a timestamped snapshot outside the repo.

Options:
  --dry-run   Show what would be backed up; change nothing.
  --system    Also back up /etc/keyd/default.conf.
  -h, --help  Show this help.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --system)
      INCLUDE_SYSTEM=1
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

log_section "system-init backup"
log_info "Target home: $TARGET_HOME"

backup_init "manual-backup"

count=0
entries="$(dotfiles_entries)" || {
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
  backup_path "$target_abs" "dotfile" || record_failure "Failed to back up $target_abs"
  count=$((count + 1))
done <<<"$entries"

if [[ "$INCLUDE_SYSTEM" == "1" ]]; then
  if [[ -e /etc/keyd/default.conf ]]; then
    backup_path /etc/keyd/default.conf "system-config" || \
      record_failure "Failed to back up /etc/keyd/default.conf"
    count=$((count + 1))
  else
    log_warn "/etc/keyd/default.conf does not exist; nothing to back up."
  fi
fi

prune_backups

if (( ${#FAILED_ITEMS[@]} > 0 )); then
  log_error "Backup completed with failures."
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log_dry "Would back up $count path(s)."
else
  log_success "Backed up $count path(s) to $BACKUP_RUN_DIR"
fi
