#!/usr/bin/env bash
# Stage one of a devbox's setup, run as root inside a fresh Arch container
# (bin/devbox-create fetches it at a pinned commit and runs it with pct exec).
# Gets pacman working, clones the devboxes repo at that commit, records the
# client, then hands over to `devbox bootstrap`. Safe to re-run.
set -euo pipefail

DIR=/opt/devboxes
STATE=/var/lib/devbox
# shellcheck disable=SC2016 # pacman expands these, not the shell
MIRROR='https://geo.mirror.pkgbuild.com/$repo/os/$arch'

die() {
  printf 'bootstrap.sh: %s\n' "$*" >&2
  exit 1
}

(($# == 4)) || die "usage: bootstrap.sh <client> <repo-url> <branch> <commit>"
client="$1" url="$2" branch="$3" commit="$4"
((EUID == 0)) || die "must run as root"

# pacman 7 downloads as user alpm inside a Landlock sandbox. The stock Proxmox
# kernel doesn't enable Landlock, so in a container every download fails; turn
# the download sandbox off then. It only confines pacman's own downloader:
# signatures are still checked, and the container stays unprivileged.
if ! grep -qw landlock /sys/kernel/security/lsm 2>/dev/null; then
  sed -i -e 's/^DownloadUser/#DownloadUser/' \
    -e 's/^#DisableSandboxFilesystem/DisableSandboxFilesystem/' \
    -e 's/^#DisableSandboxSyscalls/DisableSandboxSyscalls/' /etc/pacman.conf
fi

# Fresh containers can ship with an empty keyring and no mirror enabled.
pacman-key --init
pacman-key --populate archlinux >/dev/null
grep -q '^Server' /etc/pacman.d/mirrorlist || printf 'Server = %s\n' "$MIRROR" >>/etc/pacman.d/mirrorlist
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

exec "$DIR/bin/devbox" bootstrap
