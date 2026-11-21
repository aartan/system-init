#!/usr/bin/env bash
# Manifest-driven dotfile linking.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_DOTFILES_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_DOTFILES_SOURCED=1

DOTFILES_MANIFEST="$REPO_ROOT/dotfiles/manifest.tsv"

# Only these destinations are managed by this repository. Adding a new
# dotfile requires an explicit entry here; arbitrary manifest targets are not
# allowed, even if they are relative to $HOME.
DOTFILES_ALLOWED_TARGETS=(
  ".gitconfig"
  ".zshrc"
  ".p10k.zsh"
  ".config/alacritty/alacritty.toml"
  ".config/btop/btop.conf"
  ".config/Code/User/settings.json"
  "Library/Application Support/Code/User/settings.json"
)

# Additional files created or updated by the installer at an exact, known
# destination. They are valid restore destinations but are never linked from
# the dotfiles manifest.
DOTFILES_RESTORE_EXTRA_TARGETS=(
  ".gitconfig.local"
)

_dotfiles_manifest_error() {
  printf 'dotfiles manifest: %s\n' "$*" >&2
}

dotfiles_target_allowed() {
  local target="$1"
  local allowed
  for allowed in "${DOTFILES_ALLOWED_TARGETS[@]}"; do
    [[ "$target" == "$allowed" ]] && return 0
  done

  # Font conflicts are backed up by the fonts module. Only the exact pinned
  # JetBrainsMono Nerd Font payloads are restorable.
  case "$target" in
    .local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFont*.ttf|\
    .local/share/fonts/JetBrainsMono/OFL.txt|\
    .local/share/fonts/JetBrainsMono/README.md|\
    Library/Fonts/JetBrainsMonoNerdFont*.ttf)
      return 0
      ;;
  esac
  return 1
}

dotfiles_restore_extra_allowed() {
  local target="$1"
  local allowed
  for allowed in "${DOTFILES_RESTORE_EXTRA_TARGETS[@]}"; do
    [[ "$target" == "$allowed" ]] && return 0
  done
  return 1
}

# Validate a destination expressed relative to $TARGET_HOME. allow_extra=1 is
# used only by restore, where installer-created side files are legitimate.
dotfiles_target_rel_is_safe() {
  local target="$1"
  local allow_extra="${2:-0}"
  local home_lexical home_canonical target_lexical
  local parent_lexical parent_root parent_canonical

  [[ -n "$target" ]] || return 1
  [[ "$target" != /* && "$target" != *..* && "$target" != "." && "$target" != "./" ]] || return 1
  if [[ "$allow_extra" == "1" ]]; then
    dotfiles_target_allowed "$target" || dotfiles_restore_extra_allowed "$target" || return 1
  else
    dotfiles_target_allowed "$target" || return 1
  fi

  home_lexical="$(path_lexical "$TARGET_HOME" 2>/dev/null)" || return 1
  home_canonical="$(target_home_resolve 2>/dev/null)" || return 1
  target_lexical="$(path_lexical "$TARGET_HOME/$target" 2>/dev/null)" || return 1

  # Accept either the spelled home (possibly a symlink) or its canonical form.
  [[ "$target_lexical" == "$home_lexical"/* || "$target_lexical" == "$home_canonical"/* ]] || return 1

  if [[ "$target_lexical" == "$home_lexical"/* ]]; then
    parent_root="$home_lexical"
  else
    parent_root="$home_canonical"
  fi
  parent_lexical="$(dirname -- "$target_lexical")"
  [[ "$parent_lexical" == "$parent_root" || "$parent_lexical" == "$parent_root"/* ]] || return 1

  # Reject any existing symlinked parent below the home root. The leaf itself
  # may be a managed symlink and is handled by the backup/replace path.
  path_has_symlink_component "$parent_lexical" "$parent_root" && return 1

  # Existing symlink components must not redirect the parent outside home.
  parent_canonical="$(path_resolve "$parent_lexical" 2>/dev/null)" || return 1
  [[ "$parent_canonical" == "$home_canonical" || "$parent_canonical" == "$home_canonical"/* ]] || return 1

  return 0
}

dotfiles_target_is_safe() {
  dotfiles_target_rel_is_safe "$1" 0
}

dotfiles_restore_target_is_safe() {
  dotfiles_target_rel_is_safe "$1" 1
}

dotfiles_platform_matches() {
  local platforms="$1"
  local item
  local -a items=()
  IFS=',' read -r -a items <<<"$platforms"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    case "$item" in
      all) return 0 ;;
      "$PLATFORM") return 0 ;;
    esac
  done
  return 1
}

dotfiles_row_valid() {
  local module="$1"
  local strategy="$2"
  local platforms="$3"
  local source="$4"
  local target="$5"
  local token

  [[ -n "$module" && -n "$strategy" && -n "$platforms" && -n "$source" && -n "$target" ]] || {
    _dotfiles_manifest_error "malformed row: ${module:-?} ${strategy:-?} ${platforms:-?} ${source:-?} ${target:-?}"
    return 1
  }

  if ! module_name_is_valid "$module"; then
    _dotfiles_manifest_error "invalid module name '$module'."
    return 1
  fi
  if [[ ! -d "$REPO_ROOT/modules/$module" ]]; then
    _dotfiles_manifest_error "unknown module '$module'."
    return 1
  fi

  case "$strategy" in
    symlink|copy) ;;
    *)
      _dotfiles_manifest_error "unsupported strategy '$strategy' for $target."
      return 1
      ;;
  esac

  local -a tokens=()
  IFS=',' read -r -a tokens <<<"$platforms"
  for token in "${tokens[@]}"; do
    token="${token//[[:space:]]/}"
    case "$token" in
      all|fedora|macos) ;;
      *)
        _dotfiles_manifest_error "unsupported platform '$token' for $target."
        return 1
        ;;
    esac
  done

  if [[ "$source" == /* || "$source" == *..* ]]; then
    _dotfiles_manifest_error "source must be a repository-relative path without '..': $source"
    return 1
  fi
  if [[ ! -e "$REPO_ROOT/$source" ]]; then
    _dotfiles_manifest_error "source does not exist: $source"
    return 1
  fi
  if ! path_is_under "$REPO_ROOT/$source" "$REPO_ROOT"; then
    _dotfiles_manifest_error "source escapes the repository: $source"
    return 1
  fi
  if ! path_is_under "$(path_resolve "$REPO_ROOT/$source")" "$(path_resolve "$REPO_ROOT")"; then
    _dotfiles_manifest_error "source resolves outside the repository: $source"
    return 1
  fi

  if ! dotfiles_target_is_safe "$target"; then
    _dotfiles_manifest_error "target is not an approved managed destination: $target"
    return 1
  fi

  return 0
}

# Prints the effective manifest rows for the current platform and selected
# modules: module<TAB>strategy<TAB>source<TAB>target
dotfiles_entries() {
  local module strategy platforms source target
  local -A chosen_strategy=() chosen_source=() chosen_platforms=() chosen_module=()
  local -a order=()
  local failed=0

  [[ -f "$DOTFILES_MANIFEST" ]] || {
    _dotfiles_manifest_error "manifest is missing: $DOTFILES_MANIFEST"
    return 1
  }

  while IFS=$'\t' read -r module strategy platforms source target; do
    [[ -z "${module:-}" ]] && continue
    [[ "$module" == \#* ]] && continue
    module="${module//[[:space:]]/}"

    module_selected "$module" || continue
    dotfiles_platform_matches "$platforms" || continue

    dotfiles_row_valid "$module" "$strategy" "$platforms" "$source" "$target" || {
      failed=1
      continue
    }

    if [[ -n "${chosen_strategy[$target]:-}" ]]; then
      local existing_platforms="${chosen_platforms[$target]}"
      if [[ "$existing_platforms" == "all" && "$platforms" != "all" ]]; then
        chosen_strategy[$target]="$strategy"
        chosen_source[$target]="$source"
        chosen_platforms[$target]="$platforms"
        chosen_module[$target]="$module"
      elif [[ "$existing_platforms" != "all" && "$platforms" == "all" ]]; then
        :
      else
        _dotfiles_manifest_error "duplicate target '$target' (modules: ${chosen_module[$target]} and $module)."
        failed=1
      fi
      continue
    fi

    chosen_strategy[$target]="$strategy"
    chosen_source[$target]="$source"
    chosen_platforms[$target]="$platforms"
    chosen_module[$target]="$module"
    order+=("$target")
  done <"$DOTFILES_MANIFEST"

  (( failed == 0 )) || return 1

  local entry
  for entry in "${order[@]}"; do
    printf '%s\t%s\t%s\t%s\n' \
      "${chosen_module[$entry]}" \
      "${chosen_strategy[$entry]}" \
      "${chosen_source[$entry]}" \
      "$entry"
  done
}

dotfiles_source_abs() {
  printf '%s/%s\n' "$REPO_ROOT" "$1"
}

dotfiles_target_abs() {
  printf '%s/%s\n' "$TARGET_HOME" "$1"
}

dotfiles_target_is_managed() {
  local source_abs="$1"
  local target_abs="$2"
  [[ -L "$target_abs" ]] || return 1
  local resolved
  resolved="$(path_canonicalize "$target_abs" 2>/dev/null || true)"
  [[ "$resolved" == "$source_abs" ]]
}

dotfiles_copy_matches() {
  local source_abs="$1"
  local target_abs="$2"
  if [[ -f "$source_abs" && -f "$target_abs" ]]; then
    cmp -s -- "$source_abs" "$target_abs"
    return
  fi
  if [[ -d "$source_abs" && -d "$target_abs" ]]; then
    diff -rq -- "$source_abs" "$target_abs" >/dev/null 2>&1
    return
  fi
  return 1
}

dotfiles_install_one() {
  local module="$1"
  local strategy="$2"
  local source_rel="$3"
  local target_rel="$4"
  local source_abs target_abs

  source_abs="$(dotfiles_source_abs "$source_rel")"
  target_abs="$(dotfiles_target_abs "$target_rel")"

  if ! dotfiles_target_is_safe "$target_rel"; then
    record_failure "Refusing unsafe dotfile target: $target_rel"
    return 1
  fi

  if [[ ! -e "$source_abs" ]]; then
    record_failure "Dotfile source missing: $source_rel"
    return 1
  fi

  if [[ -d "$target_abs" && ! -L "$target_abs" ]]; then
    record_failure "Refusing to replace a directory with a dotfile: $target_rel"
    return 1
  fi

  if [[ "$strategy" == "symlink" ]]; then
    if dotfiles_target_is_managed "$source_abs" "$target_abs"; then
      log_debug "Dotfile already linked: $target_rel"
      return 0
    fi
  else
    if dotfiles_copy_matches "$source_abs" "$target_abs"; then
      log_debug "Copied dotfile already current: $target_rel"
      return 0
    fi
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ -e "$target_abs" || -L "$target_abs" ]]; then
      log_dry "back up $(log_cmd "$target_abs"), then install $strategy for $target_rel"
    else
      log_dry "install $strategy for $target_rel"
    fi
    return 0
  fi

  local had_conflict=0
  if [[ -e "$target_abs" || -L "$target_abs" ]]; then
    had_conflict=1
    backup_path "$target_abs" "dotfile-conflict" || return 1
    # A target that appeared after the pre-install backup starts a new
    # snapshot. Finalize it before removing the target so the only copy is
    # actually published and restorable.
    if [[ -n "${BACKUP_RUN_DIR:-}" && "${BACKUP_SNAPSHOT_COMPLETE:-0}" != "1" ]]; then
      backup_finalize || {
        record_failure "Could not finalize backup for dotfile target: $target_rel"
        return 1
      }
    fi
    rm -rf -- "$target_abs" || return 1
  fi

  mkdir -p -- "$(dirname -- "$target_abs")" || return 1
  if path_has_symlink_component "$(dirname -- "$target_abs")" "$TARGET_HOME"; then
    record_failure "Refusing dotfile target with a symlinked parent: $target_rel"
    return 1
  fi

  if [[ "$strategy" == "symlink" ]]; then
    ln -s -- "$source_abs" "$target_abs" || return 1
    if ! dotfiles_target_is_managed "$source_abs" "$target_abs"; then
      record_failure "Symlink verification failed for $target_rel"
      return 1
    fi
  else
    cp -a "$source_abs" "$target_abs" || return 1
    if ! dotfiles_copy_matches "$source_abs" "$target_abs"; then
      record_failure "Copy verification failed for $target_rel"
      return 1
    fi
  fi

  if [[ "$had_conflict" == "1" ]]; then
    log_success "Backed up and installed dotfile: $target_rel"
  else
    log_success "Installed dotfile: $target_rel"
  fi
}

dotfiles_install() {
  local module strategy source_rel target_rel
  local count=0
  local entries

  if ! entries="$(dotfiles_entries)"; then
    record_failure "Dotfiles manifest validation failed."
    return 1
  fi

  while IFS=$'\t' read -r module strategy source_rel target_rel; do
    [[ -z "${module:-}" ]] && continue
    CURRENT_MODULE="$module"
    if ! dotfiles_install_one "$module" "$strategy" "$source_rel" "$target_rel"; then
      record_failure "Failed to install dotfile $target_rel"
      continue
    fi
    count=$((count + 1))
  done <<<"$entries"

  # shellcheck disable=SC2034
  CURRENT_MODULE="dotfiles"
  if (( count == 0 )); then
    log_warn "No dotfiles selected for installation."
  else
    log_info "Processed $count dotfile entr(y/ies)."
  fi
}

dotfiles_check_status() {
  local module strategy source_rel target_rel
  local source_abs target_abs
  local problems=0
  local entries

  if ! entries="$(dotfiles_entries)"; then
    log_error "Dotfiles manifest validation failed."
    return 1
  fi

  while IFS=$'\t' read -r module strategy source_rel target_rel; do
    [[ -z "${module:-}" ]] && continue
    source_abs="$(dotfiles_source_abs "$source_rel")"
    target_abs="$(dotfiles_target_abs "$target_rel")"

    if [[ "$strategy" == "symlink" ]]; then
      if ! dotfiles_target_is_managed "$source_abs" "$target_abs"; then
        log_warn "Unmanaged or missing dotfile: $target_rel"
        problems=$((problems + 1))
      fi
    else
      if ! dotfiles_copy_matches "$source_abs" "$target_abs"; then
        log_warn "Missing or outdated copied dotfile: $target_rel"
        problems=$((problems + 1))
      fi
    fi
  done <<<"$entries"

  return "$problems"
}

dotfiles_count() {
  local entries
  entries="$(dotfiles_entries 2>/dev/null)" || return 1
  printf '%s\n' "$(grep -c . <<<"$entries" || true)"
}

dotfiles_target_selected() {
  local wanted="$1"
  local module strategy source_rel target_rel
  local entries

  entries="$(dotfiles_entries)" || return 1
  while IFS=$'\t' read -r module strategy source_rel target_rel; do
    [[ "$target_rel" == "$wanted" ]] && return 0
  done <<<"$entries"
  return 1
}
