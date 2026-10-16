#!/usr/bin/env bash
# Backup snapshot handling.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_BACKUPS_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_BACKUPS_SOURCED=1

BACKUP_RUN_DIR=""

backup_init() {
  local reason="${1:-manual}"
  local timestamp candidate

  if [[ -n "$BACKUP_RUN_DIR" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "would create backup snapshot for: $reason"
    return 0
  fi

  mkdir -p -- "$BACKUP_DIR"
  chmod 700 -- "$BACKUP_DIR"
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  candidate="$BACKUP_DIR/$timestamp"

  local suffix=2
  while [[ -e "$candidate" ]]; do
    candidate="$BACKUP_DIR/$timestamp-$suffix"
    suffix=$((suffix + 1))
  done

  mkdir -p -- "$candidate/files"
  chmod 700 -- "$candidate" "$candidate/files"
  printf 'created=%s\nreason=%s\nhost=%s\nuser=%s\n' \
    "$timestamp" "$reason" "$(hostname)" "$TARGET_USER" >"$candidate/metadata.conf"
  : >"$candidate/manifest.tsv"
  chmod 600 -- "$candidate/manifest.tsv" "$candidate/metadata.conf"

  BACKUP_RUN_DIR="$candidate"
  log_info "Backup snapshot: $BACKUP_RUN_DIR"
}

backup_path() {
  local source_path="$1"
  local kind="${2:-file}"
  local reason="${3:-conflict}"

  if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then
    log_debug "Nothing to back up at $source_path"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "back up $(log_cmd "$source_path") to a new snapshot"
    return 0
  fi

  backup_init "$reason" || return 1

  local destination="$BACKUP_RUN_DIR/files${source_path}"
  local manifest="$BACKUP_RUN_DIR/manifest.tsv"

  if grep -Fxq -- "$source_path" <(cut -f1 "$manifest") 2>/dev/null; then
    log_debug "Path already backed up in this snapshot: $source_path"
    return 0
  fi

  mkdir -p -- "$(dirname -- "$destination")" || return 1
  if ! cp -a --no-dereference -- "$source_path" "$destination"; then
    log_error "Failed to back up $source_path"
    return 1
  fi

  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    log_error "Backup verification failed for $source_path"
    return 1
  fi

  printf '%s\t%s\t%s\n' "$source_path" "$destination" "$kind" >>"$manifest"
  log_debug "Backed up $source_path -> $destination"
}

backup_latest() {
  list_backup_runs | head -n 1
}

backup_dotfile_targets() {
  local entries module strategy source_rel target_rel source_abs target_abs
  local count=0

  if ! entries="$(dotfiles_entries)"; then
    return 1
  fi

  while IFS=$'\t' read -r module strategy source_rel target_rel; do
    [[ -z "${module:-}" ]] && continue
    source_abs="$REPO_ROOT/$source_rel"
    target_abs="$TARGET_HOME/$target_rel"

    if [[ ! -e "$target_abs" && ! -L "$target_abs" ]]; then
      log_debug "Nothing to back up for dotfile target: $target_abs"
      continue
    fi

    # An already-correct target is not a conflict and needs no snapshot.
    if [[ "$strategy" == "symlink" ]]; then
      dotfiles_target_is_managed "$source_abs" "$target_abs" && continue
    else
      dotfiles_copy_matches "$source_abs" "$target_abs" && continue
    fi

    backup_path "$target_abs" "dotfile" "pre-install" || return 1
    count=$((count + 1))
  done <<<"$entries"

  log_debug "Processed $count dotfile target(s) requiring backup."
}

backup_snapshot_exists() {
  [[ -d "$1" && -f "$1/manifest.tsv" ]]
}

backup_manifest_targets() {
  local snapshot="$1"
  [[ -f "$snapshot/manifest.tsv" ]] || return 1
  cut -f1 -- "$snapshot/manifest.tsv"
}

backup_restore_path() {
  local original="$1"
  local stored="$2"
  local use_sudo="$3"

  if [[ ! -e "$stored" && ! -L "$stored" ]]; then
    log_error "Backup payload missing: $stored"
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "restore $(log_cmd "$stored") -> $(log_cmd "$original")"
    return 0
  fi

  mkdir -p -- "$(dirname -- "$original")" || return 1

  if [[ -e "$original" || -L "$original" ]]; then
    if [[ "$use_sudo" == "1" ]]; then
      run_sudo rm -rf -- "$original" || return 1
    else
      rm -rf -- "$original" || return 1
    fi
  fi

  if [[ "$use_sudo" == "1" ]]; then
    run_sudo cp -a --no-dereference -- "$stored" "$original" || return 1
  else
    cp -a --no-dereference -- "$stored" "$original" || return 1
  fi

  log_success "Restored $original"
}

backup_restore_snapshot() {
  local snapshot="$1"
  local allow_system="${2:-0}"
  local original stored kind use_sudo
  local restored=0 skipped=0

  backup_snapshot_exists "$snapshot" || {
    log_error "Not a valid system-init backup snapshot: $snapshot"
    return 1
  }

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "restore snapshot $(log_cmd "$snapshot")"
  fi

  while IFS=$'\t' read -r original stored kind; do
    [[ -z "${original:-}" ]] && continue
    [[ "$original" == \#* ]] && continue

    if ! path_is_under "$original" "$TARGET_HOME"; then
      if [[ "$allow_system" != "1" ]]; then
        log_warn "Skipping system path (use --system to restore): $original"
        skipped=$((skipped + 1))
        continue
      fi
      use_sudo=1
    else
      use_sudo=0
    fi

    backup_restore_path "$original" "$stored" "$use_sudo" || return 1
    restored=$((restored + 1))
  done <"$snapshot/manifest.tsv"

  log_info "Restore complete: $restored path(s) restored, $skipped skipped."
}
