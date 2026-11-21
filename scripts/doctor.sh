#!/usr/bin/env bash
# Read-only workstation health check.
set -Eeuo pipefail

if (( EUID == 0 )); then
  printf 'system-init: refusing to run as root. Run this as your normal user; sudo is requested only when needed.\n' >&2
  exit 1
fi

# Resolve privileged commands only from trusted system directories. macOS
# applies its validated Homebrew PATH in lib/bootstrap.sh instead.
if [[ "$(uname -s)" != "Darwin" ]]; then
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_ROOT

# shellcheck source=../lib/bootstrap.sh
source "$REPO_ROOT/lib/bootstrap.sh"
export DEV_SETUP_BOOTSTRAP_READONLY=1
bootstrap_run "$@"

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
# shellcheck source=../lib/backups.sh
source "$REPO_ROOT/lib/backups.sh"
# shellcheck source=installers/dnf.sh
source "$REPO_ROOT/installers/dnf.sh"
# shellcheck source=installers/flatpak.sh
source "$REPO_ROOT/installers/flatpak.sh"
# shellcheck source=installers/brew.sh
source "$REPO_ROOT/installers/brew.sh"
# shellcheck source=installers/alacritty.sh
source "$REPO_ROOT/installers/alacritty.sh"
# shellcheck source=installers/mise.sh
source "$REPO_ROOT/installers/mise.sh"
# shellcheck source=installers/fonts.sh
source "$REPO_ROOT/installers/fonts.sh"

# shellcheck disable=SC2034
CURRENT_MODULE="doctor"

usage() {
  cat <<'EOF'
Usage: ./scripts/doctor.sh [--help]

Run read-only checks for platform support, packages, services, dotfiles,
runtimes, fonts, shell startup, backups, and accidental secrets.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ok() {
  log_success "$*"
}

fail() {
  record_failure "$*"
}

warn() {
  record_warning "$*"
}

platform_detect
platform_load || exit 1
modules_resolve || exit 2

log_section "system-init doctor"
log_info "Platform: $PLATFORM_NAME ($PLATFORM_ARCH)"
log_info "Target home: $TARGET_HOME"

platform_validate || true

if [[ "$PLATFORM" == "macos" ]]; then
  ok "macOS package and user configuration operations do not require sudo."
elif sudo_binary_valid && "$SUDO_BIN" -n true >/dev/null 2>&1; then
  ok "Passwordless sudo is available."
else
  warn "sudo requires a password or $SUDO_BIN is unavailable; package operations must be run interactively."
fi

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
log_section "Declared packages"
missing_required=0
missing_optional=0
installed_count=0

while IFS= read -r module; do
  file="$(packages_module_file "$module")"
  [[ -f "$file" ]] || continue
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    read -r manager package optional <<<"$line"
    [[ -z "${manager:-}" || -z "${package:-}" ]] && continue

    present=1
    case "$manager" in
      dnf)
        rpm -q --whatprovides -- "$package" >/dev/null 2>&1 && present=0
        ;;
      flatpak)
        flatpak info --system -- "$package" >/dev/null 2>&1 && present=0
        ;;
      brew)
        brew list --formula "$package" >/dev/null 2>&1 && present=0
        ;;
      cask)
        brew list --cask "$package" >/dev/null 2>&1 && present=0
        ;;
      *)
        present=1
        ;;
    esac

    if (( present == 0 )); then
      installed_count=$((installed_count + 1))
    elif [[ "${optional:-}" == "optional" ]]; then
      missing_optional=$((missing_optional + 1))
      log_debug "Optional package missing: $package"
    else
      missing_required=$((missing_required + 1))
      fail "Required package missing: $package"
    fi
  done <"$file"
done < <(modules_all)

if (( missing_required == 0 )); then
  ok "All required declared packages are installed ($installed_count present)."
fi
if (( missing_optional > 0 )); then
  warn "$missing_optional optional application(s) are not installed."
fi

# ---------------------------------------------------------------------------
# Dotfiles
# ---------------------------------------------------------------------------
log_section "Dotfiles"
if dotfiles_check_status; then
  ok "All selected dotfiles are installed and point at this repository."
else
  fail "One or more dotfiles are missing or unmanaged."
fi

# ---------------------------------------------------------------------------
# Shell frameworks
# ---------------------------------------------------------------------------
log_section "Shell"
if have_command zsh; then
  ok "zsh is installed: $(zsh --version)"

  if ! target_user_is_valid "$TARGET_USER"; then
    fail "Invalid target user name: ${TARGET_USER:-<empty>}"
  else
    login_shell="$(user_login_shell "$TARGET_USER" 2>/dev/null || true)"
    if [[ "$PLATFORM" == "macos" ]]; then
      zsh_path=/bin/zsh
    else
      zsh_path="$(command -v zsh)"
    fi
    if [[ "$login_shell" == "$zsh_path" ]]; then
      ok "Login shell for $TARGET_USER is $zsh_path."
    else
      fail "Login shell for $TARGET_USER is ${login_shell:-unknown}, expected $zsh_path."
    fi
  fi
else
  fail "zsh is not installed."
fi

# Read-only Git inspection through the shared safe wrapper.
doctor_git() {
  git_safe "$@"
}

check_checkout() {
  local path="$1"
  local expected="$2"
  local name="$3"
  local actual status
  if [[ ! -d "$path/.git" || -L "$path" || -L "$path/.git" ]]; then
    fail "$name is not installed at $path (missing checkout or symlinked path)"
    return
  fi
  if ! git_checkout_owned_by_user "$path"; then
    fail "$name at $path is not owned by the current user."
    return
  fi
  actual="$(doctor_git -C "$path" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    fail "$name is at ${actual:0:7}, not the pinned ${expected:0:7}."
    return
  fi
  if ! status="$(doctor_git -C "$path" status --porcelain --untracked-files=normal 2>/dev/null)"; then
    fail "Could not inspect the working tree for $name at $path."
    return
  fi
  if [[ -n "$status" ]]; then
    fail "$name has local modifications at $path."
    return
  fi
  ok "$name is at the pinned commit ${expected:0:7} with a clean working tree."
}

check_checkout "$TARGET_HOME/.oh-my-zsh" "$OH_MY_ZSH_COMMIT" "Oh My Zsh"
check_checkout "$TARGET_HOME/.oh-my-zsh/custom/themes/powerlevel10k" "$P10K_COMMIT" "Powerlevel10k"
check_checkout "$TARGET_HOME/.oh-my-zsh/custom/plugins/history-substring-search" "$HISTORY_SUBSTRING_COMMIT" "history-substring-search"

# Parse managed startup files without executing user code. Doctor must remain
# read-only and must never source arbitrary shell startup content.
startup_ok=1
for startup_file in "$TARGET_HOME/.zshrc" "$TARGET_HOME/.p10k.zsh"; do
  [[ -f "$startup_file" ]] || continue
  if ! zsh -n "$startup_file" >/dev/null 2>&1; then
    fail "Shell syntax error in $startup_file."
    startup_ok=0
  fi
done
if (( startup_ok == 1 )); then
  ok "Managed zsh startup files parse successfully."
fi

# ---------------------------------------------------------------------------
# Runtimes
# ---------------------------------------------------------------------------
log_section "Runtimes"
if [[ -x "$MISE_BIN" ]]; then
  ok "mise is installed: $(mise_installed_version)"
  mise_verify_runtimes_readonly || true
else
  fail "mise is not installed at $MISE_BIN"
fi

if HOME="$TARGET_HOME" git config --global filter.lfs.clean >/dev/null 2>&1; then
  if have_command git-lfs; then
    ok "git-lfs is installed and configured."
  else
    fail "Git LFS filters are configured but git-lfs is missing."
  fi
else
  warn "Git LFS filters are not configured in the global Git config."
fi

# ---------------------------------------------------------------------------
# Fonts and terminal
# ---------------------------------------------------------------------------
log_section "Terminal and fonts"
if fonts_verify_installed; then
  ok "JetBrainsMono Nerd Font v${NERD_FONTS_VERSION} is installed."
else
  fail "JetBrainsMono Nerd Font is missing or does not match the pinned checksum."
fi

if [[ "$PLATFORM" != "macos" ]] && have_command fc-match; then
  if fc-match "JetBrainsMono Nerd Font" | grep -q "JetBrainsMono Nerd Font"; then
    ok "fontconfig resolves JetBrainsMono Nerd Font."
  else
    warn "fontconfig does not currently resolve JetBrainsMono Nerd Font."
  fi
fi

if [[ "$PLATFORM" == "macos" ]]; then
  if alacritty_verify_installed; then
    ok "Alacritty $ALACRITTY_VERSION is installed."
  else
    fail "Alacritty $ALACRITTY_VERSION is not installed."
  fi
fi

if [[ -f "$TARGET_HOME/.config/alacritty/alacritty.toml" ]]; then
  ok "Alacritty configuration is present."
else
  fail "Alacritty configuration is missing."
fi

# ---------------------------------------------------------------------------
# Databases
# ---------------------------------------------------------------------------
log_section "Databases"
if [[ "$ENABLE_DATABASE_SERVICES" == "1" ]]; then
  if [[ "$PLATFORM" == "macos" ]]; then
    if [[ -d /Applications/Postgres.app ]]; then
      if [[ -x /Applications/Postgres.app/Contents/Versions/latest/bin/pg_isready ]] \
        && /Applications/Postgres.app/Contents/Versions/latest/bin/pg_isready -q >/dev/null 2>&1; then
        ok "Postgres.app is accepting connections."
      else
        fail "Postgres.app is installed but PostgreSQL is not accepting connections."
      fi
    else
      fail "Postgres.app is not installed."
    fi
    if macos_brew_service_started valkey; then
      ok "Valkey is running as a Homebrew service."
    else
      fail "Valkey is not running as a Homebrew service."
    fi
  else
    for unit in postgresql.service valkey.service; do
      if systemctl is-enabled "$unit" >/dev/null 2>&1; then
        ok "$unit is enabled."
      else
        fail "$unit is not enabled."
      fi
      if systemctl is-active "$unit" >/dev/null 2>&1; then
        ok "$unit is active."
      else
        fail "$unit is not active."
      fi
    done
  fi
else
  warn "Database service management is disabled in config/settings.conf."
fi

# ---------------------------------------------------------------------------
# Virtualization
# ---------------------------------------------------------------------------
log_section "Virtualization"
if [[ "$ENABLE_VIRTUALIZATION_SERVICES" == "1" ]]; then
  if [[ "$PLATFORM" == "macos" ]]; then
    if [[ "$(sysctl -n kern.hv_support 2>/dev/null || printf '0')" == "1" ]]; then
      ok "Apple Hypervisor framework is available."
    else
      warn "Apple Hypervisor framework is unavailable."
    fi
    if [[ -d /Applications/UTM.app ]]; then
      ok "UTM is installed."
    else
      fail "UTM is not installed."
    fi
  else
    if [[ -e /dev/kvm ]]; then
      ok "/dev/kvm is available."
    else
      warn "/dev/kvm is missing; KVM acceleration is unavailable."
    fi

    for unit in virtqemud.socket virtnetworkd.socket virtstoraged.socket virtlogd.socket; do
      if systemctl is-active "$unit" >/dev/null 2>&1; then
        ok "$unit is active."
      else
        fail "$unit is not active."
      fi
    done

    if have_command virsh; then
      ok "virsh is installed."
    else
      fail "virsh is not installed."
    fi
  fi
else
  warn "Virtualization service management is disabled in config/settings.conf."
fi

# ---------------------------------------------------------------------------
# macOS integration
# ---------------------------------------------------------------------------
if [[ "$PLATFORM" == "macos" ]]; then
  log_section "macOS integration"
  if [[ -x "$BREW_BIN" ]] && [[ "$("$BREW_BIN" --prefix 2>/dev/null)" == "$BREW_PREFIX" ]]; then
    ok "Homebrew is installed at $BREW_PREFIX."
  else
    fail "Homebrew is missing or not at $BREW_PREFIX."
  fi
  if [[ -x "$BOOTSTRAP_BASH" ]] \
    && "$BOOTSTRAP_BASH" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 5 ]]' >/dev/null 2>&1; then
    ok "Homebrew Bash 5 is available."
  else
    fail "Homebrew Bash 5 is missing at $BOOTSTRAP_BASH."
  fi

  if have_command podman; then
    if podman machine list --format '{{.Name}} {{.Running}}' 2>/dev/null \
      | awk '$2 == "true" { found = 1 } END { exit(found ? 0 : 1) }'; then
      ok "A Podman machine is running."
    elif [[ "${PODMAN_MACHINE_AUTO:-1}" == "1" ]]; then
      fail "No Podman machine is running; run ./install.sh or start one with podman machine start."
    else
      warn "No Podman machine is running and automatic setup is disabled."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Flatpak and backups
# ---------------------------------------------------------------------------
log_section "Flatpak and backups"
if packages_selected_managers | grep -Fxq flatpak; then
  if flatpak_remote_url_matches "$FLATPAK_REMOTE" "$FLATPAK_REPO_URL"; then
    ok "Flatpak remote '$FLATPAK_REMOTE' is configured with the expected URL."
  else
    fail "Flatpak remote '$FLATPAK_REMOTE' is missing or has an unexpected URL."
    flatpak_actual_url="$(flatpak_system_remote_url "$FLATPAK_REMOTE" 2>/dev/null || true)"
    log_error "Expected: $FLATPAK_REPO_URL"
    log_error "Detected: ${flatpak_actual_url:-<missing>}"
  fi
fi

if [[ -f "$STATE_DIR/install.in-progress" ]]; then
  fail "An install-in-progress marker exists: $STATE_DIR/install.in-progress"
else
  ok "No interrupted installation marker is present."
fi

if [[ -d "$BACKUP_DIR" ]] && backup_latest | grep -q .; then
  ok "Most recent backup snapshot: $(backup_latest)"
else
  warn "No backup snapshots exist yet."
fi

# ---------------------------------------------------------------------------
# Secret scan
# ---------------------------------------------------------------------------
log_section "Repository secret scan"
secret_pattern='-----BEGIN [A-Z ]*PRIVATE KEY-----|postgres(ql)?://[^[:space:]]+:[^[:space:]@]+@|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{32,}|xox[baprs]-[A-Za-z0-9-]{10,}'
secret_hits=""

if doctor_git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  secret_hits="$(doctor_git -C "$REPO_ROOT" grep -IlE -e "$secret_pattern" -- . 2>/dev/null || true)"
else
  secret_hits="$(grep -rIlE --exclude-dir=.git -e "$secret_pattern" "$REPO_ROOT" 2>/dev/null || true)"
fi

if [[ -n "$secret_hits" ]]; then
  fail "Potential secrets found in repository files:"
  while IFS= read -r hit; do
    printf '  - %s\n' "$hit"
  done <<<"$secret_hits"
else
  ok "No credential-like patterns found in repository content."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n'
log_section "Doctor summary"
if (( ${#FAILED_ITEMS[@]} > 0 )); then
  log_error "${#FAILED_ITEMS[@]} check(s) failed:"
  for item in "${FAILED_ITEMS[@]}"; do
    printf '  - %s\n' "$item"
  done
fi
if (( ${#WARNED_ITEMS[@]} > 0 )); then
  log_warn "${#WARNED_ITEMS[@]} warning(s):"
  for item in "${WARNED_ITEMS[@]}"; do
    printf '  - %s\n' "$item"
  done
fi

if (( ${#FAILED_ITEMS[@]} > 0 )); then
  exit 1
fi

log_success "Doctor checks passed."
