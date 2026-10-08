# shellcheck shell=bash
# What a Proxmox host's ssh name may be, as a client file's `host` or as
# $DEVBOX_HOST: letters, digits, . _ -, max 253. Sourced, not run; one
# definition for bin/devbox-config (a jq regex) and the bash scripts
# (is_devbox_host_name).
# shellcheck disable=SC2034 # used by the files that source this one
DEVBOX_HOST_RE='^[A-Za-z0-9]([A-Za-z0-9._-]{0,251}[A-Za-z0-9])?$'

# Succeeds when $1 matches $DEVBOX_HOST_RE. Matches in the C locale: under a
# UTF-8 one, bash's [A-Za-z] also takes accented letters.
is_devbox_host_name() {
  local LC_ALL=C
  [[ $1 =~ $DEVBOX_HOST_RE ]]
}
