#!/usr/bin/env bash
# List system-init modules, packages, and dotfiles.
set -Eeuo pipefail

if (( EUID == 0 )); then
  printf 'system-init: refusing to run as root. Run this as your normal user; sudo is requested only when needed.\n' >&2
  exit 1
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_ROOT

# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/platform.sh
source "$REPO_ROOT/lib/platform.sh"
# shellcheck source=../lib/packages.sh
source "$REPO_ROOT/lib/packages.sh"
# shellcheck source=../lib/modules.sh
source "$REPO_ROOT/lib/modules.sh"
# shellcheck source=../lib/dotfiles.sh
source "$REPO_ROOT/lib/dotfiles.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/list.sh [OPTIONS]

Options:
  --module NAME   Show packages and dotfiles for NAME and its dependencies.
  -h, --help      Show this help.
EOF
}

REQUESTED=()

while (( $# > 0 )); do
  case "$1" in
    --module)
      if (( $# < 2 )); then
        log_error "--module requires a name."
        exit 2
      fi
      shift
      REQUESTED+=("$1")
      ;;
    --module=*)
      REQUESTED+=("${1#--module=}")
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
modules_resolve "${REQUESTED[@]}" || exit 2

printf 'Platform: %s (%s)\n\n' "$PLATFORM_NAME" "$PLATFORM_ARCH"
modules_list

if (( ${#REQUESTED[@]} > 0 )); then
  printf '\n'
  for module in "${SELECTED_MODULES[@]}"; do
    log_section "Module: $module"
    printf '%s\n' "$(module_description_or_default "$module")"
    printf '\nPackages (%s):\n' "$PLATFORM"
    packages_list_module "$module" || true
    printf '\nDotfiles:\n'
    dotfiles_entries | awk -F'\t' -v m="$module" '$1 == m { printf "  %s -> ~/%s\n", $3, $4 }'
  done
fi
