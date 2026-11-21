#!/usr/bin/env bash
# Component status reporting for the final installation summary.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_REPORT_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_REPORT_SOURCED=1

REPORT_INSTALLED=()
REPORT_PRESENT=()
REPORT_SKIPPED=()
REPORT_FAILED=()

report_record() {
  local status="${1:-}"
  local name="${2:-}"
  local detail="${3:-}"
  local entry

  [[ -n "$status" && -n "$name" ]] || return 1
  entry="$name"
  [[ -n "$detail" ]] && entry="$name ($detail)"
  case "$status" in
    installed) REPORT_INSTALLED+=("$entry") ;;
    present) REPORT_PRESENT+=("$entry") ;;
    skipped) REPORT_SKIPPED+=("$entry") ;;
    failed) REPORT_FAILED+=("$entry") ;;
    *) return 1 ;;
  esac
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf 'REPORT\t%s\t%s\n' "$status" "$entry" >>"$LOG_FILE"
  fi
}

report_installed() { report_record installed "$@"; }
report_present() { report_record present "$@"; }
report_skipped() { report_record skipped "$@"; }
report_failed() { report_record failed "$@"; }

report_count() {
  case "${1:-}" in
    installed) printf '%s\n' "${#REPORT_INSTALLED[@]}" ;;
    present) printf '%s\n' "${#REPORT_PRESENT[@]}" ;;
    skipped) printf '%s\n' "${#REPORT_SKIPPED[@]}" ;;
    failed) printf '%s\n' "${#REPORT_FAILED[@]}" ;;
    *) printf '0\n' ;;
  esac
}

_report_list() {
  local title="$1"
  shift
  local item
  if (( $# == 0 )); then
    return 0
  fi
  printf '%s (%s):\n' "$title" "$#"
  for item in "$@"; do
    printf '  - %s\n' "$item"
  done
}

report_summary() {
  local installed present skipped failed

  installed="$(report_count installed)"
  present="$(report_count present)"
  skipped="$(report_count skipped)"
  failed="$(report_count failed)"

  printf '\nComponent status:\n'
  printf '  Installed:       %s\n' "$installed"
  printf '  Already present: %s\n' "$present"
  printf '  Skipped:         %s\n' "$skipped"
  printf '  Failed:          %s\n' "$failed"

  if (( failed > 0 )); then
    _report_list "Failed components" "${REPORT_FAILED[@]}"
  fi
  if (( skipped > 0 )); then
    _report_list "Skipped components" "${REPORT_SKIPPED[@]}"
  fi
  if (( installed > 0 )); then
    _report_list "Installed components" "${REPORT_INSTALLED[@]}"
  fi
  if (( present > 0 )); then
    _report_list "Already present" "${REPORT_PRESENT[@]}"
  fi
}
