# shellcheck shell=bash
# Proxmox access shared by the bin/devbox-* scripts. Sourced,
# not run. Every call to the host goes through pve(), which only lets through
# the commands listed there: the host is shared, so no host-level changes.

DEVBOX_HOST="${DEVBOX_HOST:-}"
VMID_MIN=2000
VMID_MAX=2099
DEVBOX_TAG=devbox

die() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
  exit 1
}

say() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
}

in_range() {
  [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= VMID_MIN && 10#$1 <= VMID_MAX))
}

# Runs one command on the host as root, refusing anything outside the
# allowlist and any pct call on a VMID outside VMID_MIN..VMID_MAX.
pve() {
  [[ -n $DEVBOX_HOST ]] || die "DEVBOX_HOST is not set: export it to the Proxmox host's name (it is kept out of this public repo)"
  case "$1 ${2:-}" in
    "pct list") ;;
    "pct create" | "pct start" | "pct stop" | "pct destroy" | "pct exec" | "pct config" | "pct status")
      in_range "${3:-}" || die "refusing 'pct $2' on VMID '${3:-}': outside $VMID_MIN-$VMID_MAX" ;;
    "pvesh get") [[ ${3:-} == /cluster/resources ]] || die "refusing 'pvesh get ${3:-}': only /cluster/resources is read" ;;
    "pveam list" | "cat /proc/meminfo") ;;
    *) die "refusing to run '$*' on $DEVBOX_HOST: not an allowed command" ;;
  esac
  # ssh joins its arguments into one string for the remote shell; quote them.
  # shellcheck disable=SC2029 # expanding client-side is the point
  ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$DEVBOX_HOST" "$(printf '%q ' "$@")"
}

# JSON array of every guest (VMs and containers) on the cluster.
guests() {
  pve pvesh get /cluster/resources --type vm --output-format json
}

# Fails unless VMID $1 is a container in range, tagged devbox, whose hostname
# is $2. Reads its live config, so a stale guest listing can't slip through.
assert_devbox() {
  local vmid="$1" hostname="$2" config
  in_range "$vmid" || die "VMID $vmid is outside $VMID_MIN-$VMID_MAX; not touching it"
  config="$(pve pct config "$vmid")" || die "could not read config of VMID $vmid"
  grep -qxF "hostname: $hostname" <<<"$config" ||
    die "VMID $vmid's hostname is not $hostname; not touching it"
  grep '^tags:' <<<"$config" | sed 's/^tags: *//' | tr ';, ' '\n' | grep -qxF "$DEVBOX_TAG" ||
    die "VMID $vmid is not tagged $DEVBOX_TAG; not touching it"
}

# Guests named $h that are devbox containers ("ours") and those that aren't.
# shellcheck disable=SC2016 # jq program, not shell expansions
DEVBOX_GUESTS_JQ='
[.[] | select(.name == $h)]
| map(select(.type == "lxc" and .vmid >= $lo and .vmid <= $hi
             and ((.tags // "") | [splits("[;, ]")] | index([$tag]))))  as $ours
| {ours: [$ours[].vmid], others: [.[] | select(IN($ours[]) | not) | "\(.type)/\(.vmid)"]}
'

# Prints the VMID of the devbox container named $1, or nothing when there is
# none. Fails when the name also belongs to another guest, or to several.
# Called in $(...), where set -e doesn't reach, so each step checks itself.
find_devbox() {
  local hostname="$1" split ours others
  split="$(guests | jq -c --arg h "$hostname" --arg tag "$DEVBOX_TAG" \
    --argjson lo "$VMID_MIN" --argjson hi "$VMID_MAX" "$DEVBOX_GUESTS_JQ")" || exit 1 # pve or jq said why
  ours="$(jq -r '.ours | join(" ")' <<<"$split")"
  others="$(jq -r '.others | join(" ")' <<<"$split")"
  [[ -z $others ]] ||
    die "refusing: $hostname also names $others, not a $DEVBOX_TAG container in $VMID_MIN-$VMID_MAX"
  [[ $ours != *" "* ]] || die "refusing: several containers named $hostname: $ours"
  printf '%s' "$ours"
}
