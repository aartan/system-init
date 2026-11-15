#!/usr/bin/env bash
# Flatpak adapter.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_FLATPAK_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_FLATPAK_SOURCED=1

flatpak_package_installed() {
  # Only a system installation is relevant to the privileged installer. A
  # user-level Flatpak with the same app ID must not shadow the system app.
  flatpak info --system -- "$1" >/dev/null 2>&1
}

# Official Flathub endpoints. The .flatpakrepo descriptors are preferred when
# adding a remote because they carry the repository GPG key; Flatpak records
# the repository URL itself, so both forms must verify as the same identity.
FLATPAK_FLATHUB_REPO_URL="https://dl.flathub.org/repo/"
FLATPAK_FLATHUB_REPO_FILE="https://dl.flathub.org/repo/flathub.flatpakrepo"
FLATPAK_FLATHUB_LEGACY_REPO_URL="https://flathub.org/repo/"
FLATPAK_FLATHUB_LEGACY_REPO_FILE="https://flathub.org/repo/flathub.flatpakrepo"

# Return the URL configured for a system Flatpak remote, or empty if the
# remote is absent. Read-only; safe for doctor.
flatpak_system_remote_url() {
  local remote="${1:-${FLATPAK_REMOTE:-flathub}}"
  flatpak remotes --system --columns=name,url 2>/dev/null \
    | awk -v n="$remote" '$1 == n { print $2; exit }'
}

# Print the explicitly approved endpoints for a remote. Unknown remote names
# have no approved endpoints. Fedora's OCI remotes are listed separately so
# their verification is not confused with Flathub.
flatpak_remote_approved_urls() {
  case "${1:-}" in
    flathub)
      printf '%s\n' \
        "$FLATPAK_FLATHUB_REPO_FILE" \
        "$FLATPAK_FLATHUB_REPO_URL" \
        "${FLATPAK_FLATHUB_REPO_URL%/}" \
        "$FLATPAK_FLATHUB_LEGACY_REPO_FILE" \
        "$FLATPAK_FLATHUB_LEGACY_REPO_URL"
      ;;
    fedora)
      printf '%s\n' \
        "oci+https://registry.fedoraproject.org" \
        "https://registry.fedoraproject.org"
      ;;
    fedora-testing)
      printf '%s\n' \
        "oci+https://registry.fedoraproject.org#testing" \
        "https://registry.fedoraproject.org#testing"
      ;;
    *)
      return 1
      ;;
  esac
}

flatpak_remote_url_is_approved() {
  local remote="${1:-}"
  local url="${2:-}"
  local approved

  [[ -n "$remote" && -n "$url" ]] || return 1
  [[ "$url" != *[[:space:][:cntrl:]]* ]] || return 1

  while IFS= read -r approved; do
    [[ "$url" == "$approved" ]] && return 0
  done < <(flatpak_remote_approved_urls "$remote")
  return 1
}

flatpak_remote_url_matches() {
  local remote="${1:-${FLATPAK_REMOTE:-flathub}}"
  local expected="${2:-${FLATPAK_REPO_URL:-$FLATPAK_FLATHUB_REPO_FILE}}"
  local actual

  actual="$(flatpak_system_remote_url "$remote")"
  [[ -n "$actual" ]] || return 1
  flatpak_remote_url_is_approved "$remote" "$expected" || return 1
  flatpak_remote_url_is_approved "$remote" "$actual" || return 1

  # All approved Flathub endpoints refer to the same repository. Other remote
  # identities (for example Fedora's stable and testing OCI remotes) must
  # match exactly.
  case "$remote" in
    flathub) return 0 ;;
    *) [[ "$actual" == "$expected" ]] ;;
  esac
}

flatpak_remote_ensure() {
  local remote="${FLATPAK_REMOTE:-flathub}"
  local url="${FLATPAK_REPO_URL:-$FLATPAK_FLATHUB_REPO_FILE}"
  local actual approved

  if ! package_name_is_valid "$remote"; then
    log_error "Refusing invalid Flatpak remote name: $remote"
    return 1
  fi

  # Fail closed unless both the remote identity and URL are explicitly known.
  # This blocks option injection and prevents a modified settings file from
  # pointing the system remote at a local or attacker-controlled repository.
  if ! flatpak_remote_url_is_approved "$remote" "$url"; then
    log_error "Refusing unapproved Flatpak repository URL for remote '$remote'."
    log_error "Expected: one of the following approved URLs:"
    while IFS= read -r approved; do
      log_error "  $approved"
    done < <(flatpak_remote_approved_urls "$remote" || true)
    log_error "Detected: $url"
    return 1
  fi

  if ! have_command flatpak; then
    record_failure "flatpak is not installed; cannot manage Flatpak applications."
    return 1
  fi

  if flatpak remotes --system 2>/dev/null | awk 'NR > 0 { print $1 }' | grep -Fxq "$remote"; then
    if flatpak_remote_url_matches "$remote" "$url"; then
      log_debug "Flatpak remote already present with an approved URL: $remote"
      return 0
    fi
    actual="$(flatpak_system_remote_url "$remote")"
    log_error "Flatpak remote '$remote' exists with an unexpected URL; refusing to trust or overwrite it."
    log_error "Expected: $url"
    log_error "Detected: ${actual:-<missing>}"
    return 1
  fi

  # A .flatpakrepo descriptor carries the repository's GPG key. Never pass
  # --no-gpg-verify here: Flatpak must continue checking repository signatures.
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak remote-add --if-not-exists --system $remote $url"
    return 0
  fi

  run_sudo flatpak remote-add --if-not-exists --system -- "$remote" "$url"
}

flatpak_install() {
  local -a missing=()
  local app
  local remote="${FLATPAK_REMOTE:-flathub}"

  if ! package_name_is_valid "$remote"; then
    log_error "Refusing invalid Flatpak remote name: $remote"
    return 1
  fi

  for app in "$@"; do
    if ! package_name_is_valid "$app"; then
      log_error "Refusing invalid Flatpak application name: $app"
      return 1
    fi
    if flatpak_package_installed "$app"; then
      log_debug "Flatpak already installed: $app"
    else
      missing+=("$app")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    log_debug "All requested Flatpak applications are already installed."
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak install --system -y --noninteractive $remote ${missing[*]}"
    return 0
  fi

  run_sudo flatpak install --system -y --noninteractive "$remote" -- "${missing[@]}"
}

flatpak_remove() {
  local app
  for app in "$@"; do
    if ! package_name_is_valid "$app"; then
      log_error "Refusing invalid Flatpak application name: $app"
      return 1
    fi
  done

  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak uninstall --system -y -- $*"
    return 0
  fi
  run_sudo flatpak uninstall --system -y -- "$@"
}

flatpak_update() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_dry "sudo flatpak update --system -y"
    return 0
  fi
  run_sudo flatpak update --system -y
}
