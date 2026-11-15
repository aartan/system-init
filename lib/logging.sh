#!/usr/bin/env bash
# Logging helpers for system-init.
# shellcheck shell=bash

if [[ -n "${DEV_SETUP_LOGGING_SOURCED:-}" ]]; then
  return 0
fi
DEV_SETUP_LOGGING_SOURCED=1

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  LOG_COLOR_RESET=$'\033[0m'
  LOG_COLOR_RED=$'\033[31m'
  LOG_COLOR_GREEN=$'\033[32m'
  LOG_COLOR_YELLOW=$'\033[33m'
  LOG_COLOR_BLUE=$'\033[34m'
  LOG_COLOR_CYAN=$'\033[36m'
  LOG_COLOR_BOLD=$'\033[1m'
else
  LOG_COLOR_RESET=""
  LOG_COLOR_RED=""
  LOG_COLOR_GREEN=""
  LOG_COLOR_YELLOW=""
  LOG_COLOR_BLUE=""
  LOG_COLOR_CYAN=""
  LOG_COLOR_BOLD=""
fi

LOG_FILE="${LOG_FILE:-}"

_logging_write() {
  local level="$1"
  local color="$2"
  local message="$3"
  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  printf '%s[%s] %-7s%s %s\n' "$color" "$timestamp" "$level" "$LOG_COLOR_RESET" "$message"
  if [[ -n "$LOG_FILE" ]]; then
    printf '[%s] %-7s %s\n' "$timestamp" "$level" "$message" >>"$LOG_FILE"
  fi
}

log_info() {
  _logging_write "INFO" "$LOG_COLOR_BLUE" "$*"
}

log_success() {
  _logging_write "OK" "$LOG_COLOR_GREEN" "$*"
}

log_warn() {
  _logging_write "WARN" "$LOG_COLOR_YELLOW" "$*" >&2
}

log_error() {
  _logging_write "ERROR" "$LOG_COLOR_RED" "$*" >&2
}

log_dry() {
  _logging_write "DRY-RUN" "$LOG_COLOR_CYAN" "$*"
}

log_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    _logging_write "DEBUG" "$LOG_COLOR_CYAN" "$*" >&2
  fi
}

log_section() {
  printf '\n%s==> %s%s\n' "$LOG_COLOR_BOLD" "$*" "$LOG_COLOR_RESET"
  if [[ -n "$LOG_FILE" ]]; then
    printf '\n==> %s\n' "$*" >>"$LOG_FILE"
  fi
}

log_cmd() {
  local item
  local rendered=""
  for item in "$@"; do
    rendered+="$(printf '%q' "$item") "
  done
  printf '%s\n' "${rendered% }"
}

logging_init() {
  if [[ -n "$LOG_FILE" ]]; then
    local requested_log="$LOG_FILE"
    LOG_FILE=""
    if ! printf '' | write_private_file "$requested_log"; then
      log_error "Refusing to create the log file at an unsafe path: $requested_log"
      return 1
    fi
    LOG_FILE="$requested_log"
  fi
}
