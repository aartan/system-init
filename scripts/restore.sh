#!/usr/bin/env bash
# Restore configuration files from a system-init backup snapshot.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_ROOT

# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/platform.sh
source "$REPO_ROOT/lib/platform.sh"
# shellcheck source=../lib/backups.sh
source "$REPO_ROOT/lib/backups.sh"

SNAPSHOT=""
RESTORE_LATEST=0
ALLOW_SYSTEM=0
SHOW_LIST=0

usage() {
  cat <<'EOF'
Usage: ./scripts/restore.sh (--latest | --snapshot PATH) [OPTIONS]

Options:
  --latest          Restore the newest snapshot.
  --snapshot PATH   Restore a specific snapshot directory.
  --list            List available snapshots and exit.
  --system          Also restore paths outside $HOME (for example /etc/keyd).
  --dry-run         Show what would be restored; change nothing.
  -h, --help        Show this help.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --latest)
      RESTORE_LATEST=1
      ;;
    --snapshot)
      if (( $# < 2 )); then
        log_error "--snapshot requires a path."
        exit 2
      fi
      shift
      SNAPSHOT="$1"
      ;;
    --snapshot=*)
      SNAPSHOT="${1#--snapshot=}"
      ;;
    --list)
      SHOW_LIST=1
      ;;
    --system)
      ALLOW_SYSTEM=1
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

if [[ "$SHOW_LIST" == "1" ]]; then
  if [[ ! -d "$BACKUP_DIR" ]]; then
    printf 'No backups found at %s\n' "$BACKUP_DIR"
    exit 0
  fi
  printf 'Snapshots in %s:\n\n' "$BACKUP_DIR"
  while IFS= read -r snapshot; do
    [[ -z "$snapshot" ]] && continue
    printf '%s\n' "$snapshot"
    if [[ -f "$snapshot/metadata.conf" ]]; then
      sed 's/^/  /' "$snapshot/metadata.conf"
    fi
    printf '  paths: %s\n\n' "$(wc -l <"$snapshot/manifest.tsv" 2>/dev/null || printf '?')"
  done < <(list_backup_runs)
  exit 0
fi

if [[ "$RESTORE_LATEST" == "1" && -n "$SNAPSHOT" ]]; then
  log_error "Use either --latest or --snapshot, not both."
  exit 2
fi

if [[ "$RESTORE_LATEST" == "1" ]]; then
  SNAPSHOT="$(backup_latest)"
  if [[ -z "$SNAPSHOT" ]]; then
    log_error "No backup snapshots exist in $BACKUP_DIR"
    exit 1
  fi
fi

if [[ -z "$SNAPSHOT" ]]; then
  log_error "Specify --latest, --snapshot PATH, or --list."
  usage >&2
  exit 2
fi

if [[ ! -d "$SNAPSHOT" ]]; then
  log_error "Snapshot directory not found: $SNAPSHOT"
  exit 1
fi

if [[ "$ALLOW_SYSTEM" == "1" && "$DRY_RUN" != "1" ]]; then
  if ! sudo -n true >/dev/null 2>&1; then
    if [[ -t 0 ]]; then
      log_info "System restore requested; requesting sudo access."
      sudo -v
    else
      log_error "--system requires sudo, but stdin is not a terminal."
      exit 1
    fi
  fi
fi

log_section "system-init restore"
log_info "Snapshot: $SNAPSHOT"
if [[ "$DRY_RUN" == "1" ]]; then
  log_warn "Dry-run mode: no files will be restored."
fi

backup_restore_snapshot "$SNAPSHOT" "$ALLOW_SYSTEM" || exit 1
