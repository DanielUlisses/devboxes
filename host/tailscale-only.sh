#!/usr/bin/env bash
# Join a Proxmox VE 9 host to the tailnet, after switching it from the
# enterprise repos (which need a subscription) to pve-no-subscription. No
# firewall, SSH or boot changes. For a host setup.sh refuses (one that runs
# other guests). Runs on the host, as root; safe to re-run.
#
#   scp host/tailscale-only.sh root@<host>: && ssh -t root@<host> ./tailscale-only.sh
#
# TS_AUTHKEY in the environment joins with an auth key instead of a login URL.
set -euo pipefail

KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
SOURCES=/etc/apt/sources.list.d/tailscale.list

die() {
  printf 'tailscale-only.sh: %s\n' "$*" >&2
  exit 1
}

((EUID == 0)) || die "run as root"
suite="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)"
[[ -n $suite ]] || die "could not read the Debian release from /etc/os-release"

# deb822 sources files: add or set "Enabled: no" in every stanza.
disable_sources() {
  if grep -qi '^Enabled:' "$1"; then
    sed -i 's/^Enabled:.*/Enabled: no/I' "$1"
  else
    sed -i 's/^Types:.*/&\nEnabled: no/' "$1"
  fi
}

# The enterprise repos off (left as they are when commented out or disabled
# already), and pve-no-subscription on unless some source has it already.
for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
  [[ -f $f ]] || continue
  if grep -qE '^URIs:.*enterprise\.proxmox\.com' "$f" && ! grep -qiE '^Enabled:[[:space:]]*(no|false)' "$f"; then
    disable_sources "$f"
    echo "repos: disabled the enterprise repo in $f"
  fi
done
for f in /etc/apt/sources.list.d/*.list; do
  [[ -f $f ]] || continue
  if grep -qE '^deb .*enterprise\.proxmox\.com' "$f"; then
    sed -i -E 's/^(deb .*enterprise\.proxmox\.com)/# \1/' "$f"
    echo "repos: commented out the enterprise repo in $f"
  fi
done
if grep -rqsE '^[^#]*pve-no-subscription' /etc/apt/sources.list /etc/apt/sources.list.d/; then
  echo "repos: pve-no-subscription already configured"
else
  printf '%s\n' "Types: deb" "URIs: http://download.proxmox.com/debian/pve" "Suites: $suite" \
    "Components: pve-no-subscription" "Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg" \
    >/etc/apt/sources.list.d/proxmox.sources
  echo "repos: added pve-no-subscription (/etc/apt/sources.list.d/proxmox.sources)"
fi

if command -v tailscale >/dev/null; then
  echo "tailscale: installed"
else
  echo "tailscale: adding its apt repo for Debian $suite"
  curl -fsSL -o "$KEYRING" "https://pkgs.tailscale.com/stable/debian/$suite.noarmor.gpg"
  echo "deb [signed-by=$KEYRING] https://pkgs.tailscale.com/stable/debian $suite main" >"$SOURCES"
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q tailscale
fi

systemctl enable --now tailscaled

# --accept-dns=false: the host keeps its own DNS. Proxmox copies the host's
# resolv.conf into every container it starts, so MagicDNS here would reach
# every guest.
if ip="$(tailscale ip -4 2>/dev/null | head -n1)" && [[ -n $ip ]]; then
  echo "tailscale: already up as $ip"
  if tailscale debug prefs 2>/dev/null | grep -q '"CorpDNS": true'; then
    tailscale set --accept-dns=false
    echo "tailscale: the host keeps its own DNS now"
  fi
elif [[ -n ${TS_AUTHKEY:-} ]]; then
  tailscale up --accept-dns=false --auth-key="$TS_AUTHKEY"
else
  echo "tailscale: open the URL below to add this host to the tailnet"
  tailscale up --accept-dns=false
fi
echo "tailscale: up as $(tailscale ip -4 | head -n1)"
