#!/usr/bin/env bash
# Prepare the dedicated Proxmox VE 9 host for devboxes. Runs on the host, as
# root. --dry-run (the default) prints every change without making it; --apply
# makes them. Each step checks the current state first, so re-running --apply
# only does what is still missing.
set -euo pipefail

SUITE=trixie # Debian release under Proxmox VE 9
ZFS_ARC_MAX=$((2 * 1024 * 1024 * 1024))
TEMPLATE_STORAGE=local
TAILNET_CIDR=100.64.0.0/10
# The kernel's LSM order on stock Proxmox VE 9, used when neither the boot
# config nor /sys/kernel/security/lsm says otherwise.
STOCK_LSM=lockdown,capability,yama,apparmor,ima,evm

APPLY=0
SSH_KEY_FILE=""
PVE=0      # running on a Proxmox VE host
CHANGED=0  # whether the last ensure_file call changed (or would change) its file
CHANGES=0
PROBLEMS=0
REBOOT=0   # Landlock is set at boot but not running yet

# The whole datacenter firewall config. Inbound traffic is dropped unless it
# comes over Tailscale. Proxmox opens SSH and the web UI to "local_network"
# on its own; pointing that alias at the tailnet keeps the LAN and WAN out.
# Tailscale still connects: its outbound traffic and the replies are allowed.
CLUSTER_FW="# Managed by devboxes host/setup.sh; re-running it overwrites manual edits.
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[ALIASES]
local_network $TAILNET_CIDR

[RULES]
IN ACCEPT -i tailscale0 -log nolog"

SSHD_CONF="# Managed by devboxes host/setup.sh: root logs in with a key only.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no"

usage() {
  cat <<EOF
Usage: setup.sh [--dry-run|--apply] [--ssh-key <file>]

Prepare this machine, a fresh Proxmox VE 9 install, as the devbox host:
no-subscription repo, thin container storage (ZFS ARC capped at 2 GB), the
Landlock LSM (for pacman's download sandbox in Arch boxes), root SSH key,
Tailscale, a firewall that only lets the tailnet in, and the Arch Linux LXC
template. Runs on the host, as root.

  --dry-run         print each change without making it (the default)
  --apply           make the changes; refused on a host already running
                    guests that aren't devboxes
  --ssh-key <file>  public key(s) to add to root's authorized_keys

Environment:
  TS_AUTHKEY        Tailscale auth key, for 'tailscale up' without a login URL
EOF
}

die() {
  printf 'setup.sh: %s\n' "$*" >&2
  exit 1
}

step() { printf '\n== %s\n' "$*"; }
ok() { printf '  ok: %s\n' "$*"; }
note() { printf '  note: %s\n' "$*"; }
skip() { printf '  skip: %s\n' "$*"; }
problem() {
  PROBLEMS=$((PROBLEMS + 1))
  printf '  PROBLEM: %s\n' "$*"
}

# change <description> <command...>: run the command, or with --dry-run print
# what it would do. Commands that are this script's own functions print only
# the description.
change() {
  local what="$1"
  shift
  CHANGES=$((CHANGES + 1))
  if ((APPLY)); then
    printf '  change: %s\n' "$what"
    "$@"
  else
    printf '  would: %s\n' "$what"
    if [[ $(type -t "$1") == file ]]; then
      printf '    $'
      printf ' %q' "$@"
      printf '\n'
    fi
  fi
}

# ensure_file <path> <content>: make <path> hold exactly <content>. Sets
# CHANGED. With --dry-run, prints the diff instead.
ensure_file() {
  local path="$1" want="$2" have=""
  CHANGED=0
  [[ -r $path ]] && have="$(cat "$path")"
  if [[ -e $path && $have == "$want" ]]; then
    ok "$path"
    return
  fi
  CHANGED=1
  CHANGES=$((CHANGES + 1))
  if ((APPLY)); then
    printf '  change: write %s\n' "$path"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$want" >"$path"
  else
    printf '  would: write %s\n' "$path"
    diff -u --label "$path" --label "$path (wanted)" \
      <([[ -e $path ]] && printf '%s\n' "$have") <(printf '%s\n' "$want") |
      sed 's/^/    /' || true
  fi
}

# append_line <file> <line>: add a line, following symlinks rather than
# replacing them.
append_line() {
  [[ -d ${1%/*} ]] || mkdir -m 700 "${1%/*}"
  if [[ -s $1 && -n $(tail -c1 "$1") ]]; then printf '\n' >>"$1"; fi
  printf '%s\n' "$2" >>"$1"
}

apt_install() {
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"
}

# A host already running guests that aren't devboxes is shared with other
# services, and gets no host-level changes. A devbox is a container in VMID
# 2000-2099 tagged devbox; a freshly installed dedicated host has no guests.
is_shared_host() {
  local conf vmid
  for conf in /etc/pve/lxc/*.conf /etc/pve/qemu-server/*.conf; do
    [[ -e $conf ]] || continue
    vmid="${conf##*/}"
    vmid="${vmid%.conf}"
    [[ $conf == /etc/pve/lxc/* ]] && ((vmid >= 2000 && vmid <= 2099)) &&
      sed -n 's/^tags: *//p' "$conf" | tr ';, ' '\n' | grep -qxF devbox &&
      continue
    return 0
  done
  return 1
}

# deb822 sources files: add or set "Enabled: no" in every stanza.
disable_sources() {
  if grep -qi '^Enabled:' "$1"; then
    sed -i 's/^Enabled:.*/Enabled: no/I' "$1"
  else
    sed -i 's/^Types:.*/&\nEnabled: no/' "$1"
  fi
}

setup_repos() {
  step "Package repositories"
  local f any=0
  for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    [[ -f $f ]] || continue
    if ! grep -q 'enterprise\.proxmox\.com' "$f"; then
      ok "$f is not an enterprise repo"
    elif grep -qiE '^Enabled:[[:space:]]*(no|false)' "$f"; then
      ok "$f disabled"
    else
      change "disable the enterprise repo in $f (it needs a subscription)" disable_sources "$f"
      any=1
    fi
  done

  ensure_file /etc/apt/sources.list.d/proxmox.sources "Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $SUITE
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg"
  ((CHANGED)) && any=1

  local keyring=/usr/share/keyrings/tailscale-archive-keyring.gpg
  if [[ -s $keyring ]]; then
    ok "$keyring"
  else
    change "fetch the Tailscale apt signing key" \
      curl -fsSL -o "$keyring" "https://pkgs.tailscale.com/stable/debian/$SUITE.noarmor.gpg"
    any=1
  fi
  ensure_file /etc/apt/sources.list.d/tailscale.list \
    "deb [signed-by=$keyring] https://pkgs.tailscale.com/stable/debian $SUITE main"
  ((CHANGED)) && any=1

  if ((any)); then change "refresh the package lists" apt-get update -q; fi
}

set_arc_max() { printf '%s\n' "$ZFS_ARC_MAX" >"$1"; }

setup_storage() {
  step "Container storage"
  if ((PVE)); then
    local thin
    thin="$(pvesm status --content rootdir 2>/dev/null |
      awk 'NR > 1 && ($2 == "lvmthin" || $2 == "zfspool") && $3 == "active" {print $1 " (" $2 ")"}')"
    if [[ -n $thin ]]; then
      ok "thin storage for containers: ${thin//$'\n'/, }"
    else
      problem "no active LVM-thin or ZFS storage for containers; reinstall with ext4 (LVM-thin) or ZFS"
    fi
  else
    skip "checking for LVM-thin or ZFS storage needs Proxmox (pvesm)"
  fi

  if ! command -v zpool >/dev/null || [[ -z $(zpool list -H -o name 2>/dev/null) ]]; then
    ok "no ZFS pool, so no ARC cap needed"
    return
  fi
  ensure_file /etc/modprobe.d/zfs.conf "options zfs zfs_arc_max=$ZFS_ARC_MAX"
  if ((CHANGED)); then
    change "rebuild the initramfs so the ARC cap holds from boot" update-initramfs -u -k all
  fi
  local arc=/sys/module/zfs/parameters/zfs_arc_max
  if [[ $(cat "$arc" 2>/dev/null) == "$ZFS_ARC_MAX" ]]; then
    ok "ZFS ARC capped at 2 GB"
  else
    change "cap the ZFS ARC at 2 GB now, without a reboot (write $arc)" set_arc_max "$arc"
  fi
}

# with_landlock <cmdline>: print <cmdline> with landlock first in its lsm=
# list. Without an lsm= parameter, the list starts from the running kernel's
# order (or STOCK_LSM), so the other modules keep theirs.
with_landlock() {
  local word words out=() found=0 running
  read -ra words <<<"$1"
  for word in "${words[@]}"; do
    if [[ $word == lsm=* ]]; then
      found=1
      [[ ,${word#lsm=}, == *,landlock,* ]] || word="lsm=landlock,${word#lsm=}"
    fi
    out+=("$word")
  done
  if ((!found)); then
    running="$(cat /sys/kernel/security/lsm 2>/dev/null)" || true
    out+=("lsm=landlock,${running:-$STOCK_LSM}")
  fi
  printf '%s' "${out[*]}"
}

# Copy a changed command line to the boot partitions.
refresh_boot() {
  if [[ -s /etc/kernel/proxmox-boot-uuids ]]; then
    change "copy the new command line to the boot partitions" proxmox-boot-tool refresh
  else
    change "regenerate the GRUB config" update-grub
  fi
}

setup_landlock() {
  step "Landlock LSM"
  # systemd-boot (UEFI installs managed by proxmox-boot-tool) reads
  # /etc/kernel/cmdline; GRUB, including legacy-BIOS ZFS installs that
  # proxmox-boot-tool also manages, reads /etc/default/grub.
  local file
  if [[ -s /etc/kernel/proxmox-boot-uuids && -d /sys/firmware/efi ]]; then
    file=/etc/kernel/cmdline
    local have
    have="$(cat "$file" 2>/dev/null)" || true
    if [[ -z $have ]]; then
      problem "$file is empty or unreadable; proxmox-boot-tool needs it to hold root= and the rest"
      return
    fi
    ensure_file "$file" "$(with_landlock "$have")"
  elif [[ -r /etc/default/grub ]]; then
    file=/etc/default/grub
    local value want
    value="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT=//p' "$file" | head -n1)"
    value="${value#[\"\']}"
    value="${value%[\"\']}"
    want="$(NEW="GRUB_CMDLINE_LINUX_DEFAULT=\"$(with_landlock "$value")\"" awk '
      /^GRUB_CMDLINE_LINUX_DEFAULT=/ && !done { print ENVIRON["NEW"]; done = 1; next }
      { print }
      END { if (!done) print ENVIRON["NEW"] }' "$file")"
    ensure_file "$file" "$want"
  else
    skip "no /etc/kernel/proxmox-boot-uuids or /etc/default/grub, so no boot loader to configure"
    return
  fi
  if ((CHANGED)); then refresh_boot; fi
  if grep -qw landlock /sys/kernel/security/lsm 2>/dev/null; then
    ok "running kernel has Landlock"
  else
    REBOOT=1
    note "the running kernel has no Landlock until the host reboots"
  fi
}

reload_sshd() { sshd -t && systemctl reload ssh; }

setup_root_ssh() {
  step "Root SSH key"
  # On Proxmox this is a symlink into /etc/pve/priv: append through it, never
  # replace it.
  local auth=/root/.ssh/authorized_keys key fp have_key=0
  # The installer authorizes the node's own key; only a key from someone
  # else counts before password login is turned off.
  if [[ -r $auth ]] && grep -E '^(ssh-|ecdsa-|sk-)' "$auth" |
    grep -vxFf <(cat /root/.ssh/id_*.pub 2>/dev/null) | grep -q .; then
    have_key=1
  fi

  if [[ -n $SSH_KEY_FILE ]]; then
    while IFS= read -r key; do
      key="${key%$'\r'}"
      key="${key%"${key##*[![:space:]]}"}"
      [[ $key =~ ^[[:space:]]*(#|$) ]] && continue
      fp="$(ssh-keygen -lf - <<<"$key" | awk '{print $2 " " $3}')"
      if [[ -r $auth ]] && grep -qxF -- "$key" "$auth"; then
        ok "key $fp already authorized"
      else
        change "authorize key $fp for root" append_line "$auth" "$key"
      fi
      have_key=1
    done <"$SSH_KEY_FILE"
  fi

  if ((!have_key)); then
    problem "root has no authorized SSH key; rerun with --ssh-key <file> (password login stays on until then)"
    return
  fi
  ensure_file /etc/ssh/sshd_config.d/devboxes.conf "$SSHD_CONF"
  if ((CHANGED)); then
    change "check and reload sshd (sshd -t, systemctl reload ssh)" reload_sshd
  fi
}

tailscale_ip() {
  command -v tailscale >/dev/null && tailscale ip -4 2>/dev/null | head -n1 | grep .
}

tailscale_up() {
  if [[ -n ${TS_AUTHKEY:-} ]]; then
    tailscale up --auth-key="$TS_AUTHKEY"
  else
    tailscale up
  fi
}

setup_tailscale() {
  step "Tailscale"
  if command -v tailscale >/dev/null; then
    ok "tailscale installed"
  else
    change "install tailscale" apt_install tailscale
  fi
  if systemctl is-enabled --quiet tailscaled 2>/dev/null &&
    systemctl is-active --quiet tailscaled 2>/dev/null; then
    ok "tailscaled enabled and running"
  else
    change "enable and start tailscaled" systemctl enable --now tailscaled
  fi
  local ip
  if ip="$(tailscale_ip)"; then
    ok "on the tailnet as $ip"
  else
    change "join the tailnet with 'tailscale up' (prints a login URL unless TS_AUTHKEY is set)" tailscale_up
  fi
}

setup_firewall() {
  step "Firewall"
  # Closing everything but the tailnet before the host is on it would lock
  # out every way in except the physical console.
  if ((APPLY)) && ! tailscale_ip >/dev/null; then
    problem "Tailscale is not up, so the firewall stays as it is; rerun once 'tailscale ip' works"
    return
  fi
  ensure_file /etc/pve/firewall/cluster.fw "$CLUSTER_FW"
  if systemctl is-active --quiet pve-firewall 2>/dev/null; then
    ok "pve-firewall running"
  else
    change "enable and start pve-firewall" systemctl enable --now pve-firewall
  fi
}

setup_template() {
  step "Arch Linux LXC template"
  if ! command -v pveam >/dev/null; then
    skip "downloading the template needs Proxmox (pveam)"
    return
  fi
  # Refreshing the index changes nothing about the host's setup, so it is not
  # counted as a change; a dry run reads the index as it is.
  if ((APPLY)); then pveam update >/dev/null; fi
  local latest
  latest="$(pveam available --section system | awk '$2 ~ /^archlinux-base_/ {print $2}' | sort -V | tail -n1)"
  if [[ -z $latest ]]; then
    if ((APPLY)); then
      problem "no archlinux-base template in the Proxmox template index"
    else
      change "refresh the template index and download the latest archlinux-base template" \
        pveam update
    fi
  elif pveam list "$TEMPLATE_STORAGE" | awk '{print $1}' | grep -qxF "$TEMPLATE_STORAGE:vztmpl/$latest"; then
    ok "$latest on $TEMPLATE_STORAGE"
  else
    change "download $latest to $TEMPLATE_STORAGE" pveam download "$TEMPLATE_STORAGE" "$latest"
  fi
}

main() {
  while (($#)); do
    case "$1" in
      --dry-run) APPLY=0 ;;
      --apply) APPLY=1 ;;
      --ssh-key)
        (($# >= 2)) || die "--ssh-key needs a file"
        SSH_KEY_FILE="$2"
        shift
        ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done

  if [[ -n $SSH_KEY_FILE ]]; then
    [[ -r $SSH_KEY_FILE ]] || die "--ssh-key: cannot read $SSH_KEY_FILE"
    ! grep -q 'PRIVATE KEY' "$SSH_KEY_FILE" ||
      die "--ssh-key: $SSH_KEY_FILE is a private key; pass the .pub file"
    grep -vE '^[[:space:]]*(#|$)' "$SSH_KEY_FILE" | grep -q . ||
      die "--ssh-key: $SSH_KEY_FILE holds no keys"
    local bad
    bad="$(grep -vE '^[[:space:]]*(#|$)' "$SSH_KEY_FILE" |
      grep -vE '^(ssh-[a-z0-9-]+|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/]+=* ?' | head -n1)" || true
    [[ -z $bad ]] || die "--ssh-key: not a public key line in $SSH_KEY_FILE: ${bad:0:40}..."
  fi

  local shared=0
  is_shared_host && shared=1
  if ((APPLY && shared)); then
    die "refusing --apply: this host runs guests that aren't devboxes, so it is shared and gets no host-level changes"
  fi

  [[ -d /etc/pve ]] && command -v pveversion >/dev/null && PVE=1
  local suite
  suite="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null)" || true

  if ((APPLY)); then
    ((EUID == 0)) || die "--apply must run as root"
    ((PVE)) || die "--apply needs a Proxmox VE host (no /etc/pve or pveversion here)"
    [[ $suite == "$SUITE" ]] || die "needs Proxmox VE 9 (Debian $SUITE), found Debian '$suite'"
    printf 'Applying host setup on %s.\n' "$(hostname -f 2>/dev/null || hostname)"
  else
    printf 'Dry run on %s: nothing is changed.\n' "$(hostname -f 2>/dev/null || hostname)"
    ((!shared)) || printf 'note: this host runs guests that aren'\''t devboxes; --apply will refuse to run here.\n'
    ((PVE)) || printf 'note: not a Proxmox VE host, so Proxmox-only checks are skipped.\n'
    ((PVE == 0)) || [[ $suite == "$SUITE" ]] ||
      printf "note: expected Debian %s (Proxmox VE 9), found '%s'; --apply will refuse.\n" "$SUITE" "$suite"
    ((EUID == 0)) || printf 'note: not root, so files only root can read show as missing.\n'
  fi

  setup_repos
  setup_storage
  setup_landlock
  setup_root_ssh
  setup_tailscale
  setup_firewall
  setup_template

  printf '\n'
  if ((APPLY)); then
    printf '%d change(s) made.\n' "$CHANGES"
  else
    printf '%d change(s) pending; run with --apply to make them.\n' "$CHANGES"
  fi
  if ((REBOOT)); then
    printf 'Reboot the host to turn on Landlock (cat /sys/kernel/security/lsm should then list it).\n'
  fi
  if ((PROBLEMS)); then
    printf '%d problem(s) need attention (see PROBLEM above).\n' "$PROBLEMS" >&2
    exit 1
  fi
}

main "$@"
