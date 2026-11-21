# macOS and Fedora shared zsh configuration.
# Oh My Zsh provides plugins; Powerlevel10k is the prompt on both platforms.

if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Environment
export ZSH="$HOME/.oh-my-zsh"
export EDITOR="nvim"
export VISUAL="nvim"

# Homebrew and user-level binaries
if [[ "$OSTYPE" == darwin* ]] && [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
export PATH="$HOME/.local/bin:$PATH"

if [[ "$OSTYPE" == darwin* ]]; then
  # Keg-only OpenSSL 3 and Postgres.app command-line tools.
  if command -v brew >/dev/null 2>&1; then
    _system_init_openssl_prefix="$(brew --prefix openssl@3 2>/dev/null)"
    [[ -n "$_system_init_openssl_prefix" ]] && export PATH="$_system_init_openssl_prefix/bin:$PATH"
    unset _system_init_openssl_prefix
  fi
  if [[ -d /opt/homebrew/opt/make/libexec/gnubin ]]; then
    export PATH="/opt/homebrew/opt/make/libexec/gnubin:$PATH"
  fi
  if [[ -d /Applications/Postgres.app/Contents/Versions/latest/bin ]]; then
    export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"
  fi
fi

# Oh My Zsh
ZSH_THEME="powerlevel10k/powerlevel10k"
DISABLE_MAGIC_FUNCTIONS="true"
ENABLE_CORRECTION="false"
COMPLETION_WAITING_DOTS="true"

# zsh-autosuggestions and zsh-syntax-highlighting are sourced explicitly
# below, so they must not also be listed as Oh My Zsh plugins.
plugins=(
  git
  fzf
  extract
  history-substring-search
)

source "$ZSH/oh-my-zsh.sh"

# mise-managed runtimes
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh)"
fi

# History
HISTSIZE=50000
SAVEHIST=50000
HISTFILE="$HOME/.zsh_history"

setopt HIST_IGNORE_DUPS
setopt HIST_SAVE_NO_DUPS
setopt SHARE_HISTORY

export HISTORY_IGNORE="(&|[bf]g|c|clear|history|exit|q|pwd|* --help)"

# Print the canonical plugin path for this platform.
_system_init_zsh_plugin_path() {
  local name="$1"

  if [[ "$OSTYPE" == darwin* ]]; then
    if command -v brew >/dev/null 2>&1; then
      printf '%s\n' "$(brew --prefix)/share/$name/$name.zsh"
    fi
  else
    printf '%s\n' "/usr/share/$name/$name.zsh"
  fi
}

# Autosuggestions before the prompt so it can wrap the line editor.
_system_init_zsh_autosuggestions="$(_system_init_zsh_plugin_path zsh-autosuggestions)"
if [[ -f "$_system_init_zsh_autosuggestions" ]]; then
  source "$_system_init_zsh_autosuggestions"
fi
unset _system_init_zsh_autosuggestions

# History substring search
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# Powerlevel10k configuration (same file on Fedora and macOS).
[[ -f "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"

# Modern directory listing
alias ls='eza --icons'
alias ll='eza -lah --icons --git'

# Useful aliases
alias n='ninja'
alias c='clear'
alias please='sudo'

# Parallel builds (nproc is Linux-only)
if [[ "$OSTYPE" == darwin* ]]; then
  alias make='make -j$(sysctl -n hw.ncpu)'
  alias ninja='ninja -j$(sysctl -n hw.ncpu)'
else
  alias make='make -j$(nproc)'
  alias ninja='ninja -j$(nproc)'
fi

# opencode
if [[ -d "$HOME/.opencode/bin" ]]; then
  export PATH="$HOME/.opencode/bin:$PATH"
fi

# Stripe CLI
if [[ -d "$HOME/.stripe/bin" ]]; then
  export PATH="$HOME/.stripe/bin:$PATH"
fi

# Syntax highlighting must be loaded last.
_system_init_zsh_syntax_highlighting="$(_system_init_zsh_plugin_path zsh-syntax-highlighting)"
if [[ -f "$_system_init_zsh_syntax_highlighting" ]]; then
  source "$_system_init_zsh_syntax_highlighting"
fi
unset _system_init_zsh_syntax_highlighting
unset -f _system_init_zsh_plugin_path
