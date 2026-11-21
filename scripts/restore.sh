#!/usr/bin/env bash
# Restore configuration files from a system-init backup snapshot.
set -Eeuo pipefail

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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_ROOT

# shellcheck source=../lib/bootstrap.sh
source "$REPO_ROOT/lib/bootstrap.sh"
export DEV_SETUP_BOOTSTRAP_READONLY=1
bootstrap_run "$@"

# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/platform.sh
source "$REPO_ROOT/lib/platform.sh"
# shellcheck source=../lib/dotfiles.sh
source "$REPO_ROOT/lib/dotfiles.sh"
# shellcheck source=../lib/backups.sh
source "$REPO_ROOT/lib/backups.sh"
trap 'state_lock_release' EXIT

SNAPSHOT=""
RESTORE_LATEST=0
SHOW_LIST=0
RECOVER_JOURNAL=""
# Explicit flags only; do not inherit a permissive environment default.
RESTORE_ALLOW_LEGACY=0
RESTORE_ALLOW_UNSIGNED=0

usage() {
  cat <<'EOF'
Usage: ./scripts/restore.sh (--latest | --snapshot PATH) [OPTIONS]
       ./scripts/restore.sh --recover-journal PATH

Options:
  --latest          Restore the newest snapshot.
  --snapshot PATH   Restore a specific snapshot directory.
  --list            List available snapshots and exit.
  --allow-legacy    Restore an unverified v1 snapshot (explicit; unsafe).
  --allow-unsigned  Restore an unsigned v2 snapshot (hashes only).
  --recover-journal PATH  Recover an interrupted restore from its journal.
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
    --allow-legacy)
      RESTORE_ALLOW_LEGACY=1
      ;;
    --allow-unsigned)
      RESTORE_ALLOW_UNSIGNED=1
      ;;
    --recover-journal)
      if (( $# < 2 )); then
        log_error "--recover-journal requires a path."
        exit 2
      fi
      shift
      RECOVER_JOURNAL="$1"
      ;;
    --recover-journal=*)
      RECOVER_JOURNAL="${1#--recover-journal=}"
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

if [[ -n "$RECOVER_JOURNAL" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "would recover the restore journal: $(log_cmd "$RECOVER_JOURNAL")"
    exit 0
  fi
  log_section "system-init restore recovery"
  backup_restore_recover_journal "$RECOVER_JOURNAL" || exit 1
  exit 0
fi

if [[ "$SHOW_LIST" == "1" ]]; then
  if [[ ! -d "$BACKUP_DIR" ]]; then
    printf 'No backups found at %s\n' "$(backup_sanitize_text "$BACKUP_DIR")"
    exit 0
  fi
  printf 'Snapshots in %s:\n\n' "$(backup_sanitize_text "$BACKUP_DIR")"
  while IFS= read -r snapshot; do
    [[ -z "$snapshot" ]] && continue
    if ! validated="$(backup_snapshot_path "$snapshot" 2>/dev/null)"; then
      printf 'invalid snapshot: %s\n\n' "$(backup_sanitize_text "$snapshot")"
      continue
    fi
    printf '%s\n' "$(backup_sanitize_text "$validated")"
    status="$(backup_snapshot_status "$validated")"
    printf '  status: %s\n' "$status"
    case "$status" in
      invalid-v2|invalid-signature|invalid-payload|empty-v2)
        printf '\n'
        continue
        ;;
    esac
    backup_print_metadata "$validated"
    if [[ -f "$validated/manifest.v2" ]]; then
      printf '  paths: %s\n\n' "$(($(wc -l <"$validated/manifest.v2") - 1))"
    else
      printf '  paths: %s\n\n' "$(wc -l <"$validated/manifest.tsv")"
    fi
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

log_section "system-init restore"
log_info "Snapshot: $SNAPSHOT"
if [[ "$DRY_RUN" == "1" ]]; then
  log_warn "Dry-run mode: no files will be restored."
fi

backup_restore_snapshot "$SNAPSHOT" || exit 1
