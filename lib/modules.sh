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
  [[ -f "$REPO_ROOT/modules/$1/module.conf" ]]
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
      if ! modules_exists "$dep"; then
        record_failure "Module '$module' depends on unknown module '$dep'."
        failed=1
      fi
    done < <(modules_dependencies "$module")
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
}

modules_run() {
  local module

  for module in "${SELECTED_MODULES[@]}"; do
    CURRENT_MODULE="$module"
    log_section "Module: $module — $(module_description_or_default "$module")"

    if ! packages_install_module "$module"; then
      record_failure "Package installation failed for module '$module'."
    fi

    local hook="$REPO_ROOT/modules/$module/post-install.sh"
    if [[ -f "$hook" ]]; then
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
