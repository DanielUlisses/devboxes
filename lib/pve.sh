# shellcheck shell=bash
# Proxmox access shared by the bin/devbox-* scripts. Sourced,
# not run. Every call to the host goes through pve(), which only lets through
# the commands listed there: the host may be shared, so the one host-level
# change, a box's backup job, only runs on a host where every guest is a devbox.

# shellcheck source=lib/host-name.sh
source "$(dirname "${BASH_SOURCE[0]}")/host-name.sh"

# The host every pve() call goes to; scripts acting on one client's box point
# it at that client's `host` with use_config_host.
DEVBOX_HOST="${DEVBOX_HOST:-}"
VMID_MIN=2000
VMID_MAX=2099
DEVBOX_TAG=devbox
BACKUP_STORAGE="${DEVBOX_BACKUP_STORAGE:-local}"

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
    "pvesh get")
      [[ ${3:-} == /cluster/resources || ${3:-} == /cluster/backup ]] ||
        die "refusing 'pvesh get ${3:-}': only /cluster/resources and /cluster/backup are read" ;;
    "pvesh create" | "pvesh set" | "pvesh delete") assert_backup_job_call "$@" ;;
    "pveam list" | "cat /proc/meminfo") ;;
    *) die "refusing to run '$*' on $DEVBOX_HOST: not an allowed command" ;;
  esac
  # ssh joins its arguments into one string for the remote shell; quote them.
  # shellcheck disable=SC2029 # expanding client-side is the point
  ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$DEVBOX_HOST" "$(printf '%q ' "$@")"
}

# Dies unless $DEVBOX_HOST, when set, is a valid host ssh name ($DEVBOX_HOST_RE).
assert_devbox_host_name() {
  [[ -z $DEVBOX_HOST ]] || is_devbox_host_name "$DEVBOX_HOST" ||
    die "DEVBOX_HOST must be the ssh name of a Proxmox host (letters, digits, . _ -), got '$DEVBOX_HOST'"
}

# Points this run at the Proxmox host of resolved config $1 (devbox-config
# --json): its `host`, or $DEVBOX_HOST when that is empty. Dies when neither
# names one; says which host it is.
use_config_host() {
  local config="$1" host hostname
  host="$(jq -r '.host // ""' <<<"$config")" || die "could not read host from the resolved config"
  hostname="$(jq -r .hostname <<<"$config")" || die "could not read hostname from the resolved config"
  [[ -z $host ]] || DEVBOX_HOST="$host"
  [[ -n $DEVBOX_HOST ]] ||
    die "no Proxmox host for $hostname: its client file sets no \`host\` and DEVBOX_HOST is not set (export it to the host's ssh name)"
  [[ -n $host ]] || assert_devbox_host_name
  say "$hostname: targeting Proxmox host $DEVBOX_HOST ($([[ -n $host ]] && echo "the client's host" || echo "DEVBOX_HOST"))"
}

# Dies unless "$@" (pvesh create|set|delete ...) touches only one devbox
# backup job (id devbox-<hostname>), for one VMID in range, with only the
# options devbox sets, on a dedicated host. Anything else could back up, or
# stop backing up, guests that aren't devboxes.
assert_backup_job_call() {
  local verb="$2" path="${3:-}" id="" has_vmid=false allowed opt value i
  case "$verb" in
    create) [[ $path == /cluster/backup ]] || die "refusing 'pvesh create $path': only /cluster/backup jobs are created"
      allowed=" --id --vmid --schedule --storage --mode --compress --prune-backups --enabled --comment " ;;
    set) allowed=" --vmid --schedule --storage --prune-backups --comment " ;;
    delete) allowed=" " ;;
  esac
  [[ $verb == create ]] || id="${path#/cluster/backup/}"
  [[ $verb == create || $path == /cluster/backup/* ]] ||
    die "refusing 'pvesh $verb $path': only /cluster/backup/<job> is changed"
  for ((i = 4; i <= $#; i += 2)); do
    opt="${!i}"
    [[ $allowed == *" $opt "* ]] || die "refusing 'pvesh $verb $path' with option '$opt'"
    ((i < $#)) || die "refusing 'pvesh $verb $path': option '$opt' has no value"
    value="${*:i+1:1}"
    case "$opt" in
      --id) id="$value" ;;
      --vmid) has_vmid=true
        in_range "$value" || die "refusing a backup job for VMID '$value': outside $VMID_MIN-$VMID_MAX" ;;
    esac
  done
  [[ $verb != create ]] || $has_vmid || die "refusing 'pvesh create $path' without --vmid"
  [[ $id =~ ^$DEVBOX_TAG-[a-z0-9-]+$ ]] || die "refusing 'pvesh $verb' on backup job '$id': not a $DEVBOX_TAG job"
  dedicated_host || die "refusing to change backup jobs: $(shared_host_reason)"
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

# Succeeds when every guest on the cluster is a devbox (a container in range,
# tagged devbox): the rule host/setup.sh --apply uses. A host running anything
# else is shared, and gets no host-level changes. Sets NON_DEVBOX_GUESTS.
NON_DEVBOX_GUESTS=""
dedicated_host() {
  local all
  all="$(guests)" || die "could not list the guests on $DEVBOX_HOST"
  NON_DEVBOX_GUESTS="$(jq -r --arg tag "$DEVBOX_TAG" --argjson lo "$VMID_MIN" --argjson hi "$VMID_MAX" '
    [.[] | select((.type == "lxc" and .vmid >= $lo and .vmid <= $hi
                   and ((.tags // "") | [splits("[;, ]")] | index([$tag]))) | not)
         | "\(.type)/\(.vmid)"] | join(" ")' <<<"$all")" || die "could not read the guest list"
  [[ -z $NON_DEVBOX_GUESTS ]]
}

shared_host_reason() {
  printf '%s also runs guests that are not devboxes (%s), so it is shared and gets no host-level changes' \
    "$DEVBOX_HOST" "$NON_DEVBOX_GUESTS"
}

backup_job_id() {
  printf '%s-%s' "$DEVBOX_TAG" "$1"
}

# Prints hostname $1's backup job as JSON, or nothing when there is none.
# Fails, saying why, when the jobs can't be read or a job has its id but not
# devbox's comment: someone else's.
backup_job() {
  local jobs job
  jobs="$(pve pvesh get /cluster/backup --output-format json)" ||
    { say "could not read the backup jobs on $DEVBOX_HOST"; return 1; }
  job="$(jq -c --arg id "$(backup_job_id "$1")" '.[] | select(.id == $id)' <<<"$jobs")" || return 1
  [[ -z $job || $(jq -r '.comment // ""' <<<"$job") == "$DEVBOX_TAG "* ]] || {
    say "backup job $(backup_job_id "$1") has no '$DEVBOX_TAG' comment; not touching it"
    return 1
  }
  printf '%s' "$job"
}

# Converges hostname $1's backup job to config $3 (backup, backup_schedule,
# backup_keep) for VMID $2: creates, updates or deletes it, or with $4 = true
# prints the pvesh command instead. Returns 1, saying why, when the job could
# not be read or changed, such as on a shared host.
sync_backup_job() {
  local hostname="$1" vmid="$2" config="$3" dry_run="${4:-false}"
  local id want schedule keep comment current have cmd=()
  id="$(backup_job_id "$hostname")"
  want="$(jq -r '.backup // false' <<<"$config")"
  schedule="$(jq -r .backup_schedule <<<"$config")"
  keep="$(jq -r .backup_keep <<<"$config")"
  comment="$DEVBOX_TAG $hostname: managed by devboxes, delete with bin/devbox-destroy"
  current="$(backup_job "$hostname")" || return 1

  if [[ $want == true && -z $current ]]; then
    cmd=(pvesh create /cluster/backup --id "$id" --vmid "$vmid" --schedule "$schedule"
      --storage "$BACKUP_STORAGE" --mode snapshot --compress zstd
      --prune-backups "keep-last=$keep" --enabled 1 --comment "$comment")
  elif [[ $want == true ]]; then
    # prune-backups reads back as "keep-last=7" or {"keep-last": 7}.
    have="$(jq -r '[.vmid, .schedule, .storage,
      (.["prune-backups"] | if type == "object" then .["keep-last"]
                            else [(. // "") | capture("keep-last=(?<k>[0-9]+)").k][0] end)]
      | map(. // "" | tostring) | join(" ")' <<<"$current")"
    if [[ $have == "$vmid $schedule $BACKUP_STORAGE $keep" ]]; then
      say "backup job $id is up to date"
      return 0
    fi
    cmd=(pvesh set "/cluster/backup/$id" --vmid "$vmid" --schedule "$schedule"
      --storage "$BACKUP_STORAGE" --prune-backups "keep-last=$keep" --comment "$comment")
  elif [[ -n $current ]]; then
    cmd=(pvesh delete "/cluster/backup/$id")
  else
    return 0
  fi

  if $dry_run; then
    printf '%q ' "${cmd[@]}"
    printf '\n'
    dedicated_host || say "that would be refused: $(shared_host_reason)"
    return 0
  fi
  dedicated_host || { say "not changing backup job $id: $(shared_host_reason)"; return 1; }
  say "backup job $id: ${cmd[1]}"
  pve "${cmd[@]}" >/dev/null || { say "pvesh ${cmd[1]} of backup job $id failed"; return 1; }
}
