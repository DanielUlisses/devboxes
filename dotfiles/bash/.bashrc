# shellcheck shell=bash
# Devbox shell, from dotfiles/bash in the devboxes repo (stowed by devbox
# bootstrap). Machine-specific additions go in ~/.bashrc.local.
export EDITOR=nvim VISUAL=nvim
# Headless: tools that would open a browser print the URL instead
# (bin/devbox-browser, next to this file's checkout).
BROWSER="$(readlink -f "${BASH_SOURCE[0]}")"
export BROWSER="${BROWSER%/dotfiles/bash/.bashrc}/bin/devbox-browser"
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
if command -v starship >/dev/null; then
  eval "$(starship init bash)"
elif [[ -r /usr/share/git/completion/git-prompt.sh ]]; then
  source /usr/share/git/completion/git-prompt.sh
  PS1='[\u@\h \W$(__git_ps1 " (%s)")]\$ '
else
  PS1='[\u@\h \W]\$ '
fi
# z <dir fragment> jumps to a directory visited before; after the prompt, as
# zoxide's own hook goes last.
command -v zoxide >/dev/null && eval "$(zoxide init bash)"

# agent_user on (devbox sync wrote /etc/tk-agent.conf): inside a ticket
# worktree (~/work/<repo>--<branch>, group tkwork), `claude` is the shim that
# runs it as the agent user. Last in PROMPT_COMMAND, so mise's hook can't
# put its own PATH entries ahead of it.
if [[ -r /etc/tk-agent.conf ]]; then
  __tk_agent_path() {
    local shim=/usr/local/libexec/tk-agent-bin top
    PATH=":$PATH:"
    PATH="${PATH//:$shim:/:}"
    PATH="${PATH#:}"
    PATH="${PATH%:}"
    [[ $PWD == "$HOME/work/"*--* ]] || return 0
    top="${PWD#"$HOME/work/"}"
    top="${top%%/*}"
    [[ $(stat -c %G "$HOME/work/$top" 2>/dev/null) == tkwork ]] && PATH="$shim:$PATH"
    return 0
  }
  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}__tk_agent_path"
fi

# shellcheck source=/dev/null
source ~/.aliases
# shellcheck source=/dev/null
[[ -r ~/.bashrc.local ]] && source ~/.bashrc.local
