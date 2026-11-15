#!/usr/bin/env bash
# Module selection, dependency resolution, and execution.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_MODULES_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_MODULES_SOURCED=1

MODULES_CONF="$REPO_ROOT/config/modules.conf"

modules_all() {
  local module
  while IFS= read -r module || [[ -n "$module" ]]; do
    module="${module%%#*}"
    module="${module//[[:space:]]/}"
    [[ -z "$module" ]] && continue
    printf '%s\n' "$module"
  done <"$MODULES_CONF"
}

modules_exists() {
  local module="${1:-}"
  local module_dir
  module_name_is_valid "$module" || return 1
  module_dir="$REPO_ROOT/modules/$module"
  [[ -d "$module_dir" && ! -L "$module_dir" ]] || return 1
  [[ -f "$module_dir/module.conf" && ! -L "$module_dir/module.conf" ]]
}

# Resolve a module hook to an absolute path that is guaranteed to live under
# modules/. Symlinked module directories and hooks are refused: a checkout
# owned by another user must not be able to inject code into the installer.
modules_hook_path() {
  local module="${1:-}"
  local modules_root module_dir hook resolved

  module_name_is_valid "$module" || return 1

  modules_root="$(realpath -e -- "$REPO_ROOT/modules" 2>/dev/null)" || return 1
  module_dir="$modules_root/$module"
  [[ -d "$module_dir" && ! -L "$module_dir" ]] || return 1

  hook="$module_dir/post-install.sh"
  [[ -f "$hook" && ! -L "$hook" ]] || return 1

  resolved="$(realpath -e -- "$hook" 2>/dev/null)" || return 1
  [[ "$resolved" == "$modules_root"/* ]] || return 1
  printf '%s\n' "$resolved"
}

module_in_list() {
  local wanted="$1"
  local list="$2"
  local item
  local -a items=()

  read -r -a items <<<"$list"
  for item in "${items[@]}"; do
    [[ -z "$item" ]] && continue
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

modules_profile_modules() {
  local profile="$1"
  local module
  local -a items=()

  case "$profile" in
    core)
      read -r -a items <<<"${CORE_MODULES:-}"
      for module in "${items[@]}"; do
        [[ -z "$module" ]] && continue
        printf '%s\n' "$module"
      done
      ;;
    extended)
      modules_all
      ;;
    *)
      return 1
      ;;
  esac
}

modules_profile_validate() {
  local profile="$1"
  local module
  local failed=0
  local -a items=()

  case "$profile" in
    core|extended) ;;
    *)
      log_error "Unknown profile: $profile"
      return 1
      ;;
  esac

  read -r -a items <<<"${CORE_MODULES:-}"
  if (( ${#items[@]} == 0 )); then
    log_error "The core profile does not list any modules."
    return 1
  fi

  for module in "${items[@]}"; do
    [[ -z "$module" ]] && continue
    if ! modules_exists "$module"; then
      log_error "Core profile references unknown module: $module"
      failed=1
    fi
    if module_in_list "$module" "${EXTENDED_ONLY_MODULES:-}"; then
      log_error "Module '$module' is listed as core and extended-only."
      failed=1
    fi
  done

  return "$failed"
}

modules_validate_all() {
  local module dep
  local failed=0
  while IFS= read -r module; do
    if ! modules_exists "$module"; then
      record_failure "Module listed in config/modules.conf has no module.conf: $module"
      failed=1
      continue
    fi
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      if ! module_name_is_valid "$dep"; then
        record_failure "Module '$module' has an invalid dependency name: $dep"
        failed=1
        continue
      fi
      if ! modules_exists "$dep"; then
        record_failure "Module '$module' depends on unknown module '$dep'."
        failed=1
      fi
    done < <(modules_dependencies "$module")

    if [[ -e "$REPO_ROOT/modules/$module/post-install.sh" || -L "$REPO_ROOT/modules/$module/post-install.sh" ]]; then
      if ! modules_hook_path "$module" >/dev/null; then
        record_failure "Module '$module' has an unsafe post-install hook (symlinked or outside modules/)."
        failed=1
      fi
    fi
  done < <(modules_all)
  return "$failed"
}

modules_dependencies() {
  local deps
  deps="$(module_depends "$1")"
  [[ -z "$deps" ]] && return 0
  local dep
  local -a items=()
  IFS=',' read -r -a items <<<"$deps"
  for dep in "${items[@]}"; do
    dep="${dep//[[:space:]]/}"
    [[ -z "$dep" ]] && continue
    printf '%s\n' "$dep"
  done
}

modules_resolve() {
  local requested=("$@")
  local -A wanted=()
  local -a queue=()
  local module dep

  if (( ${#requested[@]} == 0 )); then
    while IFS= read -r module; do
      queue+=("$module")
      wanted["$module"]=1
    done < <(modules_all)
  else
    for module in "${requested[@]}"; do
      if ! modules_exists "$module"; then
        log_error "Unknown module: $module"
        return 1
      fi
      if [[ -z "${wanted[$module]:-}" ]]; then
        wanted["$module"]=1
        queue+=("$module")
      fi
    done

    local index=0
    while (( index < ${#queue[@]} )); do
      module="${queue[$index]}"
      index=$((index + 1))
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        if ! module_name_is_valid "$dep"; then
          log_error "Module '$module' has an invalid dependency name: $dep"
          return 1
        fi
        if ! modules_exists "$dep"; then
          log_error "Module '$module' depends on unknown module '$dep'."
          return 1
        fi
        if [[ -z "${wanted[$dep]:-}" ]]; then
          wanted["$dep"]=1
          queue+=("$dep")
        fi
      done < <(modules_dependencies "$module")
    done
  fi

  # Emit in the canonical modules.conf order, not dependency discovery order.
  SELECTED_MODULES=()
  while IFS= read -r module; do
    if [[ -n "${wanted[$module]:-}" ]]; then
      SELECTED_MODULES+=("$module")
      unset "wanted[$module]"
    fi
  done < <(modules_all)

  # Any selected module that is not listed in modules.conf is appended so a
  # direct --module request cannot be silently dropped.
  for module in "${!wanted[@]}"; do
    SELECTED_MODULES+=("$module")
  done
}

modules_list() {
  local module description count
  printf '%-16s %-8s %s\n' "MODULE" "PACKAGES" "DESCRIPTION"
  while IFS= read -r module; do
    description="$(module_description_or_default "$module")"
    count="$(packages_count_module "$module")"
    printf '%-16s %-8s %s\n' "$module" "$count" "$description"
  done < <(modules_all)
  printf '\nDotfiles managed for the current platform: %s\n' "$(dotfiles_count 2>/dev/null || printf '?')"
  printf 'Core profile:'
  while IFS= read -r module; do
    printf ' %s' "$module"
  done < <(modules_profile_modules core)
  printf '\nExtended profile: all modules\n'
}

modules_run() {
  local module

  for module in "${SELECTED_MODULES[@]}"; do
    CURRENT_MODULE="$module"
    log_section "Module: $module — $(module_description_or_default "$module")"

    if ! packages_install_module "$module"; then
      record_failure "Package installation failed for module '$module'."
    fi

    local hook=""
    if [[ -e "$REPO_ROOT/modules/$module/post-install.sh" || -L "$REPO_ROOT/modules/$module/post-install.sh" ]]; then
      if ! hook="$(modules_hook_path "$module")"; then
        record_failure "Refusing unsafe post-install hook for module '$module'."
        continue
      fi
      # shellcheck disable=SC1090
      if ! source "$hook"; then
        record_failure "Failed to load post-install hook for module '$module'."
        continue
      fi
      if declare -F module_post_install >/dev/null 2>&1; then
        if ! module_post_install; then
          record_failure "Post-install hook failed for module '$module'."
        fi
        unset -f module_post_install
      else
        record_warning "Module '$module' has a post-install.sh without module_post_install()."
      fi
    fi
  done
  # shellcheck disable=SC2034
  CURRENT_MODULE="modules"
}
