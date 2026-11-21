#!/usr/bin/env bash
# macOS bootstrap: Homebrew, Bash 5, PATH policy, and the single confirmation.
#
# This file is intentionally compatible with the Bash 3.2 shipped by macOS.
# It is sourced before lib/common.sh, so it must not use Bash 4+ syntax.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_BOOTSTRAP_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_BOOTSTRAP_SOURCED=1

BREW_PREFIX=/opt/homebrew
BREW_BIN="$BREW_PREFIX/bin/brew"
BOOTSTRAP_BASH="$BREW_PREFIX/bin/bash"
BOOTSTRAP_DRY_RUN=0
BOOTSTRAP_ASSUME_YES=0
BOOTSTRAP_PROFILE=""
BOOTSTRAP_MODULES=""

bootstrap_say() {
  printf '%s\n' "$*"
}

bootstrap_error() {
  printf 'system-init: %s\n' "$*" >&2
}

bootstrap_scan_args() {
  local argument
  BOOTSTRAP_DRY_RUN=0
  BOOTSTRAP_ASSUME_YES=0
  BOOTSTRAP_PROFILE=""
  BOOTSTRAP_MODULES=""

  while (( $# > 0 )); do
    argument="$1"
    case "$argument" in
      --dry-run)
        BOOTSTRAP_DRY_RUN=1
        ;;
      --yes|-y|--non-interactive)
        BOOTSTRAP_ASSUME_YES=1
        ;;
      --profile)
        if (( $# >= 2 )); then
          BOOTSTRAP_PROFILE="$2"
          shift
        fi
        ;;
      --profile=*)
        BOOTSTRAP_PROFILE="${argument#--profile=}"
        ;;
      --module)
        if (( $# >= 2 )); then
          BOOTSTRAP_MODULES="$2"
          shift
        fi
        ;;
      --module=*)
        BOOTSTRAP_MODULES="${argument#--module=}"
        ;;
    esac
    shift
  done
}

bootstrap_apply_path() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
  else
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
  fi
  export PATH
}

bootstrap_bash_major() {
  printf '%s\n' "${BASH_VERSINFO[0]:-0}"
}

bootstrap_bash5_present() {
  [[ -x "$BOOTSTRAP_BASH" ]] || return 1
  "$BOOTSTRAP_BASH" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 5 ]]' >/dev/null 2>&1
}

bootstrap_homebrew_present() {
  [[ -x "$BREW_BIN" ]]
}

bootstrap_profile_modules() {
  local profile="$1"
  local module
  local -a modules=()

  case "$profile" in
    core)
      # config/profiles.conf is intentionally simple shell assignments.
      # shellcheck disable=SC1090
      source "$REPO_ROOT/config/profiles.conf"
      read -r -a modules <<<"${CORE_MODULES:-}"
      for module in "${modules[@]}"; do
        [[ -n "$module" ]] && printf '%s\n' "$module"
      done
      ;;
    extended)
      while IFS= read -r module; do
        module="${module%%#*}"
        module="$(printf '%s' "$module" | tr -d '[:space:]')"
        [[ -n "$module" ]] && printf '%s\n' "$module"
      done <"$REPO_ROOT/config/modules.conf"
      ;;
    *)
      return 1
      ;;
  esac
}

bootstrap_selected_modules() {
  local module
  if [[ -n "$BOOTSTRAP_MODULES" ]]; then
    printf '%s\n' "$BOOTSTRAP_MODULES" | tr ',' '\n' | while IFS= read -r module; do
      module="$(printf '%s' "$module" | tr -d '[:space:]')"
      [[ -n "$module" ]] && printf '%s\n' "$module"
    done
    return 0
  fi
  bootstrap_profile_modules "${BOOTSTRAP_PROFILE:-${MACOS_DEFAULT_PROFILE:-extended}}"
}

bootstrap_print_plan() {
  local module line manager package optional count=0
  local profile="${BOOTSTRAP_PROFILE:-${MACOS_DEFAULT_PROFILE:-extended}}"

  bootstrap_say "macOS bootstrap plan"
  bootstrap_say "  Platform: macOS $(sw_vers -productVersion 2>/dev/null || printf unknown) ($(uname -m))"
  bootstrap_say "  Profile:  $profile"
  if [[ -n "$BOOTSTRAP_MODULES" ]]; then
    bootstrap_say "  Modules:  $BOOTSTRAP_MODULES"
  else
    bootstrap_say "  Modules:  $(bootstrap_selected_modules | tr '\n' ' ')"
  fi
  bootstrap_say ""
  bootstrap_say "Prerequisites:"
  if bootstrap_homebrew_present; then
    bootstrap_say "  Homebrew: present at $BREW_PREFIX"
  else
    bootstrap_say "  Homebrew: missing"
    bootstrap_say "    Installer commit: ${HOMEBREW_INSTALL_COMMIT:-<unset>}"
    bootstrap_say "    Installer SHA-256: ${HOMEBREW_INSTALL_SHA256:-<unset>}"
    bootstrap_say "    Verification: pinned commit + GitHub signature + downloaded SHA-256"
  fi
  if bootstrap_bash5_present; then
    bootstrap_say "  Bash 5:   present at $BOOTSTRAP_BASH"
  else
    bootstrap_say "  Bash 5:   missing; will install the Homebrew bash formula"
  fi

  bootstrap_say ""
  bootstrap_say "macOS packages:"
  while IFS= read -r module; do
    [[ -n "$module" ]] || continue
    [[ -f "$REPO_ROOT/modules/$module/packages.macos" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      # shellcheck disable=SC2034 # optional is validated by the manifests
      read -r manager package optional <<<"$line"
      [[ -n "${manager:-}" && -n "${package:-}" ]] || continue
      bootstrap_say "  $manager $package"
      count=$((count + 1))
    done <"$REPO_ROOT/modules/$module/packages.macos"
  done < <(bootstrap_selected_modules)
  bootstrap_say "  ($count package declarations)"
  bootstrap_say "  Alacritty v${ALACRITTY_VERSION:-<unset>} from the pinned official DMG"
  bootstrap_say ""
  bootstrap_say "Podman machine auto-initialization: ${PODMAN_MACHINE_AUTO:-1}"
  bootstrap_say "Dotfiles are backed up before any managed file is replaced."
}

bootstrap_confirm() {
  local answer
  if (( BOOTSTRAP_ASSUME_YES == 1 )); then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    bootstrap_error "No interactive terminal. Re-run with --yes or --non-interactive to proceed."
    return 2
  fi
  printf '\nProceed with this plan? [y/N] '
  if ! read -r answer; then
    printf '\n'
    return 1
  fi
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

bootstrap_verify_homebrew_installer() {
  local commit="${HOMEBREW_INSTALL_COMMIT:-}"
  local expected="${HOMEBREW_INSTALL_SHA256:-}"
  local destination="$1"
  local api_file actual api_sha verified reason

  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
    bootstrap_error "HOMEBREW_INSTALL_COMMIT must be a full 40-hex commit."
    return 1
  }
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    bootstrap_error "HOMEBREW_INSTALL_SHA256 must be a full 64-hex digest."
    return 1
  }
  if [[ ! -x /usr/bin/plutil && ! -x /usr/bin/python3 ]]; then
    bootstrap_error "A JSON parser (plutil or python3) is required to verify the Homebrew installer."
    return 1
  fi

  api_file="$(mktemp "${TMPDIR:-/tmp}/system-init-brew-api.XXXXXXXX")" || return 1
  if ! /usr/bin/curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 \
    "https://api.github.com/repos/Homebrew/install/commits/$commit" \
    -o "$api_file"; then
    rm -f "$api_file"
    bootstrap_error "Could not fetch the pinned Homebrew installer commit metadata."
    return 1
  fi
  # plutil is native to macOS and avoids pulling in Command Line Tools just
  # to parse GitHub's JSON response.
  if [[ -x /usr/bin/plutil ]]; then
    api_sha="$(/usr/bin/plutil -extract sha raw -o - "$api_file" 2>/dev/null || true)"
    verified="$(/usr/bin/plutil -extract commit.verification.verified raw -o - "$api_file" 2>/dev/null || true)"
    reason="$(/usr/bin/plutil -extract commit.verification.reason raw -o - "$api_file" 2>/dev/null || true)"
  else
    api_sha="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sha", ""))' "$api_file" 2>/dev/null || true)"
    verified="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit",{}).get("verification",{}).get("verified", False))' "$api_file" 2>/dev/null || true)"
    reason="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit",{}).get("verification",{}).get("reason", ""))' "$api_file" 2>/dev/null || true)"
  fi
  rm -f "$api_file"

  if [[ "$api_sha" != "$commit" ]]; then
    bootstrap_error "GitHub returned a different commit than the pinned Homebrew installer commit."
    return 1
  fi
  if [[ "$verified" != "True" && "$verified" != "true" ]] || [[ "$reason" != "valid" ]]; then
    bootstrap_error "The pinned Homebrew installer commit is not a valid GitHub-verified signature."
    return 1
  fi

  if ! /usr/bin/curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 \
    "https://raw.githubusercontent.com/Homebrew/install/$commit/install.sh" \
    -o "$destination"; then
    bootstrap_error "Could not download the pinned Homebrew installer."
    return 1
  fi
  actual="$(/usr/bin/shasum -a 256 "$destination" | awk '{ print $1; exit }')"
  if [[ "$actual" != "$expected" ]]; then
    bootstrap_error "Homebrew installer checksum mismatch."
    bootstrap_error "expected: $expected"
    bootstrap_error "actual:   $actual"
    return 1
  fi
  bootstrap_say "  Verified Homebrew installer: $commit"
  bootstrap_say "  SHA-256: $actual"
}

bootstrap_install_homebrew() {
  local installer
  [[ "$(uname -m)" == "arm64" ]] || {
    bootstrap_error "Homebrew bootstrap supports Apple Silicon only."
    return 1
  }
  installer="$(mktemp "${TMPDIR:-/tmp}/system-init-brew-install.XXXXXXXX")" || return 1
  if ! bootstrap_verify_homebrew_installer "$installer"; then
    rm -f "$installer"
    return 1
  fi
  if (( BOOTSTRAP_DRY_RUN == 1 )); then
    rm -f "$installer"
    bootstrap_say "Dry-run: would execute /bin/bash $installer"
    return 0
  fi
  if [[ -t 0 ]] && ! /usr/bin/sudo -n true >/dev/null 2>&1; then
    /usr/bin/sudo -v || { rm -f "$installer"; return 1; }
  fi
  if ! NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 /bin/bash "$installer"; then
    rm -f "$installer"
    bootstrap_error "Homebrew installation failed."
    return 1
  fi
  rm -f "$installer"
  bootstrap_homebrew_present || {
    bootstrap_error "Homebrew installation finished but $BREW_BIN is missing."
    return 1
  }
  export DEV_SETUP_HOMEBREW_INSTALLED=1
}

bootstrap_install_bash() {
  if bootstrap_bash5_present; then
    return 0
  fi
  if (( BOOTSTRAP_DRY_RUN == 1 )); then
    bootstrap_say "Dry-run: would install Homebrew bash."
    return 0
  fi
  HOMEBREW_NO_ANALYTICS=1 \
    "$BREW_BIN" install bash || {
      bootstrap_error "Could not install Homebrew bash."
      return 1
    }
  bootstrap_bash5_present || {
    bootstrap_error "Homebrew bash is not usable at $BOOTSTRAP_BASH."
    return 1
  }
  export DEV_SETUP_BASH_INSTALLED=1
}

bootstrap_run() {
  local need_homebrew=0 need_bash=0

  [[ "$(uname -s)" == "Darwin" ]] || return 0
  if [[ "$(uname -m)" != "arm64" ]]; then
    bootstrap_error "macOS support requires Apple Silicon (arm64); ${PLATFORM_ARCH:-$(uname -m)} is unsupported."
    exit 1
  fi
  local macos_major
  macos_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
  if ! [[ "$macos_major" =~ ^[0-9]+$ ]] || (( macos_major < 27 )); then
    bootstrap_error "macOS 27 or newer is required (found $(sw_vers -productVersion 2>/dev/null || printf unknown))."
    exit 1
  fi
  bootstrap_apply_path
  bootstrap_scan_args "$@"

  if [[ -n "${DEV_SETUP_BASH_REEXEC:-}" ]] && (( $(bootstrap_bash_major) >= 5 )); then
    return 0
  fi

  bootstrap_homebrew_present || need_homebrew=1
  bootstrap_bash5_present || need_bash=1

  # The shared libraries require Bash 5. Re-exec immediately when a usable
  # Homebrew Bash is already present, even if no installation is needed.
  if (( $(bootstrap_bash_major) < 5 )) && bootstrap_bash5_present; then
    export DEV_SETUP_BASH_REEXEC=1
    exec "$BOOTSTRAP_BASH" "$0" "$@"
  fi

  if (( need_homebrew == 0 && need_bash == 0 )); then
    return 0
  fi

  # Read-only commands such as doctor and list must not install prerequisites.
  # Bash 5 is mandatory to source the shared libraries; a missing Homebrew is
  # reported by doctor/list instead of triggering an install.
  if [[ "${DEV_SETUP_BOOTSTRAP_READONLY:-0}" == "1" ]]; then
    if (( need_bash == 1 )); then
      bootstrap_error "Homebrew Bash 5 is required for this read-only command."
      bootstrap_error "Run ./install.sh interactively first, then rerun this command."
      exit 1
    fi
    return 0
  fi

  # settings.conf is simple shell assignments and is safe to read here.
  if [[ -f "$REPO_ROOT/config/settings.conf" ]]; then
    # shellcheck disable=SC1090
    source "$REPO_ROOT/config/settings.conf"
  fi
  if [[ -f "$REPO_ROOT/config/pins.conf" ]]; then
    # shellcheck disable=SC1090
    source "$REPO_ROOT/config/pins.conf"
  fi

  bootstrap_print_plan
  if (( BOOTSTRAP_DRY_RUN == 1 )); then
    bootstrap_say ""
    bootstrap_say "Dry-run complete. No bootstrap changes were made."
    exit 0
  fi
  local confirm_status=0
  bootstrap_confirm || confirm_status=$?
  if (( confirm_status == 2 )); then
    bootstrap_error "Bootstrap aborted."
    exit 1
  elif (( confirm_status != 0 )); then
    bootstrap_say "Cancelled."
    exit 0
  fi

  if (( need_homebrew == 1 )); then
    bootstrap_install_homebrew || exit 1
  fi
  if (( need_bash == 1 )); then
    bootstrap_install_bash || exit 1
  fi

  export DEV_SETUP_BASH_REEXEC=1
  export DEV_SETUP_CONFIRMED=1
  bootstrap_say "Re-executing with $BOOTSTRAP_BASH."
  exec "$BOOTSTRAP_BASH" "$0" "$@"
}
