#!/usr/bin/env bash
# Declarative package installation.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_PACKAGES_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_PACKAGES_SOURCED=1

packages_module_file() {
  local module="$1"
  printf '%s/modules/%s/packages.%s\n' "$REPO_ROOT" "$module" "$PLATFORM"
}

packages_selected_managers() {
  local module file manager
  local -a managers=()
  for module in "${SELECTED_MODULES[@]}"; do
    file="$(packages_module_file "$module")"
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      read -r manager _ _ <<<"$line"
      [[ -z "${manager:-}" ]] && continue
      if [[ " ${managers[*]} " != *" $manager "* ]]; then
        managers+=("$manager")
      fi
    done <"$file"
  done
  printf '%s\n' "${managers[@]}"
}

packages_have_work() {
  local module file
  for module in "${SELECTED_MODULES[@]}"; do
    file="$(packages_module_file "$module")"
    [[ -f "$file" ]] || continue
    if awk '
      {
        sub(/#.*/, "")
        if ($0 ~ /[^[:space:]]/) found = 1
      }
      END { exit(found ? 0 : 1) }
    ' "$file"; then
      return 0
    fi
  done
  return 1
}

packages_array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

packages_install_module() {
  local module="$1"
  local file
  file="$(packages_module_file "$module")"

  if [[ ! -f "$file" ]]; then
    log_debug "No packages declared for module '$module' on $PLATFORM."
    return 0
  fi

  local -a dnf_required=() dnf_optional=()
  local -a flatpak_required=() flatpak_optional=()
  local -a brew_required=() brew_optional=() cask_required=() cask_optional=()

  local line manager package optional
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    read -r manager package optional <<<"$line"

    if [[ -z "${manager:-}" || -z "${package:-}" ]]; then
      record_failure "Malformed package line in $file: $line"
      continue
    fi

    if [[ -n "${optional:-}" && "$optional" != "optional" ]]; then
      record_failure "Unknown package flag '$optional' in $file: $line"
      continue
    fi

    case "$manager" in
      dnf)
        if ! packages_array_contains "$package" "${dnf_required[@]}" "${dnf_optional[@]}"; then
          if [[ "$optional" == "optional" ]]; then
            dnf_optional+=("$package")
          else
            dnf_required+=("$package")
          fi
        fi
        ;;
      flatpak)
        if ! packages_array_contains "$package" "${flatpak_required[@]}" "${flatpak_optional[@]}"; then
          if [[ "$optional" == "optional" ]]; then
            flatpak_optional+=("$package")
          else
            flatpak_required+=("$package")
          fi
        fi
        ;;
      brew)
        if ! packages_array_contains "$package" "${brew_required[@]}" "${brew_optional[@]}"; then
          if [[ "$optional" == "optional" ]]; then
            brew_optional+=("$package")
          else
            brew_required+=("$package")
          fi
        fi
        ;;
      cask)
        if ! packages_array_contains "$package" "${cask_required[@]}" "${cask_optional[@]}"; then
          if [[ "$optional" == "optional" ]]; then
            cask_optional+=("$package")
          else
            cask_required+=("$package")
          fi
        fi
        ;;
      *)
        record_failure "Unsupported package manager '$manager' in $file"
        ;;
    esac
  done <"$file"

  if (( ${#dnf_required[@]} > 0 )); then
    if ! dnf_install "${dnf_required[@]}"; then
      record_failure "Failed to install required DNF packages for module '$module'."
    fi
  fi

  if (( ${#flatpak_required[@]} > 0 )); then
    if ! flatpak_install "${flatpak_required[@]}"; then
      record_failure "Failed to install required Flatpak applications for module '$module'."
    fi
  fi

  if [[ "$INSTALL_OPTIONAL_APPS" == "1" ]]; then
    if (( ${#dnf_optional[@]} > 0 )); then
      if ! dnf_install "${dnf_optional[@]}"; then
        record_warning "Optional DNF packages failed for module '$module'."
      fi
    fi

    if (( ${#flatpak_optional[@]} > 0 )); then
      if ! flatpak_install "${flatpak_optional[@]}"; then
        record_warning "Optional Flatpak applications failed for module '$module'."
      fi
    fi

    if (( ${#brew_optional[@]} > 0 )); then
      if ! brew_install "${brew_optional[@]}"; then
        record_warning "Optional Homebrew formulae failed for module '$module'."
      fi
    fi

    if (( ${#cask_optional[@]} > 0 )); then
      if ! brew_cask_install "${cask_optional[@]}"; then
        record_warning "Optional Homebrew casks failed for module '$module'."
      fi
    fi
  fi
}

packages_list_module() {
  local module="$1"
  local file
  file="$(packages_module_file "$module")"
  [[ -f "$file" ]] || return 0
  awk '
    {
      sub(/#.*/, "")
      if ($0 ~ /[^[:space:]]/) print
    }
  ' "$file"
}

packages_count_module() {
  local module="$1"
  local count
  count="$(packages_list_module "$module" | wc -l)"
  printf '%s\n' "$((count + 0))"
}
