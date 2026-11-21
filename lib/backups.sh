#!/usr/bin/env bash
# Backup snapshot handling.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_BACKUPS_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_BACKUPS_SOURCED=1

BACKUP_RUN_DIR=""
BACKUP_SIGNING_KEY="${BACKUP_SIGNING_KEY:-}"
BACKUP_WARNED_UNSIGNED="${BACKUP_WARNED_UNSIGNED:-0}"
BACKUP_ENTRIES=()
BACKUP_ENTRY_COUNT=0
BACKUP_SNAPSHOT_COMPLETE=0
declare -gA BACKUP_SOURCE_PATHS=()
BACKUP_SIGNATURE_ERROR=""

# Restore policy. Defaults are fail closed; entrypoints expose explicit flags.
RESTORE_ALLOW_LEGACY="${RESTORE_ALLOW_LEGACY:-0}"
RESTORE_ALLOW_UNSIGNED="${RESTORE_ALLOW_UNSIGNED:-0}"
RESTORE_JOURNAL="${RESTORE_JOURNAL:-}"

backup_signing_key_valid() {
  [[ "${1:-}" =~ ^[0-9A-Fa-f]{40}$ ]]
}

backup_sign_manifest() {
  local manifest="$1"
  local signature="$2"

  if ! backup_signing_key_valid "$BACKUP_SIGNING_KEY"; then
    log_error "BACKUP_SIGNING_KEY must be a full 40-hex OpenPGP fingerprint."
    return 1
  fi
  if ! have_command gpg; then
    log_error "gpg is required to sign backup manifests."
    return 1
  fi

  rm -f -- "$signature"
  if ! gpg --batch --no-tty --yes --armor --detach-sign \
    --local-user "$BACKUP_SIGNING_KEY" \
    --output "$signature" -- "$manifest" 2>/dev/null; then
    rm -f -- "$signature"
    log_error "Failed to sign the backup manifest with $BACKUP_SIGNING_KEY."
    return 1
  fi
  chmod_mode 600 "$signature"
}

# 0 = valid signature by the configured primary fingerprint, 1 = invalid,
# 2 = no trusted key/gpg available. Callers must fail closed on anything but 0.
#
# GnuPG returns status 0 for a good cryptographic signature even when the
# signing key is revoked or expired, and it may emit VALIDSIG in that case. A
# signature is therefore only accepted when the machine-readable status has
# exactly one GOODSIG/VALIDSIG pair, no revocation/expiry/error status, and
# the primary-key fingerprint in the VALIDSIG record is the configured one.
_backup_signature_verify() {
  local manifest="$1"
  local signature="$2"
  local status status_line fpr primary validsig_count goodsig_count newsig_count

  BACKUP_SIGNATURE_ERROR=""

  backup_signing_key_valid "$BACKUP_SIGNING_KEY" || {
    BACKUP_SIGNATURE_ERROR="No valid BACKUP_SIGNING_KEY fingerprint is configured."
    return 2
  }
  have_command gpg || {
    BACKUP_SIGNATURE_ERROR="gpg is not available."
    return 2
  }
  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    BACKUP_SIGNATURE_ERROR="Manifest is missing or a symlink."
    return 1
  }
  [[ -f "$signature" && ! -L "$signature" ]] || {
    BACKUP_SIGNATURE_ERROR="Signature is missing or a symlink."
    return 1
  }

  if ! status="$(gpg --batch --no-tty --status-fd 1 --verify "$signature" "$manifest" 2>/dev/null)"; then
    BACKUP_SIGNATURE_ERROR="gpg rejected the signature."
    return 1
  fi

  if grep -Eq '^\[GNUPG:\] (REVKEYSIG|KEYREVOKED|EXPKEYSIG|KEYEXPIRED|EXPSIG|NO_PUBKEY|ERRSIG|BADSIG|FAILURE|BADARMOR) ' <<<"$status"; then
    BACKUP_SIGNATURE_ERROR="Signature status is invalid, revoked, expired, or the public key is unavailable."
    return 1
  fi

  validsig_count="$(grep -c '^\[GNUPG:\] VALIDSIG ' <<<"$status" || true)"
  goodsig_count="$(grep -c '^\[GNUPG:\] GOODSIG ' <<<"$status" || true)"
  newsig_count="$(grep -c '^\[GNUPG:\] NEWSIG ' <<<"$status" || true)"
  if [[ "$validsig_count" != "1" || "$goodsig_count" != "1" ]] \
    || (( newsig_count > 1 )); then
    BACKUP_SIGNATURE_ERROR="Signature status is ambiguous or missing a unique valid signature."
    return 1
  fi

  status_line="$(grep '^\[GNUPG:\] VALIDSIG ' <<<"$status" | head -n 1)"
  fpr="$(awk '{ print $3 }' <<<"$status_line")"
  primary="$(awk 'NF >= 12 { print $NF }' <<<"$status_line")"

  if [[ -n "$primary" ]]; then
    # The last VALIDSIG field is the primary-key fingerprint when the
    # signature was made by a signing subkey. Require the configured primary.
    [[ "${primary^^}" == "${BACKUP_SIGNING_KEY^^}" ]] || {
      BACKUP_SIGNATURE_ERROR="Signing key's primary fingerprint does not match BACKUP_SIGNING_KEY."
      return 1
    }
  else
    [[ "${fpr^^}" == "${BACKUP_SIGNING_KEY^^}" ]] || {
      BACKUP_SIGNATURE_ERROR="Signing key fingerprint does not match BACKUP_SIGNING_KEY."
      return 1
    }
  fi

  [[ "$fpr" =~ ^[0-9A-Fa-f]{40}$ ]] || {
    BACKUP_SIGNATURE_ERROR="GnuPG did not report a usable signing fingerprint."
    return 1
  }
  return 0
}

backup_signature_verify() {
  local rc
  _backup_signature_verify "$@"; rc=$?
  if (( rc != 0 )) && [[ -n "$BACKUP_SIGNATURE_ERROR" ]]; then
    log_error "$BACKUP_SIGNATURE_ERROR"
  fi
  return "$rc"
}

# Restored managed files are owner-only. Symlinks are not chmodded.
backup_normalized_mode() {
  if [[ -L "$1" ]]; then
    printf '0777\n'
  else
    printf '0600\n'
  fi
}

BACKUP_SECURE_DIR=""
BACKUP_SECURE_MANIFEST=""
BACKUP_SECURE_SIG=""
BACKUP_SECURE_SHA=""

# Build and sign a canonical manifest in private storage. Publication is a
# separate step so finalization can verify every payload before replacing the
# previous valid manifest. Build failures never touch the published pair.
backup_manifest_build() {
  local run="$BACKUP_RUN_DIR"
  local secure_dir secure_manifest secure_sig unsorted manifest_sha_before manifest_sha_after
  local produced

  [[ -n "$run" ]] || return 1
  BACKUP_SECURE_DIR=""
  BACKUP_SECURE_MANIFEST=""
  BACKUP_SECURE_SIG=""
  BACKUP_SECURE_SHA=""

  if (( BACKUP_ENTRY_COUNT == 0 )); then
    log_error "Refusing to build an empty backup manifest."
    return 1
  fi
  if [[ -z "$BACKUP_SIGNING_KEY" && ( -e "$run/manifest.v2.sig" || -L "$run/manifest.v2.sig" ) ]]; then
    log_error "Refusing to downgrade a signed snapshot to an unsigned manifest."
    return 1
  fi

  init_private_dir "$STATE_DIR" || return 1
  secure_dir="$(mktemp -d "$STATE_DIR/.backup-sign.XXXXXXXX")" || {
    log_error "Failed to create a private signing directory."
    return 1
  }
  chmod_mode 700 "$secure_dir" || {
    rm -rf -- "$secure_dir"
    return 1
  }
  secure_manifest="$secure_dir/manifest.v2"
  secure_sig="$secure_dir/manifest.v2.sig"
  unsorted="$secure_dir/entries.unsorted"

  if ! printf '%s\n' "${BACKUP_ENTRIES[@]}" >"$unsorted"; then
    log_error "Failed to write backup manifest entries to private storage."
    rm -rf -- "$secure_dir"
    return 1
  fi
  {
    printf 'SYSTEM-INIT-BACKUP-V2\t1\n'
    LC_ALL=C sort -t $'\t' -k1,1 -- "$unsorted"
  } >"$secure_manifest" || {
    log_error "Failed to build the canonical backup manifest."
    rm -rf -- "$secure_dir"
    return 1
  }
  rm -f -- "$unsorted"
  chmod_mode 600 "$secure_manifest" || {
    rm -rf -- "$secure_dir"
    return 1
  }

  produced="$(tail -n +2 -- "$secure_manifest" | grep -c . || true)"
  if [[ "$produced" != "$BACKUP_ENTRY_COUNT" ]]; then
    log_error "Backup manifest entry count mismatch (expected $BACKUP_ENTRY_COUNT, got ${produced:-0})."
    rm -rf -- "$secure_dir"
    return 1
  fi

  manifest_sha_before="$(file_sha256 "$secure_manifest" 2>/dev/null || true)"
  [[ "$manifest_sha_before" =~ ^[0-9a-f]{64}$ ]] || {
    log_error "Could not hash the trusted backup manifest."
    rm -rf -- "$secure_dir"
    return 1
  }

  if [[ -n "$BACKUP_SIGNING_KEY" ]]; then
    if ! backup_sign_manifest "$secure_manifest" "$secure_sig"; then
      log_error "Failed to sign the backup manifest; no published snapshot was changed."
      rm -rf -- "$secure_dir"
      return 1
    fi
    if ! backup_signature_verify "$secure_manifest" "$secure_sig"; then
      log_error "Refusing a manifest whose signature did not verify: ${BACKUP_SIGNATURE_ERROR:-unknown error}"
      rm -rf -- "$secure_dir"
      return 1
    fi
    manifest_sha_after="$(file_sha256 "$secure_manifest" 2>/dev/null || true)"
    if [[ "$manifest_sha_after" != "$manifest_sha_before" ]]; then
      log_error "Backup manifest changed during signing; refusing to publish."
      rm -rf -- "$secure_dir"
      return 1
    fi
  else
    rm -f -- "$secure_sig"
    if [[ "$BACKUP_WARNED_UNSIGNED" != "1" ]]; then
      log_warn "No BACKUP_SIGNING_KEY configured; backups are hashed but unsigned."
      BACKUP_WARNED_UNSIGNED=1
    fi
  fi

  BACKUP_SECURE_DIR="$secure_dir"
  BACKUP_SECURE_MANIFEST="$secure_manifest"
  BACKUP_SECURE_SIG="$secure_sig"
  BACKUP_SECURE_SHA="$manifest_sha_before"
  return 0
}

# Publish a previously built pair, preserving the previous valid pair if any
# step fails. A crash between the two moves leaves an invalid pair (signature
# does not match), which restore rejects.
backup_manifest_publish() {
  local run="$BACKUP_RUN_DIR"
  local secure_dir="$BACKUP_SECURE_DIR"
  local secure_manifest="$BACKUP_SECURE_MANIFEST"
  local secure_sig="$BACKUP_SECURE_SIG"
  local expected_sha="$BACKUP_SECURE_SHA"
  local old_manifest old_sig had_old=0 published_sha

  [[ -n "$run" && -n "$secure_dir" && -f "$secure_manifest" ]] || return 1
  if [[ -e "$run/manifest.v2" && ! -f "$run/manifest.v2" ]] || [[ -L "$run/manifest.v2" ]]; then
    log_error "Existing backup manifest is unsafe: $run/manifest.v2"
    rm -rf -- "$secure_dir"
    return 1
  fi
  if [[ -e "$run/manifest.v2.sig" && ! -f "$run/manifest.v2.sig" ]] || [[ -L "$run/manifest.v2.sig" ]]; then
    log_error "Existing backup signature is unsafe: $run/manifest.v2.sig"
    rm -rf -- "$secure_dir"
    return 1
  fi

  old_manifest="$secure_dir/old.manifest.v2"
  old_sig="$secure_dir/old.manifest.v2.sig"
  if [[ -f "$run/manifest.v2" ]]; then
    if ! cp -p -- "$run/manifest.v2" "$old_manifest"; then
      log_error "Could not preserve the previous backup manifest."
      rm -rf -- "$secure_dir"
      return 1
    fi
    had_old=1
  fi
  if [[ -f "$run/manifest.v2.sig" ]]; then
    if ! cp -p -- "$run/manifest.v2.sig" "$old_sig"; then
      log_error "Could not preserve the previous backup signature."
      rm -rf -- "$secure_dir"
      return 1
    fi
  fi

  if ! rm -f -- "$run/manifest.v2.sig"; then
    log_error "Could not remove the old backup signature."
    rm -rf -- "$secure_dir"
    return 1
  fi
  if ! mv_replace "$secure_manifest" "$run/manifest.v2"; then
    log_error "Failed to publish the canonical backup manifest."
    if (( had_old == 1 )); then
      cp -p -- "$old_manifest" "$run/manifest.v2" 2>/dev/null || true
      [[ -f "$old_sig" ]] && cp -p -- "$old_sig" "$run/manifest.v2.sig" 2>/dev/null || true
    fi
    rm -rf -- "$secure_dir"
    return 1
  fi
  if [[ -n "$BACKUP_SIGNING_KEY" ]]; then
    if ! mv_replace "$secure_sig" "$run/manifest.v2.sig"; then
      log_error "Failed to publish the backup signature."
      rm -f -- "$run/manifest.v2" "$run/manifest.v2.sig" 2>/dev/null || true
      if (( had_old == 1 )); then
        cp -p -- "$old_manifest" "$run/manifest.v2" 2>/dev/null || true
        [[ -f "$old_sig" ]] && cp -p -- "$old_sig" "$run/manifest.v2.sig" 2>/dev/null || true
      fi
      rm -rf -- "$secure_dir"
      return 1
    fi
  fi

  published_sha="$(file_sha256 "$run/manifest.v2" 2>/dev/null || true)"
  if [[ "$published_sha" != "$expected_sha" ]]; then
    log_error "Published backup manifest does not match the signed bytes."
    rm -f -- "$run/manifest.v2" "$run/manifest.v2.sig" 2>/dev/null || true
    if (( had_old == 1 )); then
      cp -p -- "$old_manifest" "$run/manifest.v2" 2>/dev/null || true
      [[ -f "$old_sig" ]] && cp -p -- "$old_sig" "$run/manifest.v2.sig" 2>/dev/null || true
    fi
    rm -rf -- "$secure_dir"
    return 1
  fi
  if [[ -n "$BACKUP_SIGNING_KEY" ]] && ! backup_signature_verify "$run/manifest.v2" "$run/manifest.v2.sig"; then
    log_error "Published backup signature did not verify: ${BACKUP_SIGNATURE_ERROR:-unknown error}"
    rm -f -- "$run/manifest.v2" "$run/manifest.v2.sig" 2>/dev/null || true
    if (( had_old == 1 )); then
      cp -p -- "$old_manifest" "$run/manifest.v2" 2>/dev/null || true
      [[ -f "$old_sig" ]] && cp -p -- "$old_sig" "$run/manifest.v2.sig" 2>/dev/null || true
    fi
    rm -rf -- "$secure_dir"
    return 1
  fi

  BACKUP_SECURE_DIR=""
  BACKUP_SECURE_MANIFEST=""
  BACKUP_SECURE_SIG=""
  BACKUP_SECURE_SHA=""
  rm -rf -- "$secure_dir"
  return 0
}

# Backward-compatible build+publish helper used by tests and any library caller
# that explicitly wants to refresh a published manifest without finalization.
backup_manifest_rebuild() {
  backup_manifest_build || return 1
  backup_manifest_publish
}

backup_snapshot_has_entries() {
  local snapshot="${1:-}"
  local count=0

  [[ -n "$snapshot" ]] || return 1
  if [[ -f "$snapshot/manifest.v2" && ! -L "$snapshot/manifest.v2" ]]; then
    count="$(tail -n +2 -- "$snapshot/manifest.v2" | grep -c . || true)"
  elif [[ -f "$snapshot/manifest.tsv" && ! -L "$snapshot/manifest.tsv" ]]; then
    count="$(grep -v '^#' -- "$snapshot/manifest.tsv" 2>/dev/null | grep -c . || true)"
  else
    return 1
  fi
  [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 ))
}

# Absent complete= means "complete" for compatibility with snapshots created
# before this field existed. Any explicit non-1 value is treated as incomplete.
backup_snapshot_complete() {
  local snapshot="${1:-}"
  local metadata="$snapshot/metadata.conf"
  local complete=""

  [[ -f "$metadata" && ! -L "$metadata" && -r "$metadata" ]] || return 1
  complete="$(awk -F= '$1 == "complete" { print $2; exit }' "$metadata" 2>/dev/null || true)"
  [[ -z "$complete" || "$complete" == "1" ]]
}

# Remove a snapshot that never received a valid entry. Used for empty or
# aborted manual backups so an empty snapshot cannot become "latest".
backup_discard_snapshot() {
  local run="${1:-${BACKUP_RUN_DIR:-}}"
  local backup_root

  [[ -n "$run" ]] || return 0
  backup_root="$(path_canonicalize "$BACKUP_DIR" 2>/dev/null)" || return 1
  [[ "$(dirname -- "$run")" == "$backup_root" && ! -L "$run" ]] || return 1
  if safe_rm_rf "$run"; then
    BACKUP_RUN_DIR=""
    BACKUP_ENTRIES=()
    BACKUP_ENTRY_COUNT=0
    BACKUP_SOURCE_PATHS=()
    BACKUP_SNAPSHOT_COMPLETE=0
    return 0
  fi
  return 1
}

backup_snapshot_mark_incomplete() {
  local run="${1:-${BACKUP_RUN_DIR:-}}"
  local metadata tmp created reason host user

  [[ -n "$run" ]] || return 1
  BACKUP_SNAPSHOT_COMPLETE=0
  metadata="$run/metadata.conf"
  created="$(awk -F= '$1 == "created" { print $2; exit }' "$metadata" 2>/dev/null || true)"
  reason="$(awk -F= '$1 == "reason" { print $2; exit }' "$metadata" 2>/dev/null || true)"
  host="$(awk -F= '$1 == "host" { print $2; exit }' "$metadata" 2>/dev/null || true)"
  user="$(awk -F= '$1 == "user" { print $2; exit }' "$metadata" 2>/dev/null || true)"
  tmp="$(mktemp "$run/.metadata.XXXXXXXX")" || return 1
  if ! {
    printf 'created=%s\nreason=%s\nhost=%s\nuser=%s\ncomplete=0\n' \
      "${created:-unknown}" "${reason:-unknown}" "${host:-unknown}" "${user:-unknown}" >"$tmp"
  }; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod_mode 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv_replace "$tmp" "$metadata" || { rm -f -- "$tmp"; return 1; }
}

backup_snapshot_mark_complete() {
  local run="${1:-${BACKUP_RUN_DIR:-}}"
  local metadata tmp created reason host user

  [[ -n "$run" ]] || return 1
  metadata="$run/metadata.conf"
  created="$(awk -F= '$1 == "created" { print $2; exit }' "$metadata" 2>/dev/null || true)"
  reason="$(awk -F= '$1 == "reason" { print $2; exit }' "$metadata" 2>/dev/null || true)"
  host="$(awk -F= '$1 == "host" { print $2; exit }' "$metadata" 2>/dev/null || true)"
  user="$(awk -F= '$1 == "user" { print $2; exit }' "$metadata" 2>/dev/null || true)"
  tmp="$(mktemp "$run/.metadata.XXXXXXXX")" || return 1
  if ! {
    printf 'created=%s\nreason=%s\nhost=%s\nuser=%s\ncomplete=1\n' \
      "${created:-unknown}" "${reason:-unknown}" "${host:-unknown}" "${user:-unknown}" >"$tmp"
  }; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod_mode 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv_replace "$tmp" "$metadata" || { rm -f -- "$tmp"; return 1; }
  BACKUP_SNAPSHOT_COMPLETE=1
}

# Verify the complete published snapshot (structure, signature if configured,
# and every payload hash) before marking it complete. This deliberately runs
# without mutating the home directory.
backup_finalize() {
  local run="${BACKUP_RUN_DIR:-}"
  local dest type size sha mode payload kind
  local was_complete=0

  [[ -n "$run" ]] || return 0
  [[ "$BACKUP_SNAPSHOT_COMPLETE" == "1" ]] && was_complete=1

  if (( BACKUP_ENTRY_COUNT == 0 )); then
    log_error "Refusing to finalize an empty backup snapshot."
    backup_snapshot_mark_incomplete "$run" || true
    return 1
  fi

  # Build and sign in private storage first. Never disturb an existing valid
  # manifest/signature pair unless the new pair was fully built and verified.
  if ! backup_manifest_build; then
    if (( was_complete == 0 )); then
      backup_snapshot_mark_incomplete "$run" || true
    fi
    return 1
  fi

  if ! backup_v2_manifest_parse_file "$BACKUP_SECURE_MANIFEST" >/dev/null 2>&1; then
    log_error "Backup manifest structure is invalid."
    rm -rf -- "$BACKUP_SECURE_DIR"
    BACKUP_SECURE_DIR=""
    if (( was_complete == 0 )); then
      backup_snapshot_mark_incomplete "$run" || true
    fi
    return 1
  fi

  # Verify every payload before publishing. This is the key ordering property:
  # a signed manifest is never published with a missing or invalid payload.
  while IFS=$'\t' read -r dest type size sha mode payload kind; do
    if ! backup_v2_entry_verify "$run/$payload" "$type" "$size" "$sha"; then
      log_error "Backup payload verification failed for $dest."
      rm -rf -- "$BACKUP_SECURE_DIR"
      BACKUP_SECURE_DIR=""
      if (( was_complete == 0 )); then
        backup_snapshot_mark_incomplete "$run" || true
      fi
      return 1
    fi
  done < <(backup_v2_manifest_parse_file "$BACKUP_SECURE_MANIFEST")

  # Mark complete before publishing so a crash after publication cannot leave
  # a valid manifest with an incomplete marker. A crash before publication
  # leaves either the old valid pair or no manifest at all.
  if ! backup_snapshot_mark_complete "$run"; then
    log_error "Failed to mark the backup snapshot complete."
    rm -rf -- "$BACKUP_SECURE_DIR"
    BACKUP_SECURE_DIR=""
    return 1
  fi

  if ! backup_manifest_publish; then
    log_error "Backup publication failed; previous published state was preserved where possible."
    if (( was_complete == 0 )); then
      backup_snapshot_mark_incomplete "$run" || true
    fi
    return 1
  fi

  log_info "Backup snapshot verified and complete: $run"
}

backup_init() {
  local reason="${1:-manual}"
  local timestamp candidate suffix=1

  if [[ -n "$BACKUP_RUN_DIR" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "would create backup snapshot for: $reason"
    return 0
  fi

  state_lock_acquire "operation" || return 1
  init_private_dir "$BACKUP_DIR" || return 1
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  candidate="$BACKUP_DIR/$timestamp"
  while true; do
    if create_private_dir_exclusive "$candidate"; then
      break
    fi
    if [[ -e "$candidate" || -L "$candidate" ]]; then
      suffix=$((suffix + 1))
      candidate="$BACKUP_DIR/$timestamp-$suffix"
      continue
    fi
    log_error "Failed to create a private backup snapshot directory: $candidate"
    return 1
  done

  init_private_dir "$candidate/files" || return 1
  if ! printf 'created=%s\nreason=%s\nhost=%s\nuser=%s\ncomplete=0\n' \
    "$timestamp" "$reason" "$(hostname)" "$TARGET_USER" | write_private_file "$candidate/metadata.conf"; then
    rm -rf -- "$candidate"
    return 1
  fi
  if ! printf '' | write_private_file "$candidate/manifest.tsv"; then
    rm -rf -- "$candidate"
    return 1
  fi

  BACKUP_RUN_DIR="$candidate"
  BACKUP_ENTRIES=()
  BACKUP_ENTRY_COUNT=0
  BACKUP_SNAPSHOT_COMPLETE=0
  BACKUP_SOURCE_PATHS=()
  log_info "Backup snapshot: $BACKUP_RUN_DIR"
}

# Remove the most recent in-memory/manifest.tsv entry and its staged payload
# after a post-finalization backup failed to publish. This keeps a previously
# valid snapshot usable and prevents a later duplicate check from treating an
# unpublished payload as backed up.
backup_rollback_pending_entry() {
  local source_path="$1"
  local destination="$2"
  local previous_count="$3"
  local previous_manifest_size="$4"
  local tmp

  if (( BACKUP_ENTRY_COUNT != previous_count + 1 )); then
    return 1
  fi
  BACKUP_ENTRY_COUNT="$previous_count"
  unset "BACKUP_ENTRIES[$(( ${#BACKUP_ENTRIES[@]} - 1 ))]"
  unset "BACKUP_SOURCE_PATHS[$source_path]"
  rm -f -- "$destination" 2>/dev/null || true
  if [[ -f "$BACKUP_RUN_DIR/manifest.tsv" && "$previous_manifest_size" =~ ^[0-9]+$ ]]; then
    if have_command truncate; then
      truncate -s "$previous_manifest_size" -- "$BACKUP_RUN_DIR/manifest.tsv" 2>/dev/null || true
    else
      tmp="$(mktemp "$BACKUP_RUN_DIR/.manifest-rollback.XXXXXXXX")" || return 1
      if head -c "$previous_manifest_size" -- "$BACKUP_RUN_DIR/manifest.tsv" >"$tmp"; then
        mv_replace "$tmp" "$BACKUP_RUN_DIR/manifest.tsv"
      else
        rm -f -- "$tmp"
      fi
    fi
  fi
  return 0
}

backup_path() {
  local source_path="$1"
  local kind="${2:-file}"
  local reason="${3:-conflict}"

  if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then
    log_debug "Nothing to back up at $source_path"
    return 0
  fi

  if ! path_is_under "$source_path" "$TARGET_HOME"; then
    log_error "Refusing to back up a path outside \$HOME: $source_path"
    return 1
  fi
  if [[ -d "$source_path" && ! -L "$source_path" ]]; then
    log_error "Refusing to back up a directory: $source_path"
    return 1
  fi

  local target_rel="${source_path#"$TARGET_HOME"/}"
  if [[ -z "$target_rel" || "$target_rel" == "$source_path" ]] \
    || ! dotfiles_restore_target_is_safe "$target_rel"; then
    log_error "Refusing to back up an unapproved destination: $source_path"
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "back up $(log_cmd "$source_path") to a new snapshot"
    return 0
  fi

  backup_init "$reason" || return 1

  # New snapshots use the portable v2 layout files/<home-relative path>.
  # Legacy v1 snapshots may use files/<absolute path>; both are accepted by
  # the v1 restore validator.
  local destination="$BACKUP_RUN_DIR/files/$target_rel"
  local manifest="$BACKUP_RUN_DIR/manifest.tsv"
  local entry was_complete=0 previous_count previous_manifest_size
  [[ "$BACKUP_SNAPSHOT_COMPLETE" == "1" ]] && was_complete=1
  previous_count="$BACKUP_ENTRY_COUNT"
  previous_manifest_size="$(file_size "$manifest" 2>/dev/null || printf '0')"

  if [[ -n "${BACKUP_SOURCE_PATHS[$source_path]:-}" ]]; then
    local existing_destination
    existing_destination="$(awk -F'\t' -v p="$source_path" '$1 == p { print $2; exit }' "$manifest" 2>/dev/null || true)"
    if [[ -z "$existing_destination" || ( ! -e "$existing_destination" && ! -L "$existing_destination" ) ]]; then
      log_error "Previously backed-up destination is missing for: $source_path"
      return 1
    fi
    if [[ -L "$source_path" ]]; then
      if [[ -L "$existing_destination" ]] \
        && [[ "$(readlink -- "$source_path" 2>/dev/null)" == "$(readlink -- "$existing_destination" 2>/dev/null)" ]]; then
        log_debug "Path already backed up in this snapshot: $source_path"
        return 0
      fi
    elif [[ -f "$source_path" && -f "$existing_destination" && ! -L "$existing_destination" ]] \
      && cmp -s -- "$source_path" "$existing_destination"; then
      log_debug "Path already backed up in this snapshot: $source_path"
      return 0
    fi
    log_error "Source changed after it was backed up; refusing to overwrite: $source_path"
    return 1
  fi

  # Snapshot payload paths are staged under a 0700 directory, but a same-UID
  # process (or shared backup filesystem) could plant a symlinked component.
  # Never write or hash through such a link.
  if [[ -L "$BACKUP_RUN_DIR/files" ]] \
    || path_has_symlink_component "$(dirname -- "$destination")" "$BACKUP_RUN_DIR/files"; then
    log_error "Refusing to back up through a symlinked snapshot payload parent: $destination"
    return 1
  fi
  local old_umask
  old_umask="$(umask)"
  umask 077
  mkdir -p -- "$(dirname -- "$destination")"
  local mkdir_rc=$?
  umask "$old_umask"
  (( mkdir_rc == 0 )) || return 1
  if [[ -L "$BACKUP_RUN_DIR/files" ]] \
    || path_has_symlink_component "$(dirname -- "$destination")" "$BACKUP_RUN_DIR/files"; then
    log_error "Refusing to back up through a symlinked snapshot payload parent: $destination"
    return 1
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    log_error "Backup payload destination already exists: $destination"
    return 1
  fi
  if ! cp -a "$source_path" "$destination"; then
    log_error "Failed to back up $source_path"
    return 1
  fi

  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    log_error "Backup verification failed for $source_path"
    return 1
  fi

  local v2_type v2_size v2_sha v2_mode v2_payload v2_target
  if [[ -L "$destination" ]]; then
    v2_type="symlink"
    v2_target="$(readlink -- "$destination" 2>/dev/null)" || {
      log_error "Could not read the backed-up symlink: $source_path"
      return 1
    }
    v2_size="$(printf '%s' "$v2_target" | LC_ALL=C wc -c | tr -d '[:space:]')"
    v2_sha="$(string_sha256 "$v2_target")"
    v2_mode="0777"
  elif [[ -f "$destination" ]]; then
    v2_type="file"
    v2_size="$(file_size "$destination" 2>/dev/null)" || {
      log_error "Could not read the backed-up file size: $source_path"
      return 1
    }
    v2_sha="$(file_sha256 "$destination" 2>/dev/null || true)"
    v2_mode="$(backup_normalized_mode "$destination")"
  else
    log_error "Unsupported backup payload type: $source_path"
    return 1
  fi
  if [[ ! "$v2_size" =~ ^[0-9]+$ || ! "$v2_sha" =~ ^[0-9a-f]{64}$ ]]; then
    log_error "Could not hash the backup payload: $source_path"
    return 1
  fi

  v2_payload="files/$target_rel"
  entry="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$target_rel" "$v2_type" "$v2_size" "$v2_sha" "$v2_mode" "$v2_payload" "${kind:--}")"
  if [[ -z "$entry" ]]; then
    log_error "Could not construct a backup manifest entry: $source_path"
    return 1
  fi
  BACKUP_ENTRIES+=("$entry")
  BACKUP_ENTRY_COUNT=$((BACKUP_ENTRY_COUNT + 1))
  BACKUP_SOURCE_PATHS["$source_path"]=1
  if ! printf '%s\t%s\t%s\n' "$source_path" "$destination" "$kind" >>"$manifest"; then
    log_error "Failed to append to the legacy backup manifest: $source_path"
    BACKUP_ENTRY_COUNT=$((BACKUP_ENTRY_COUNT - 1))
    unset "BACKUP_ENTRIES[$(( ${#BACKUP_ENTRIES[@]} - 1 ))]"
    unset "BACKUP_SOURCE_PATHS[$source_path]"
    backup_snapshot_mark_incomplete || true
    return 1
  fi

  # Do not publish manifest.v2 during accumulation. A crash or later failure
  # must leave the snapshot without an authenticated manifest, which is
  # unambiguously invalid. backup_finalize publishes it once, after all paths
  # have been accumulated.
  if (( was_complete == 1 )); then
    # The install flow can encounter a new conflict after the pre-install
    # snapshot was finalized. Persist and verify the new entry immediately;
    # otherwise the caller could replace a target that was never actually
    # captured in the signed manifest.
    if ! backup_finalize; then
      if (( was_complete == 1 )); then
        backup_rollback_pending_entry "$source_path" "$destination" \
          "$previous_count" "$previous_manifest_size" || true
        BACKUP_SNAPSHOT_COMPLETE=1
      else
        backup_snapshot_mark_incomplete || true
      fi
      return 1
    fi
  fi
  log_debug "Backed up $source_path -> $destination"
}

backup_latest() {
  local candidate resolved
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    resolved="$(backup_snapshot_path "$candidate" 2>/dev/null)" || continue
    backup_snapshot_has_entries "$resolved" || continue
    case "$(backup_snapshot_status "$resolved")" in
      signed|unsigned-v2|legacy-unverified) ;;
      *) continue ;;
    esac
    printf '%s\n' "$resolved"
    return 0
  done < <(list_backup_runs)
  return 0
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

  if (( BACKUP_ENTRY_COUNT > 0 )); then
    backup_finalize || return 1
  fi
  log_debug "Processed $count dotfile target(s) requiring backup."
}

backup_snapshot_path() {
  local snapshot="${1:-}"
  local backup_root resolved

  [[ -n "$snapshot" && "$snapshot" != *..* ]] || return 1
  [[ ! -L "$BACKUP_DIR" ]] || return 1

  backup_root="$(path_canonicalize "$BACKUP_DIR" 2>/dev/null)" || return 1
  resolved="$(path_canonicalize "$snapshot" 2>/dev/null)" || return 1

  [[ "$resolved" == "$backup_root"/* ]] || return 1
  [[ "$(dirname -- "$resolved")" == "$backup_root" ]] || return 1
  [[ ! -L "$snapshot" ]] || return 1
  [[ -d "$resolved" && ! -L "$resolved" ]] || return 1
  [[ -d "$resolved/files" && ! -L "$resolved/files" ]] || return 1

  # v2 is authoritative when any v2 artifact exists. A stray signature without
  # a manifest is invalid, never a reason to fall back to v1.
  if [[ -e "$resolved/manifest.v2" || -L "$resolved/manifest.v2" \
    || -e "$resolved/manifest.v2.sig" || -L "$resolved/manifest.v2.sig" ]]; then
    [[ -f "$resolved/manifest.v2" && ! -L "$resolved/manifest.v2" ]] || return 1
    if [[ -e "$resolved/manifest.v2.sig" || -L "$resolved/manifest.v2.sig" ]]; then
      [[ -f "$resolved/manifest.v2.sig" && ! -L "$resolved/manifest.v2.sig" ]] || return 1
    fi
  elif [[ -f "$resolved/manifest.tsv" && ! -L "$resolved/manifest.tsv" ]]; then
    :
  else
    return 1
  fi
  backup_snapshot_complete "$resolved" || return 1

  printf '%s\n' "$resolved"
}

backup_snapshot_exists() {
  backup_snapshot_path "$1" >/dev/null 2>&1
}

backup_manifest_targets() {
  local snapshot
  snapshot="$(backup_snapshot_path "$1")" || return 1
  if [[ -f "$snapshot/manifest.v2" ]]; then
    tail -n +2 -- "$snapshot/manifest.v2" | cut -f1
  else
    cut -f1 -- "$snapshot/manifest.tsv"
  fi
}

# Strip terminal control characters from snapshot-controlled text before it is
# displayed. Snapshot metadata is untrusted input.
backup_sanitize_text() {
  printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177\200-\237'
}

backup_print_metadata() {
  local snapshot="$1"
  local metadata="$snapshot/metadata.conf"
  local key value

  [[ -f "$metadata" && ! -L "$metadata" ]] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      created|reason|host|user)
        printf '  %s=%s\n' "$key" "$(backup_sanitize_text "$value")"
        ;;
    esac
  done <"$metadata"
}

# Validate a payload symlink by resolving existing link components. Unlike a
# lexical check, this follows chains such as $HOME/link -> /etc and rejects
# them. Directory payloads are rejected, so no recursive tree walk is needed.
backup_payload_symlink_safe() {
  local stored="$1"
  local home_root="$2"
  local repo_root="$3"
  local dest_parent="${4:-}"
  local target resolved

  [[ -L "$stored" ]] || return 0

  target="$(readlink -- "$stored" 2>/dev/null)" || return 1
  [[ -n "$target" ]] || return 1

  if [[ "$target" == /* ]]; then
    resolved="$(path_resolve "$target" 2>/dev/null)" || return 1
  else
    # A relative link is interpreted where it will be installed, not inside
    # the snapshot.
    resolved="$(path_resolve "${dest_parent:-$(dirname -- "$stored")}/$target" 2>/dev/null)" || return 1
  fi

  [[ "$resolved" == "$home_root"/* || "$resolved" == "$repo_root"/* ]]
}

backup_manifest_path_valid() {
  local path="${1:-}"
  [[ -n "$path" && "$path" == /* ]] || return 1
  [[ ! "$path" =~ [[:cntrl:]] ]] || return 1
  return 0
}

# Strict v2 fields: no control characters, tabs or empty values. The manifest
# is signed as bytes, so there is no escaping layer that could be ambiguous.
backup_v2_field_safe() {
  local value="${1:-}"
  [[ -n "$value" ]] || return 1
  [[ ! "$value" =~ [[:cntrl:]] ]] || return 1
  return 0
}

# Validate a canonical v2 manifest file and print its entries. The first line
# is a fixed version header; entries are strictly sorted by destination and
# each destination may appear only once.
backup_v2_manifest_parse_file() {
  local manifest="${1:-}"
  local header dest type size sha mode payload kind previous=""
  local LC_ALL=C

  [[ -n "$manifest" && "$manifest" == /* && -f "$manifest" && ! -L "$manifest" ]] || return 1
  {
    IFS= read -r header || return 1
    [[ "$header" == $'SYSTEM-INIT-BACKUP-V2\t1' ]] || return 1

    while IFS=$'\t' read -r dest type size sha mode payload kind \
      || [[ -n "${dest:-}" ]]; do
      [[ -n "${dest:-}" ]] || return 1
      backup_v2_field_safe "$dest" || return 1
      backup_v2_field_safe "$type" || return 1
      backup_v2_field_safe "$size" || return 1
      backup_v2_field_safe "$sha" || return 1
      backup_v2_field_safe "$mode" || return 1
      backup_v2_field_safe "$payload" || return 1
      backup_v2_field_safe "$kind" || return 1
      [[ "$dest" != /* && "$dest" != *..* && "$dest" != "." && "$dest" != "./" ]] || return 1
      dotfiles_restore_target_is_safe "$dest" || return 1

      case "$type" in
        file|symlink) ;;
        *) return 1 ;;
      esac
      [[ "$size" =~ ^[0-9]+$ ]] || return 1
      [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
      case "$type:$mode" in
        file:0600|symlink:0777) ;;
        *) return 1 ;;
      esac
      [[ "$payload" == "files/$dest" ]] || return 1
      [[ "$kind" == "-" || "$kind" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
      if [[ -n "$previous" && ! "$dest" > "$previous" ]]; then
        return 1
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$dest" "$type" "$size" "$sha" "$mode" "$payload" "$kind"
      previous="$dest"
    done
  } <"$manifest"
}

backup_v2_manifest_parse() {
  local snapshot="${1:-}"
  [[ -n "$snapshot" ]] || return 1
  backup_v2_manifest_parse_file "$snapshot/manifest.v2"
}

backup_v2_manifest_validate() {
  backup_v2_manifest_parse "$1" >/dev/null
}

# Verify a payload against a v2 entry. Used before any mutation and again on
# the staged copy, so a payload swapped after validation is still rejected.
backup_v2_entry_verify() {
  local file="$1"
  local type="$2"
  local expected_size="$3"
  local expected_sha="$4"
  local actual_size actual_sha target

  case "$type" in
    file)
      [[ -f "$file" && ! -L "$file" ]] || return 1
      actual_size="$(file_size "$file" 2>/dev/null)" || return 1
      [[ "$actual_size" == "$expected_size" ]] || return 1
      actual_sha="$(file_sha256 "$file" 2>/dev/null || true)"
      [[ "$actual_sha" == "$expected_sha" ]]
      ;;
    symlink)
      [[ -L "$file" ]] || return 1
      target="$(readlink -- "$file" 2>/dev/null)" || return 1
      actual_size="$(printf '%s' "$target" | LC_ALL=C wc -c | tr -d '[:space:]')"
      [[ "$actual_size" == "$expected_size" ]] || return 1
      actual_sha="$(string_sha256 "$target")"
      [[ "$actual_sha" == "$expected_sha" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

backup_v2_payloads_verify() {
  local snapshot="${1:-}"
  local dest type size sha mode payload kind

  [[ -n "$snapshot" ]] || return 1
  backup_v2_manifest_validate "$snapshot" >/dev/null 2>&1 || return 1
  while IFS=$'\t' read -r dest type size sha mode payload kind; do
    backup_v2_entry_verify "$snapshot/$payload" "$type" "$size" "$sha" || return 1
  done < <(backup_v2_manifest_parse "$snapshot")
}

# Human-readable trust state for restore --list. "signed" means the signature
# and every payload hash were checked; signature validity alone is not enough.
backup_snapshot_status() {
  local snapshot
  snapshot="$(backup_snapshot_path "$1")" || {
    printf 'invalid\n'
    return 0
  }

  if [[ -f "$snapshot/manifest.v2" ]]; then
    if ! backup_v2_manifest_validate "$snapshot" >/dev/null 2>&1; then
      printf 'invalid-v2\n'
    elif ! backup_snapshot_has_entries "$snapshot"; then
      printf 'empty-v2\n'
    elif [[ ! -f "$snapshot/manifest.v2.sig" ]]; then
      if backup_v2_payloads_verify "$snapshot"; then
        printf 'unsigned-v2\n'
      else
        printf 'invalid-payload\n'
      fi
    elif ! backup_signing_key_valid "$BACKUP_SIGNING_KEY" || ! have_command gpg; then
      printf 'unverified-v2\n'
    elif ! backup_signature_verify "$snapshot/manifest.v2" "$snapshot/manifest.v2.sig"; then
      printf 'invalid-signature\n'
    elif backup_v2_payloads_verify "$snapshot"; then
      printf 'signed\n'
    else
      printf 'invalid-payload\n'
    fi
  elif backup_snapshot_has_entries "$snapshot"; then
    printf 'legacy-unverified\n'
  else
    printf 'legacy-empty\n'
  fi
}

backup_journal_begin() {
  if [[ "$DRY_RUN" == "1" ]]; then
    RESTORE_JOURNAL=""
    return 0
  fi
  init_private_dir "$STATE_DIR" || return 1
  init_private_dir "$JOURNAL_DIR" || return 1
  RESTORE_JOURNAL="$(mktemp "$JOURNAL_DIR/restore-XXXXXXXX.journal")" || {
    log_error "Could not create a private restore journal."
    return 1
  }
  chmod_mode 600 "$RESTORE_JOURNAL" || {
    rm -f -- "$RESTORE_JOURNAL"
    RESTORE_JOURNAL=""
    return 1
  }
}

backup_journal_write() {
  local status="$1"
  local dest="$2"
  local stage="$3"
  local had_old="$4"

  [[ -n "$RESTORE_JOURNAL" ]] || return 0
  printf '%s\t%s\t%s\t%s\n' "$status" "$dest" "$stage" "$had_old" \
    >>"$RESTORE_JOURNAL" || return 1
  # Keep the recovery record durable across a crash. If the filesystem does
  # not support sync -f, fall back to a global sync and fail if that fails too.
  if ! sync -f -- "$RESTORE_JOURNAL" 2>/dev/null; then
    sync 2>/dev/null || return 1
  fi
}

backup_journal_remove() {
  [[ -n "$RESTORE_JOURNAL" ]] || return 0
  if ! rm -f -- "$RESTORE_JOURNAL"; then
    log_error "Could not remove the completed restore journal: $RESTORE_JOURNAL"
    return 1
  fi
  RESTORE_JOURNAL=""
}

# Validate one manifest row and populate the BACKUP_ENTRY_* values. This is
# the single place that decides whether a restore destination is acceptable.
backup_restore_entry_validate() {
  local original="$1"
  local stored="$2"
  local files_root="$3"
  local home_raw="$4"
  local home_canon="$5"
  local repo_root="$6"
  local layout="${7:-v1}"
  local original_lex stored_lex target_rel expected_stored
  local parent_lex parent_root parent_canon dest

  BACKUP_ENTRY_DEST=""
  BACKUP_ENTRY_STORED=""

  backup_manifest_path_valid "$original" || {
    log_error "Backup manifest destination is not a safe absolute path: ${original:-<empty>}"
    return 1
  }
  backup_manifest_path_valid "$stored" || {
    log_error "Backup manifest payload is not a safe absolute path: ${stored:-<empty>}"
    return 1
  }

  original_lex="$(path_lexical "$original" 2>/dev/null)" || {
    log_error "Could not normalise restore destination: $original"
    return 1
  }
  stored_lex="$(path_lexical "$stored" 2>/dev/null)" || {
    log_error "Could not normalise backup payload: $stored"
    return 1
  }

  if [[ "$original_lex" == "$home_raw"/* ]]; then
    target_rel="${original_lex#"$home_raw"/}"
  elif [[ "$original_lex" == "$home_canon"/* ]]; then
    target_rel="${original_lex#"$home_canon"/}"
  else
    log_error "Refusing to restore outside \$HOME: $original"
    return 1
  fi

  if ! dotfiles_restore_target_is_safe "$target_rel"; then
    log_error "Refusing to restore an unapproved destination: $target_rel"
    return 1
  fi

  # v1 stores files<absolute path>; v2 stores files/<home-relative path>.
  # Either way the payload must bind exactly to the approved destination.
  if [[ "$layout" == "v2" ]]; then
    expected_stored="$files_root/$target_rel"
    if [[ "$stored_lex" != "$expected_stored" ]]; then
      log_error "Backup payload does not match its manifest destination: $stored"
      return 1
    fi
  else
    if [[ "$stored_lex" != "$files_root/$target_rel" ]]; then
      expected_stored="$files_root$original_lex"
      if [[ "$stored_lex" != "$expected_stored" ]]; then
        expected_stored="$files_root$home_canon/$target_rel"
        if [[ "$stored_lex" != "$expected_stored" ]]; then
          expected_stored="$files_root$home_raw/$target_rel"
          if [[ "$stored_lex" != "$expected_stored" ]]; then
            log_error "Backup payload does not match its manifest destination: $stored"
            return 1
          fi
        fi
      fi
    fi
  fi
  if [[ "$stored_lex" != "$files_root"/* ]]; then
    log_error "Refusing to restore a payload outside the snapshot: $stored"
    return 1
  fi
  if path_has_symlink_component "$(dirname -- "$stored_lex")" "$files_root"; then
    log_error "Refusing to restore through a symlinked payload parent: $stored"
    return 1
  fi

  # Resolve the destination's parent but not its leaf: a managed dotfile leaf
  # may legitimately be a symlink and must be replaced, not followed.
  if [[ "$original_lex" == "$home_raw"/* ]]; then
    parent_root="$home_raw"
  else
    parent_root="$home_canon"
  fi
  parent_lex="$(dirname -- "$original_lex")"
  [[ "$parent_lex" == "$parent_root" || "$parent_lex" == "$parent_root"/* ]] || {
    log_error "Refusing to restore outside \$HOME: $original"
    return 1
  }
  if path_has_symlink_component "$parent_lex" "$parent_root"; then
    log_error "Refusing to restore through a symlinked parent: $original"
    return 1
  fi
  parent_canon="$(path_resolve "$parent_lex" 2>/dev/null)" || {
    log_error "Could not resolve restore destination parent: $parent_lex"
    return 1
  }
  [[ "$parent_canon" == "$home_canon" || "$parent_canon" == "$home_canon"/* ]] || {
    log_error "Refusing to restore outside \$HOME: $original"
    return 1
  }

  dest="$parent_canon/$(basename -- "$original_lex")"
  [[ "$dest" != "$home_canon" ]] || {
    log_error "Refusing to replace TARGET_HOME itself: $original"
    return 1
  }
  if [[ -d "$dest" && ! -L "$dest" ]]; then
    log_error "Refusing to replace an existing directory: $dest"
    return 1
  fi

  if [[ -d "$stored_lex" && ! -L "$stored_lex" ]]; then
    log_error "Refusing to restore a directory payload: $stored"
    return 1
  fi
  if [[ -L "$stored_lex" ]]; then
    if ! backup_payload_symlink_safe "$stored_lex" "$home_canon" "$repo_root" "$parent_canon"; then
      log_error "Refusing to restore a symlink that escapes the allowed roots: $stored"
      return 1
    fi
  elif [[ ! -f "$stored_lex" ]]; then
    log_error "Backup payload is missing or unsupported: $stored"
    return 1
  fi

  BACKUP_ENTRY_DEST="$dest"
  BACKUP_ENTRY_STORED="$stored_lex"
  return 0
}

# Verify the installed destination against the signed manifest (v2) or the
# staged source (v1), including type, size, hash, and mode where applicable.
backup_restore_destination_verify() {
  local dest="$1"
  local stored="$2"
  local mode="${3:-}"
  local v2_type="${4:-}"
  local v2_size="${5:-}"
  local v2_sha="${6:-}"

  if [[ -n "$v2_sha" ]]; then
    backup_v2_entry_verify "$dest" "$v2_type" "$v2_size" "$v2_sha" || return 1
  elif [[ -L "$stored" ]]; then
    [[ -L "$dest" ]] || return 1
    [[ "$(readlink -- "$dest" 2>/dev/null)" == "$(readlink -- "$stored" 2>/dev/null)" ]] || return 1
  else
    [[ -f "$dest" && ! -L "$dest" ]] || return 1
    cmp -s -- "$stored" "$dest" || return 1
  fi

  if [[ -n "$mode" && "$v2_type" != "symlink" && ! -L "$dest" ]]; then
    [[ "$(file_mode "$dest" 2>/dev/null)" == "${mode#0}" ]] || return 1
  fi
  return 0
}

# Undo a just-installed entry, preserving untrusted staging data if any step
# fails. Returns 0 only when the old state is restored and journaled.
backup_restore_undo_installed() {
  local dest="$1"
  local stage="$2"
  local had_old="$3"
  local reason="$4"

  log_error "$reason"
  if [[ -e "$dest" || -L "$dest" ]]; then
    if ! rm -f -- "$dest"; then
      log_error "Could not remove the newly installed destination: $dest"
      backup_journal_write "ROLLBACK_REMOVE_FAILED" "$dest" "$stage" "$had_old" || true
      return 1
    fi
  fi
  if (( had_old == 1 )); then
    if ! mv_replace "$stage/old" "$dest"; then
      log_error "Could not restore the previous destination: $dest"
      backup_journal_write "ROLLBACK_RESTORE_FAILED" "$dest" "$stage" "$had_old" || true
      return 1
    fi
  fi
  if ! backup_journal_write "ROLLED_BACK_LOCAL" "$dest" "$stage" "$had_old"; then
    log_error "Installed state was rolled back, but the journal update failed."
    return 1
  fi
  safe_rm_rf "$stage" || log_warn "Could not remove restore staging area: $stage"
  return 0
}

# Apply one validated entry. The previous object is retained in the staging
# directory until the whole restore commits, so a later failure can roll back.
backup_restore_apply() {
  local dest="$1"
  local stored="$2"
  local home_root="$3"
  local mode="${4:-}"
  local v2_type="${5:-}"
  local v2_size="${6:-}"
  local v2_sha="${7:-}"
  local parent stage new old had_old=0

  [[ -n "$mode" ]] || mode="$(backup_normalized_mode "$stored")"

  parent="$(dirname -- "$dest")"
  if path_has_symlink_component "$parent" "$home_root"; then
    log_error "Refusing to restore through a symlinked parent: $parent"
    return 1
  fi
  mkdir -p -- "$parent" || return 1
  if path_has_symlink_component "$parent" "$home_root"; then
    log_error "Refusing to restore through a symlinked parent: $parent"
    return 1
  fi
  if [[ -d "$dest" && ! -L "$dest" ]]; then
    log_error "Refusing to replace an existing directory: $dest"
    return 1
  fi

  if [[ -L "$stored" ]]; then
    if ! backup_payload_symlink_safe "$stored" "$home_root" "$REPO_ROOT" "$parent"; then
      log_error "Refusing to restore a symlink that escapes the allowed roots: $stored"
      return 1
    fi
  elif [[ ! -f "$stored" ]]; then
    log_error "Backup payload is missing or unsupported: $stored"
    return 1
  fi

  stage="$(mktemp -d "$parent/.system-init-restore.XXXXXXXX")" || return 1
  new="$stage/new"
  old="$stage/old"

  # Copy without -a: ACLs and extended attributes from an untrusted snapshot
  # must not be applied to the user's home. The normalized mode is set below.
  if ! cp -P -- "$stored" "$new"; then
    log_error "Failed to stage backup payload: $stored"
    backup_journal_write "APPLY_FAILED" "$dest" "$stage" "0" || true
    safe_rm_rf "$stage"
    return 1
  fi

  if [[ -n "$v2_sha" ]]; then
    if ! backup_v2_entry_verify "$new" "$v2_type" "$v2_size" "$v2_sha"; then
      log_error "Staged copy does not match the signed backup manifest: $stored"
      backup_journal_write "APPLY_FAILED" "$dest" "$stage" "0" || true
      safe_rm_rf "$stage"
      return 1
    fi
  elif [[ -L "$stored" ]]; then
    if [[ ! -L "$new" || "$(readlink -- "$new" 2>/dev/null)" != "$(readlink -- "$stored" 2>/dev/null)" ]]; then
      log_error "Staged symlink does not match the backup payload: $stored"
      backup_journal_write "APPLY_FAILED" "$dest" "$stage" "0" || true
      safe_rm_rf "$stage"
      return 1
    fi
  elif ! cmp -s -- "$stored" "$new"; then
    log_error "Staged copy does not match the backup payload: $stored"
    backup_journal_write "APPLY_FAILED" "$dest" "$stage" "0" || true
    safe_rm_rf "$stage"
    return 1
  fi

  # Normalize and verify the mode on the staged inode before moving it into
  # place. This avoids chmod following a symlink planted at the destination.
  if [[ "$v2_type" != "symlink" && ! -L "$new" ]]; then
    if ! chmod_mode "$mode" "$new"; then
      log_error "Failed to set the staged file mode: $new"
      backup_journal_write "APPLY_FAILED" "$dest" "$stage" "0" || true
      safe_rm_rf "$stage"
      return 1
    fi
    if [[ "$(file_mode "$new" 2>/dev/null)" != "${mode#0}" ]]; then
      log_error "Staged file mode verification failed: $new"
      backup_journal_write "APPLY_FAILED" "$dest" "$stage" "0" || true
      safe_rm_rf "$stage"
      return 1
    fi
  fi

  if ! backup_journal_write "PREPARED" "$dest" "$stage" "0"; then
    log_error "Could not write the restore journal; refusing to move $dest."
    safe_rm_rf "$stage"
    return 1
  fi

  if [[ -e "$dest" || -L "$dest" ]]; then
    if ! backup_journal_write "MOVING_ASIDE" "$dest" "$stage" "0"; then
      log_error "Could not journal the destination move; refusing to move $dest."
      safe_rm_rf "$stage"
      return 1
    fi
    if ! mv_replace "$dest" "$old"; then
      log_error "Failed to move the existing destination aside: $dest"
      backup_journal_write "APPLY_FAILED" "$dest" "$stage" "0" || true
      safe_rm_rf "$stage"
      return 1
    fi
    had_old=1
    if ! backup_journal_write "MOVED_ASIDE" "$dest" "$stage" "$had_old"; then
      log_error "Could not journal the moved destination; restoring it."
      mv_replace "$old" "$dest" || log_error "Previous data remains at: $old"
      safe_rm_rf "$stage"
      return 1
    fi
  fi

  if ! mv_replace "$new" "$dest"; then
    log_error "Failed to install the restored payload: $dest"
    backup_journal_write "APPLY_FAILED" "$dest" "$stage" "$had_old" || true
    if (( had_old == 1 )); then
      if mv_replace "$old" "$dest"; then
        backup_journal_write "ROLLED_BACK_LOCAL" "$dest" "$stage" "$had_old" || true
      else
        log_error "Rollback also failed; previous data remains at: $old"
        backup_journal_write "ROLLBACK_FAILED" "$dest" "$stage" "$had_old" || true
        return 1
      fi
    fi
    safe_rm_rf "$stage"
    return 1
  fi

  if ! backup_journal_write "NEW_INSTALLED" "$dest" "$stage" "$had_old"; then
    backup_restore_undo_installed "$dest" "$stage" "$had_old" \
      "Could not journal the installed destination; rolling back $dest." || true
    return 1
  fi

  # The staged copy was verified, but it was then moved by pathname. Re-verify
  # the final destination before commit. This closes the post-staging swap
  # window for ordinary concurrent writers.
  if ! backup_restore_destination_verify "$dest" "$stored" "" "$v2_type" "$v2_size" "$v2_sha"; then
    backup_restore_undo_installed "$dest" "$stage" "$had_old" \
      "Installed destination failed verification: $dest" || true
    return 1
  fi

  if ! backup_restore_destination_verify "$dest" "$stored" "$mode" "$v2_type" "$v2_size" "$v2_sha"; then
    backup_restore_undo_installed "$dest" "$stage" "$had_old" \
      "Installed destination failed verification: $dest" || true
    return 1
  fi

  if ! backup_journal_write "APPLIED" "$dest" "$stage" "$had_old"; then
    backup_restore_undo_installed "$dest" "$stage" "$had_old" \
      "Could not journal the applied destination; rolling back $dest." || true
    return 1
  fi

  BACKUP_APPLIED_STAGE="$stage"
  BACKUP_APPLIED_HAD_OLD="$had_old"
  return 0
}

backup_restore_rollback() {
  local dest="$1"
  local stage="$2"
  local had_old="$3"

  if [[ -e "$dest" || -L "$dest" ]]; then
    # Restore only installs files and symlinks, so never recurse here. If the
    # destination unexpectedly became a directory, fail and preserve it.
    if ! rm -f -- "$dest"; then
      log_error "Rollback could not remove $dest; previous data remains at: $stage"
      backup_journal_write "ROLLBACK_REMOVE_FAILED" "$dest" "$stage" "$had_old" || true
      return 1
    fi
  fi
  if [[ "$had_old" == "1" ]]; then
    if ! mv_replace "$stage/old" "$dest"; then
      log_error "Rollback could not restore $dest; previous data remains at: $stage"
      backup_journal_write "ROLLBACK_RESTORE_FAILED" "$dest" "$stage" "$had_old" || true
      return 1
    fi
  fi
  if ! backup_journal_write "ROLLED_BACK" "$dest" "$stage" "$had_old"; then
    log_error "Rollback succeeded but the journal update failed for $dest."
    return 1
  fi
  safe_rm_rf "$stage" || log_warn "Could not remove restore staging area: $stage"
  return 0
}

backup_restore_commit() {
  local dest="$1"
  local stage="$2"
  local v2_type="${3:-}"
  local v2_size="${4:-}"
  local v2_sha="${5:-}"
  local v2_mode="${6:-}"

  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    log_error "Refusing to delete previous data for a missing destination: $dest"
    log_error "Previous data is preserved at: $stage/old"
    backup_journal_write "COMMIT_FAILED" "$dest" "$stage" "1" || true
    return 1
  fi
  if [[ -n "$v2_sha" ]]; then
    if ! backup_restore_destination_verify "$dest" "" "$v2_mode" "$v2_type" "$v2_size" "$v2_sha"; then
      log_error "Destination changed before commit: $dest"
      backup_journal_write "COMMIT_FAILED" "$dest" "$stage" "1" || true
      return 1
    fi
  fi
  if ! backup_journal_write "COMMIT_PENDING" "$dest" "$stage" "1"; then
    log_error "Could not journal the pending commit for $dest."
    return 1
  fi
  if ! safe_rm_rf "$stage"; then
    log_warn "Could not remove restore staging area: $stage"
    backup_journal_write "COMMIT_FAILED" "$dest" "$stage" "1" || true
    return 1
  fi
  if ! backup_journal_write "COMMITTED" "$dest" "$stage" "0"; then
    log_error "Commit completed but the journal update failed for $dest."
    return 1
  fi
  return 0
}

# Roll back applied entries in reverse order and aggregate every failure so the
# user gets the exact destination and staging path for each unresolved entry.
backup_restore_rollback_applied() {
  local dests_name="$1"
  local stages_name="$2"
  local olds_name="$3"
  local -n rollback_dests="$dests_name"
  local -n rollback_stages="$stages_name"
  local -n rollback_olds="$olds_name"
  local index failed=0
  local -a failures=()

  for (( index = ${#rollback_dests[@]} - 1; index >= 0; index-- )); do
    if ! backup_restore_rollback \
      "${rollback_dests[$index]}" "${rollback_stages[$index]}" "${rollback_olds[$index]}"; then
      failures+=("${rollback_dests[$index]} (previous data: ${rollback_stages[$index]}/old)")
      failed=1
    fi
  done

  # Apply-internal rollback failures are recorded in the journal but are not
  # in the applied array. Include them in the aggregate report.
  if [[ -n "$RESTORE_JOURNAL" && -f "$RESTORE_JOURNAL" ]]; then
    local status jdest jstage _ item existing found
    while IFS=$'\t' read -r status jdest jstage _ || [[ -n "${status:-}" ]]; do
      case "$status" in
        ROLLBACK_FAILED|ROLLBACK_REMOVE_FAILED|ROLLBACK_RESTORE_FAILED)
          item="$jdest (previous data: $jstage/old)"
          found=0
          for existing in "${failures[@]}"; do
            [[ "$existing" == "$item" ]] && found=1
          done
          if (( found == 0 )); then
            failures+=("$item")
          fi
          failed=1
          ;;
      esac
    done <"$RESTORE_JOURNAL"
  fi

  if (( failed == 1 )); then
    log_error "Rollback incomplete for ${#failures[@]} path(s):"
    local item
    for item in "${failures[@]}"; do
      log_error "  $item"
    done
  else
    log_info "Rollback completed for ${#rollback_dests[@]} applied path(s)."
  fi
  return "$failed"
}

backup_restore_v2_snapshot() {
  local snapshot_root="$1"
  local files_root="$2"
  local home_raw="$3"
  local home_canon="$4"
  local repo_root="$5"
  local manifest="$snapshot_root/manifest.v2"
  local signature="$snapshot_root/manifest.v2.sig"
  local verify_dir verify_manifest verify_sig plan manifest_sha_before manifest_sha_after
  local plan_count manifest_count dest type size sha mode payload kind original stored line
  local restored=0 rc=0 stage commit_failed=0
  local -a entries=()
  local -a applied_dest=() applied_stage=() applied_old=()
  local -a applied_type=() applied_size=() applied_sha=() applied_mode=()

  backup_snapshot_complete "$snapshot_root" || {
    log_error "Backup snapshot is marked incomplete; refusing to restore."
    return 1
  }
  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    log_error "Canonical v2 manifest is missing or unsafe: $manifest"
    return 1
  }

  # Verify and parse an immutable private copy. Never reopen the snapshot path
  # after signature verification: that was the original TOCTOU. Dry-run uses
  # a private temporary directory instead of creating or touching state.
  local verify_base="$STATE_DIR"
  if [[ "$DRY_RUN" == "1" ]]; then
    verify_base="${TMPDIR:-/tmp}"
    [[ "$verify_base" == /* && ! -L "$verify_base" ]] || {
      log_error "Unsafe temporary directory for dry-run verification."
      return 1
    }
  else
    init_private_dir "$STATE_DIR" || return 1
  fi
  verify_dir="$(mktemp -d "$verify_base/.restore-verify.XXXXXXXX")" || {
    log_error "Could not create a private restore verification directory."
    return 1
  }
  chmod_mode 700 "$verify_dir" || { rm -rf -- "$verify_dir"; return 1; }
  verify_manifest="$verify_dir/manifest.v2"
  verify_sig="$verify_dir/manifest.v2.sig"
  plan="$verify_dir/plan"
  if ! install_file 600 "$manifest" "$verify_manifest"; then
    log_error "Could not copy the manifest into protected verification storage."
    rm -rf -- "$verify_dir"
    return 1
  fi
  if [[ -e "$signature" || -L "$signature" ]]; then
    [[ -f "$signature" && ! -L "$signature" ]] || {
      log_error "Backup signature is missing or unsafe: $signature"
      rm -rf -- "$verify_dir"
      return 1
    }
    if ! install_file 600 "$signature" "$verify_sig"; then
      log_error "Could not copy the signature into protected verification storage."
      rm -rf -- "$verify_dir"
      return 1
    fi
    if ! backup_signing_key_valid "$BACKUP_SIGNING_KEY"; then
      log_error "No trusted signing key configured; set BACKUP_SIGNING_KEY to the signer's full fingerprint."
      rm -rf -- "$verify_dir"
      return 1
    fi
    if ! backup_signature_verify "$verify_manifest" "$verify_sig"; then
      log_error "Backup signature verification failed: ${BACKUP_SIGNATURE_ERROR:-unknown error}; refusing to restore."
      rm -rf -- "$verify_dir"
      return 1
    fi
  else
    if [[ "$RESTORE_ALLOW_UNSIGNED" != "1" ]]; then
      log_error "Snapshot is unsigned; use --allow-unsigned to accept hashes without a signature."
      rm -rf -- "$verify_dir"
      return 1
    fi
    log_warn "Restoring an unsigned v2 snapshot; hashes detect corruption, not tampering."
  fi

  manifest_sha_before="$(file_sha256 "$verify_manifest" 2>/dev/null || true)"
  [[ "$manifest_sha_before" =~ ^[0-9a-f]{64}$ ]] || {
    log_error "Could not hash the private manifest copy."
    rm -rf -- "$verify_dir"
    return 1
  }
  if ! backup_v2_manifest_parse_file "$verify_manifest" >"$plan"; then
    log_error "Canonical v2 manifest validation failed; refusing to restore."
    rm -rf -- "$verify_dir"
    return 1
  fi
  manifest_sha_after="$(file_sha256 "$verify_manifest" 2>/dev/null || true)"
  if [[ "$manifest_sha_after" != "$manifest_sha_before" ]]; then
    log_error "Private manifest copy changed during verification; refusing to restore."
    rm -rf -- "$verify_dir"
    return 1
  fi
  plan_count="$(grep -c . "$plan" 2>/dev/null || true)"
  manifest_count="$(tail -n +2 -- "$verify_manifest" | grep -c . || true)"
  if [[ ! "$plan_count" =~ ^[0-9]+$ ]] || (( plan_count == 0 )) \
    || [[ "$plan_count" != "$manifest_count" ]]; then
    log_error "Backup snapshot is empty or its manifest was not fully parsed; refusing to restore."
    rm -rf -- "$verify_dir"
    return 1
  fi

  # Phase 1: verify every destination and every payload hash before mutation.
  while IFS=$'\t' read -r dest type size sha mode payload kind; do
    original="$home_raw/$dest"
    stored="$snapshot_root/$payload"
    if ! backup_restore_entry_validate \
      "$original" "$stored" "$files_root" "$home_raw" "$home_canon" "$repo_root" v2; then
      rm -rf -- "$verify_dir"
      log_error "Restore aborted before any change: destination validation failed."
      return 1
    fi
    if ! backup_v2_entry_verify "$BACKUP_ENTRY_STORED" "$type" "$size" "$sha"; then
      rm -rf -- "$verify_dir"
      log_error "Restore aborted before any change: payload hash or size mismatch for $dest."
      return 1
    fi
    entries+=("$dest"$'\t'"$type"$'\t'"$size"$'\t'"$sha"$'\t'"$mode"$'\t'"$payload"$'\t'"$kind")
  done <"$plan"

  if [[ "$DRY_RUN" == "1" ]]; then
    for line in "${entries[@]}"; do
      IFS=$'\t' read -r dest type size sha mode payload kind <<<"$line"
      original="$home_raw/$dest"
      stored="$snapshot_root/$payload"
      if ! backup_restore_entry_validate \
        "$original" "$stored" "$files_root" "$home_raw" "$home_canon" "$repo_root" v2 \
        || ! backup_v2_entry_verify "$BACKUP_ENTRY_STORED" "$type" "$size" "$sha"; then
        rm -rf -- "$verify_dir"
        log_error "Dry-run validation failed after the initial manifest check for $dest."
        return 1
      fi
      log_dry "restore $(log_cmd "$BACKUP_ENTRY_STORED") -> $(log_cmd "$BACKUP_ENTRY_DEST")"
    done
    rm -rf -- "$verify_dir"
    return 0
  fi

  backup_journal_begin || {
    rm -rf -- "$verify_dir"
    log_error "Could not create a restore journal; refusing to mutate the home directory."
    return 1
  }

  # Phase 2: revalidate every entry and hash immediately before applying it.
  for line in "${entries[@]}"; do
    IFS=$'\t' read -r dest type size sha mode payload kind <<<"$line"
    original="$home_raw/$dest"
    stored="$snapshot_root/$payload"
    if ! backup_restore_entry_validate \
      "$original" "$stored" "$files_root" "$home_raw" "$home_canon" "$repo_root" v2 \
      || ! backup_v2_entry_verify "$BACKUP_ENTRY_STORED" "$type" "$size" "$sha"; then
      rc=1
      break
    fi
    if ! backup_restore_apply "$BACKUP_ENTRY_DEST" "$BACKUP_ENTRY_STORED" \
      "$home_canon" "$mode" "$type" "$size" "$sha"; then
      rc=1
      break
    fi
    applied_dest+=("$BACKUP_ENTRY_DEST")
    applied_stage+=("$BACKUP_APPLIED_STAGE")
    applied_old+=("$BACKUP_APPLIED_HAD_OLD")
    applied_type+=("$type")
    applied_size+=("$size")
    applied_sha+=("$sha")
    applied_mode+=("$mode")
    restored=$((restored + 1))
  done

  rm -rf -- "$verify_dir"

  if (( rc != 0 )); then
    log_error "Restore failed; rolling back $restored applied path(s)."
    backup_restore_rollback_applied applied_dest applied_stage applied_old || rc=2
    log_error "Recovery journal retained: $RESTORE_JOURNAL"
    return 1
  fi

  for (( stage = 0; stage < ${#applied_stage[@]}; stage++ )); do
    if ! backup_restore_commit "${applied_dest[$stage]}" "${applied_stage[$stage]}" \
      "${applied_type[$stage]}" "${applied_size[$stage]}" "${applied_sha[$stage]}" "${applied_mode[$stage]}"; then
      commit_failed=1
    fi
  done

  if (( commit_failed == 1 )); then
    log_error "Restore applied, but cleanup was incomplete. Recovery journal retained: $RESTORE_JOURNAL"
    return 1
  fi

  if ! backup_journal_remove; then
    log_error "Restore completed but the journal could not be removed."
    return 1
  fi
  log_success "Restore complete: $restored path(s) restored (v2)."
}

backup_restore_v1_snapshot() {
  local snapshot_root="$1"
  local files_root="$2"
  local home_raw="$3"
  local home_canon="$4"
  local repo_root="$5"
  local original stored kind line stage restored=0 rc=0 commit_failed=0 manifest_fd
  local -a entries=()
  local -a applied_dest=() applied_stage=() applied_old=()
  local -A seen_destinations=()

  backup_snapshot_complete "$snapshot_root" || {
    log_error "Backup snapshot is marked incomplete; refusing to restore."
    return 1
  }
  [[ -f "$snapshot_root/manifest.tsv" && ! -L "$snapshot_root/manifest.tsv" ]] || {
    log_error "Legacy backup manifest is missing or unsafe."
    return 1
  }
  exec {manifest_fd}<"$snapshot_root/manifest.tsv" || {
    log_error "Could not open the legacy backup manifest: $snapshot_root/manifest.tsv"
    return 1
  }
  while IFS=$'\t' read -r original stored kind || [[ -n "${original:-}" ]]; do
    [[ -z "${original:-}" ]] && continue
    [[ "$original" == \#* ]] && continue
    if ! backup_restore_entry_validate \
      "$original" "$stored" "$files_root" "$home_raw" "$home_canon" "$repo_root"; then
      exec {manifest_fd}<&-
      log_error "Restore aborted before any change: manifest validation failed."
      return 1
    fi
    if [[ -n "${seen_destinations[$BACKUP_ENTRY_DEST]:-}" ]]; then
      exec {manifest_fd}<&-
      log_error "Restore aborted: duplicate destination in manifest: $BACKUP_ENTRY_DEST"
      return 1
    fi
    seen_destinations["$BACKUP_ENTRY_DEST"]=1
    entries+=("$original"$'\t'"$stored")
  done <&"$manifest_fd"
  exec {manifest_fd}<&-
  if (( ${#entries[@]} == 0 )); then
    log_error "Legacy backup snapshot is empty; refusing to restore."
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    for line in "${entries[@]}"; do
      IFS=$'\t' read -r original stored <<<"$line"
      if backup_restore_entry_validate \
        "$original" "$stored" "$files_root" "$home_raw" "$home_canon" "$repo_root"; then
        log_dry "restore $(log_cmd "$BACKUP_ENTRY_STORED") -> $(log_cmd "$BACKUP_ENTRY_DEST")"
      fi
    done
    return 0
  fi

  backup_journal_begin || {
    log_error "Could not create a restore journal; refusing to mutate the home directory."
    return 1
  }

  for line in "${entries[@]}"; do
    IFS=$'\t' read -r original stored <<<"$line"
    if ! backup_restore_entry_validate \
      "$original" "$stored" "$files_root" "$home_raw" "$home_canon" "$repo_root"; then
      rc=1
      break
    fi
    if ! backup_restore_apply "$BACKUP_ENTRY_DEST" "$BACKUP_ENTRY_STORED" "$home_canon"; then
      rc=1
      break
    fi
    applied_dest+=("$BACKUP_ENTRY_DEST")
    applied_stage+=("$BACKUP_APPLIED_STAGE")
    applied_old+=("$BACKUP_APPLIED_HAD_OLD")
    restored=$((restored + 1))
  done

  if (( rc != 0 )); then
    log_error "Restore failed; rolling back $restored applied path(s)."
    backup_restore_rollback_applied applied_dest applied_stage applied_old || rc=2
    log_error "Recovery journal retained: $RESTORE_JOURNAL"
    return 1
  fi

  for (( stage = 0; stage < ${#applied_stage[@]}; stage++ )); do
    if ! backup_restore_commit "${applied_dest[$stage]}" "${applied_stage[$stage]}"; then
      commit_failed=1
    fi
  done

  if (( commit_failed == 1 )); then
    log_error "Restore applied, but cleanup was incomplete. Recovery journal retained: $RESTORE_JOURNAL"
    return 1
  fi

  if ! backup_journal_remove; then
    log_error "Restore completed but the journal could not be removed."
    return 1
  fi
  log_success "Restore complete: $restored path(s) restored (legacy v1, unverified)."
}

backup_restore_snapshot() {
  local snapshot="$1"
  local snapshot_root files_root home_raw home_canon repo_root

  [[ "$DRY_RUN" == "1" ]] || state_lock_acquire "operation" || return 1
  snapshot_root="$(backup_snapshot_path "$snapshot")" || {
    log_error "Not a valid system-init backup snapshot under $BACKUP_DIR: $snapshot"
    return 1
  }
  files_root="$(path_canonicalize "$snapshot_root/files" 2>/dev/null)" || {
    log_error "Backup payload directory is missing: $snapshot_root/files"
    return 1
  }
  if [[ ! -d "$files_root" || -L "$files_root" ]]; then
    log_error "Backup payload directory is unsafe: $files_root"
    return 1
  fi
  home_raw="$(path_lexical "$TARGET_HOME" 2>/dev/null)" || {
    log_error "Target home directory is not a safe path: $TARGET_HOME"
    return 1
  }
  if [[ "$home_raw" == "/" ]]; then
    log_error "Refusing to restore with / as TARGET_HOME."
    return 1
  fi
  home_canon="$(path_canonicalize "$TARGET_HOME" 2>/dev/null)" || {
    log_error "Target home directory is missing: $TARGET_HOME"
    return 1
  }
  repo_root="$(path_canonicalize "$REPO_ROOT" 2>/dev/null)" || {
    log_error "Repository root is missing: $REPO_ROOT"
    return 1
  }

  if [[ -f "$snapshot_root/manifest.v2" ]]; then
    backup_restore_v2_snapshot "$snapshot_root" "$files_root" "$home_raw" "$home_canon" "$repo_root"
    return $?
  fi

  if [[ "$RESTORE_ALLOW_LEGACY" != "1" ]]; then
    log_error "Legacy v1 snapshot has no integrity verification; use --allow-legacy to restore it."
    return 1
  fi
  log_warn "Restoring a legacy v1 snapshot; its content is not cryptographically verified."
  backup_restore_v1_snapshot "$snapshot_root" "$files_root" "$home_raw" "$home_canon" "$repo_root"
}

# Recover from an interrupted restore using a journal created by this user.
# A journal is only accepted from the canonical journal directory, with
# restrictive ownership/permissions, and every destination is re-validated
# against the managed-dotfile allowlist. Unresolved or failed states always
# produce a nonzero exit and preserve staging data.
backup_restore_recover_journal() {
  local journal="${1:-}"
  local journal_dir journal_canon home_canon repo_root
  local status dest dest_canon stage stage_canon old had_old line key
  local restored=0 unresolved=0 entries=0
  local -a journal_lines=()
  local -A completed_keys=()
  local current_uid perms owner stage_perms dest_parent

  [[ -n "$journal" && "$journal" == /* && -f "$journal" && ! -L "$journal" ]] || {
    log_error "Recovery journal is missing, relative, or a symlink: ${journal:-<empty>}"
    return 1
  }
  state_lock_acquire "operation" || return 1
  if [[ -L "$JOURNAL_DIR" ]]; then
    log_error "Recovery journal directory is a symlink: $JOURNAL_DIR"
    return 1
  fi
  journal_dir="$(path_canonicalize "$JOURNAL_DIR" 2>/dev/null)" || {
    log_error "Recovery journal directory does not exist: $JOURNAL_DIR"
    return 1
  }
  [[ -d "$journal_dir" && ! -L "$journal_dir" ]] || {
    log_error "Recovery journal directory is unsafe: $journal_dir"
    return 1
  }
  current_uid="$(id -u)"
  owner="$(file_owner_uid "$journal_dir" 2>/dev/null)" || return 1
  perms="$(file_mode "$journal_dir" 2>/dev/null)" || return 1
  if [[ "$owner" != "$current_uid" || ! "$perms" =~ ^[0-7]{3,4}$ ]] \
    || (( (8#$perms & 077) != 0 )); then
    log_error "Recovery journal directory has unsafe ownership or permissions: $journal_dir"
    return 1
  fi
  journal_canon="$(path_canonicalize "$journal" 2>/dev/null)" || return 1
  [[ "$journal_canon" == "$journal_dir"/* ]] || {
    log_error "Recovery journal is outside the canonical journal directory: $journal"
    return 1
  }
  [[ "$(dirname -- "$journal_canon")" == "$journal_dir" ]] || {
    log_error "Recovery journal is not a direct child of the journal directory: $journal"
    return 1
  }
  [[ "$(basename -- "$journal_canon")" =~ ^restore-.*\.journal$ ]] || {
    log_error "Recovery journal has an unexpected name: $journal"
    return 1
  }
  [[ ! -L "$journal" ]] || {
    log_error "Recovery journal is a symlink: $journal"
    return 1
  }

  owner="$(file_owner_uid "$journal" 2>/dev/null)" || return 1
  perms="$(file_mode "$journal" 2>/dev/null)" || return 1
  [[ "$owner" == "$current_uid" ]] || {
    log_error "Recovery journal is not owned by the current user: $journal"
    return 1
  }
  [[ "$perms" =~ ^[0-7]{3,4}$ ]] && (( (8#$perms & 077) == 0 )) || {
    log_error "Recovery journal permissions are too open: $perms"
    return 1
  }

  home_canon="$(path_canonicalize "$TARGET_HOME" 2>/dev/null)" || {
    log_error "Target home directory is missing: $TARGET_HOME"
    return 1
  }
  repo_root="$(path_canonicalize "$REPO_ROOT" 2>/dev/null)" || return 1
  RESTORE_JOURNAL="$journal_canon"
  mapfile -t journal_lines <"$journal_canon" || {
    log_error "Could not read the recovery journal: $journal_canon"
    return 1
  }

  # Pre-scan terminal records so a retry after a partial recovery is
  # idempotent: already recovered/cleaned/rolled-back/committed entries must
  # not be treated as unresolved merely because their original journal row
  # remains in the file.
  for line in "${journal_lines[@]}"; do
    IFS=$'\t' read -r status dest stage had_old <<<"$line"
    case "$status" in
      RECOVERED|CLEANED|ROLLED_BACK|ROLLED_BACK_LOCAL|COMMITTED)
        [[ -n "${dest:-}" && -n "${stage:-}" ]] && completed_keys["$dest"$'\t'"$stage"]=1
        ;;
    esac
  done

  for line in "${journal_lines[@]}"; do
    IFS=$'\t' read -r status dest stage had_old <<<"$line"
    [[ -n "${status:-}" ]] || continue
    entries=$((entries + 1))
    key="$dest"$'\t'"$stage"
    if [[ -n "${completed_keys[$key]:-}" ]] \
      && [[ "$status" != "RECOVERED" && "$status" != "CLEANED" \
        && "$status" != "ROLLED_BACK" && "$status" != "ROLLED_BACK_LOCAL" \
        && "$status" != "COMMITTED" ]] \
      && [[ -e "$dest" || -L "$dest" ]]; then
      continue
    fi
    case "$status" in
      RECOVERED|CLEANED|ROLLED_BACK|ROLLED_BACK_LOCAL|COMMITTED)
        if [[ -e "$dest" || -L "$dest" ]]; then
          continue
        fi
        log_error "Terminal journal state has no destination: $status $dest"
        unresolved=$((unresolved + 1))
        continue
        ;;
    esac

    case "$status" in
      PREPARED|MOVING_ASIDE|MOVED_ASIDE|NEW_INSTALLED|APPLIED|APPLY_FAILED|\
      ROLLBACK_FAILED|ROLLBACK_REMOVE_FAILED|ROLLBACK_RESTORE_FAILED|\
      COMMIT_FAILED|COMMIT_PENDING|ROLLED_BACK|ROLLED_BACK_LOCAL|\
      RECOVERED|COMMITTED|CLEANED)
        ;;
      *)
        log_error "Unknown journal status '$status' for destination '$dest'."
        unresolved=$((unresolved + 1))
        continue
        ;;
    esac

    if [[ -z "${dest:-}" || -z "${stage:-}" ]]; then
      log_error "Journal entry is missing a destination or staging path."
      unresolved=$((unresolved + 1))
      continue
    fi
    if [[ "$dest" == *..* || "$stage" == *..* ]]; then
      log_error "Journal entry contains a traversal component: $dest / $stage"
      unresolved=$((unresolved + 1))
      continue
    fi
    dest_canon="$(path_resolve "$dest" 2>/dev/null)" || {
      log_error "Could not canonicalize journal destination: $dest"
      unresolved=$((unresolved + 1))
      continue
    }
    if [[ "$dest_canon" != "$dest" ]]; then
      log_error "Journal destination is not canonical: $dest"
      unresolved=$((unresolved + 1))
      continue
    fi
    if [[ "$dest_canon" != "$home_canon"/* ]]; then
      log_error "Journal destination is outside TARGET_HOME: $dest"
      unresolved=$((unresolved + 1))
      continue
    fi
    dest_parent="$(dirname -- "$dest_canon")"
    if path_has_symlink_component "$dest_parent" "$home_canon"; then
      log_error "Journal destination has a symlinked parent: $dest"
      unresolved=$((unresolved + 1))
      continue
    fi
    if ! dotfiles_restore_target_is_safe "${dest_canon#"$home_canon"/}"; then
      log_error "Journal destination is not an approved managed target: $dest"
      unresolved=$((unresolved + 1))
      continue
    fi

    stage_canon="$(path_canonicalize "$stage" 2>/dev/null)" || {
      log_error "Journal staging directory is missing: $stage"
      unresolved=$((unresolved + 1))
      continue
    }
    if [[ "$stage_canon" != "$stage" || "$stage_canon" != "$dest_parent"/* ]]; then
      log_error "Journal staging directory is not under the destination parent: $stage"
      unresolved=$((unresolved + 1))
      continue
    fi
    if [[ "$(dirname -- "$stage_canon")" != "$dest_parent" \
      || "$(basename -- "$stage_canon")" != .system-init-restore.* ]]; then
      log_error "Journal staging path is not a restore staging directory: $stage"
      unresolved=$((unresolved + 1))
      continue
    fi
    [[ -d "$stage_canon" && ! -L "$stage_canon" ]] || {
      log_error "Journal staging directory is missing or a symlink: $stage"
      unresolved=$((unresolved + 1))
      continue
    }
    stage_perms="$(file_mode "$stage_canon" 2>/dev/null)" || stage_perms=""
    owner="$(file_owner_uid "$stage_canon" 2>/dev/null)" || owner=""
    if [[ "$owner" != "$current_uid" || ! "$stage_perms" =~ ^[0-7]{3,4}$ ]] \
      || (( (8#$stage_perms & 077) != 0 )); then
      log_error "Journal staging directory has unsafe ownership or permissions: $stage"
      unresolved=$((unresolved + 1))
      continue
    fi

    old="$stage_canon/old"
    if [[ -d "$old" && ! -L "$old" ]]; then
      log_error "Journal contains a directory payload for $dest."
      unresolved=$((unresolved + 1))
      continue
    fi
    if [[ -L "$old" ]]; then
      log_error "Journal contains a symlink payload for $dest; manual review required."
      unresolved=$((unresolved + 1))
      continue
    elif [[ -e "$old" && ! -f "$old" ]]; then
      log_error "Journal contains an unsupported payload type for $dest."
      unresolved=$((unresolved + 1))
      continue
    fi

    # Already-resolved states. Remove an empty staging directory when the
    # transaction never moved the destination, but never report success for a
    # state that still has an old copy waiting for manual review.
    case "$status" in
      ROLLED_BACK|ROLLED_BACK_LOCAL|RECOVERED|COMMITTED|CLEANED)
        [[ -e "$old" || -L "$old" ]] && unresolved=$((unresolved + 1))
        continue
        ;;
    esac

    if [[ "$status" == "PREPARED" || "$status" == "MOVING_ASIDE" || "$status" == "APPLY_FAILED" ]] \
      && [[ -e "$dest" || -L "$dest" ]] && [[ ! -e "$old" && ! -L "$old" ]]; then
      # The destination move never happened. The stage contains only a new
      # payload that was never installed; clean it up.
      if safe_rm_rf "$stage_canon"; then
        backup_journal_write "CLEANED" "$dest" "$stage_canon" "$had_old" || {
          unresolved=$((unresolved + 1))
        }
        restored=$((restored + 1))
      else
        unresolved=$((unresolved + 1))
      fi
      continue
    fi

    if [[ -e "$dest" || -L "$dest" ]]; then
      log_warn "Recovery: destination exists, leaving previous data at $stage_canon/old"
      unresolved=$((unresolved + 1))
      continue
    fi
    if [[ ! -e "$old" && ! -L "$old" ]]; then
      log_error "Recovery: no previous data at $stage_canon/old for $dest"
      unresolved=$((unresolved + 1))
      continue
    fi
    if ! mv_replace "$old" "$dest"; then
      log_error "Recovery failed for $dest; previous data remains at $stage_canon/old"
      unresolved=$((unresolved + 1))
      continue
    fi
    if [[ -L "$dest" ]]; then
      if ! backup_payload_symlink_safe "$dest" "$home_canon" "$repo_root" "$dest_parent"; then
        log_error "Recovered symlink escapes the allowed roots: $dest"
        unresolved=$((unresolved + 1))
        continue
      fi
    elif [[ ! -f "$dest" ]]; then
      log_error "Recovered destination has an unsupported type: $dest"
      unresolved=$((unresolved + 1))
      continue
    fi
    if ! backup_journal_write "RECOVERED" "$dest" "$stage_canon" "$had_old"; then
      log_error "Recovered $dest but could not record it in the journal."
      unresolved=$((unresolved + 1))
      continue
    fi
    if ! safe_rm_rf "$stage_canon"; then
      log_error "Recovered $dest but could not remove staging data: $stage_canon"
      unresolved=$((unresolved + 1))
      continue
    fi
    restored=$((restored + 1))
    log_success "Recovered $dest"
  done

  if (( entries == 0 )); then
    log_error "Recovery journal is empty: $journal_canon"
    return 1
  fi
  if (( unresolved > 0 )); then
    log_error "Recovery completed with $unresolved unresolved path(s); journals and staging data were preserved."
    return 1
  fi
  if ! backup_journal_remove; then
    log_error "Recovery succeeded but the journal could not be removed."
    return 1
  fi
  log_success "Recovery complete: $restored path(s) restored; journal removed."
  return 0
}
