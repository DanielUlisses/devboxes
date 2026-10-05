# shellcheck shell=bash
# Devbox shell, from dotfiles/bash in the devboxes repo (stowed by devbox
# bootstrap). Machine-specific additions go in ~/.bashrc.local.
export EDITOR=nvim VISUAL=nvim
[[ $- != *i* ]] && return

HISTSIZE=50000
HISTFILESIZE=50000
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend checkwinsize

export PATH="$HOME/.local/bin:$PATH"
command -v mise >/dev/null && eval "$(mise activate bash)"
# The client's 1Password service account, stored by `devbox login`.
if [[ -r ~/.config/op/service-account-token ]]; then
  OP_SERVICE_ACCOUNT_TOKEN="$(<~/.config/op/service-account-token)"
  export OP_SERVICE_ACCOUNT_TOKEN
fi

[[ -r /usr/share/bash-completion/bash_completion ]] && source /usr/share/bash-completion/bash_completion
if [[ -r /usr/share/git/completion/git-prompt.sh ]]; then
  source /usr/share/git/completion/git-prompt.sh
  PS1='[\u@\h \W$(__git_ps1 " (%s)")]\$ '
else
  PS1='[\u@\h \W]\$ '
fi

# shellcheck source=/dev/null
source ~/.aliases
# shellcheck source=/dev/null
[[ -r ~/.bashrc.local ]] && source ~/.bashrc.local
