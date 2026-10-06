#!/usr/bin/env bash
# Stage one of a devbox's setup, run as root inside a fresh Arch container
# (bin/devbox-create fetches it at a pinned commit and runs it with pct exec).
# Gets pacman working, clones the devboxes repo at that commit, records the
# client and the resolved config devbox-create handed in (the client files
# are in a private repo the box can't read yet), then hands over to
# `devbox bootstrap`. Safe to re-run.
set -euo pipefail

DIR=/opt/devboxes
STATE=/var/lib/devbox
# shellcheck disable=SC2016 # pacman expands these, not the shell
MIRROR='https://geo.mirror.pkgbuild.com/$repo/os/$arch'

die() {
  printf 'bootstrap.sh: %s\n' "$*" >&2
  exit 1
}

(($# == 5)) || die "usage: bootstrap.sh <client> <repo-url> <branch> <commit> <config-json>"
client="$1" url="$2" branch="$3" commit="$4" config="$5"
((EUID == 0)) || die "must run as root"

# Fresh containers can ship with an empty keyring and no mirror enabled.
pacman-key --init
pacman-key --populate archlinux >/dev/null
grep -q '^Server' /etc/pacman.d/mirrorlist || printf 'Server = %s\n' "$MIRROR" >>/etc/pacman.d/mirrorlist

# pacman 7 downloads as user alpm inside a Landlock sandbox. A kernel without
# Landlock (stock Proxmox) makes every download fail; only then is the
# download sandbox turned off. Tried rather than read from
# /sys/kernel/security/lsm, which an unprivileged container can't see. It only
# confines pacman's own downloader: signatures are still checked, and the
# container stays unprivileged.
if ! out="$(pacman -Sy 2>&1)"; then
  grep -qiE 'landlock|sandbox' <<<"$out" || die "pacman -Sy failed: $out"
  echo "bootstrap.sh: pacman's download sandbox doesn't work on this kernel (no Landlock); turning it off" >&2
  sed -i -e 's/^DownloadUser/#DownloadUser/' \
    -e 's/^#DisableSandboxFilesystem/DisableSandboxFilesystem/' \
    -e 's/^#DisableSandboxSyscalls/DisableSandboxSyscalls/' /etc/pacman.conf
fi
pacman -Syu --needed --noconfirm archlinux-keyring git

if [[ ! -d $DIR/.git ]]; then
  git clone -q --branch "$branch" "$url" "$DIR"
else
  git -C "$DIR" fetch -q origin "$branch"
fi
git -C "$DIR" -c advice.detachedHead=false checkout -q --detach "$commit"

mkdir -p "$STATE"
printf '%s\n' "$client" >"$STATE/client"
printf '%s\n' "$branch" >"$STATE/branch"
# Readable by the box user: login, finish and logout read it. No secrets in it.
install -m 644 /dev/stdin "$STATE/config.json" <<<"$config"

exec "$DIR/bin/devbox" bootstrap
