# Powerlevel10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Environment
export ZSH="$HOME/.oh-my-zsh"
export EDITOR="nvim"
export VISUAL="nvim"

# User-level binaries
export PATH="$HOME/.local/bin:$PATH"

# Oh My Zsh
ZSH_THEME="powerlevel10k/powerlevel10k"
DISABLE_MAGIC_FUNCTIONS="true"
ENABLE_CORRECTION="false"
COMPLETION_WAITING_DOTS="true"

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

# Autosuggestions
if [[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
fi

# History substring search
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# Syntax highlighting (load last)
if [[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

# Modern directory listing
alias ls='eza --icons'
alias ll='eza -lah --icons --git'

# Useful aliases
alias n='ninja'
alias c='clear'
alias please='sudo'

# Parallel builds
alias make='make -j$(nproc)'
alias ninja='ninja -j$(nproc)'

# Powerlevel10k configuration
[[ -f "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"

# opencode
if [[ -d "$HOME/.opencode/bin" ]]; then
  export PATH="$HOME/.opencode/bin:$PATH"
fi

# Stripe CLI
if [[ -d "$HOME/.stripe/bin" ]]; then
  export PATH="$HOME/.stripe/bin:$PATH"
fi
