# devboxes

One dev VM per client, each described by a small YAML file in this repo.

## Layout

```
defaults.yaml          defaults every client inherits (resources, base skills)
clients/_template.yaml documented template; every field explained
clients/<client>.yaml  one file per client
bin/devbox-config      prints a client's resolved config, or fails naming the bad field
bin/devbox-create      creates, starts and bootstraps a client's container on the Proxmox host
bin/devbox-sync        syncs a client's box to this checkout's config, from your machine
bin/devbox-destroy     stops and destroys it
bin/devbox             runs inside a box: `devbox bootstrap`, `devbox sync`
bootstrap.sh           first thing a new box runs: clones this repo, hands over to devbox
dotfiles/              bash, git and gh config stowed into every box (no identity, no secrets)
lib/pve.sh             the one way bin/ scripts talk to the host
host/setup.sh          prepares the dedicated Proxmox host (run on the host)
```

## Adding a client

1. `cp clients/_template.yaml clients/<client>.yaml` (name: lowercase letters, digits, dashes).
2. Edit it. Delete anything you don't need; it falls back to `defaults.yaml`.
3. `bin/devbox-config <client>` and check the output.
4. Commit.

## devbox-config

```
bin/devbox-config [--json] <client>
```

Prints `defaults.yaml` merged with `clients/<client>.yaml`, as YAML (or JSON
with `--json`). Mappings merge key by key, lists replace, except `skills`, which
appends the client's extras to the base list (duplicates dropped). `hostname` defaults to
`dev-<client>`.

On an invalid file it prints one line per problem, each naming the field, and
exits 1:

```
clients/acme.yaml: resources.cores: must be an integer >= 1 (got 2.5)
clients/acme.yaml: tools[0]: must be <tool>@<version> (got "terraform")
```

Needs `jq` and [mikefarah/yq](https://github.com/mikefarah/yq) v4
(`pacman -S jq go-yq`; Arch's plain `yq` package is a different tool).

## devbox-create / devbox-destroy

```
bin/devbox-create [--light] [--dry-run] <client>
bin/devbox-destroy <client>
```

Both run `ssh root@$DEVBOX_HOST pct ...`. `DEVBOX_HOST` has no default and
must be exported (host names stay out of this public repo). `devbox-create` makes an unprivileged Arch container
with `nesting=1` and `/dev/net/tun`, hostname from the config, tag `devbox`,
the first free VMID in 2000-2099, sized from `resources`, then starts it.
`--light` caps it at 1 GB memory, 512 MB swap, 1 core and an 8 GB disk; `--dry-run` runs
every check and prints the `pct create` and `pct exec` commands instead of running them.

Once started, the box bootstraps itself: `devbox-create` looks up the pushed
head of the repo's `main` on GitHub (`DEVBOX_BRANCH` picks another branch)
and `pct exec`s a fetch of `bootstrap.sh` at that commit. The box clones this
public repo, so the client file and any script changes must be pushed first.

The test host is shared, so the scripts never change the host itself:
`lib/pve.sh` only lets through `pct create/start/stop/destroy/exec/list`
and read-only queries (`pct config/status`, `pvesh get /cluster/resources`,
`pveam list`, `/proc/meminfo`), and refuses any `pct` call on a VMID outside
2000-2099. `devbox-create` refuses when the host has under 1 GB memory
available, or when the hostname is already taken. `devbox-destroy` only
touches a container tagged `devbox`, in range, with the client's hostname,
re-read from its live config just before; with no such container it exits 0.

The Arch template must already be on the host (downloading it is a host
change, left to a person): `pveam download local archlinux-base_<date>_amd64.tar.zst`.
Overrides: `DEVBOX_HOST`, `DEVBOX_BRANCH` (default `main`), `DEVBOX_STORAGE` (rootfs, default `local-lvm`),
`DEVBOX_TEMPLATE_STORAGE` (default `local`), `DEVBOX_BRIDGE` (default `vmbr0`).

## Inside a box

`bootstrap.sh` gets pacman working (keyring, mirror, and pacman's download
sandbox turned off when the kernel has no Landlock, as the stock Proxmox one
doesn't), clones this repo to
`/opt/devboxes` at the pinned commit, records the client and branch in
`/var/lib/devbox/`, then runs `devbox bootstrap`, which:

- installs the base packages (`base-devel git openssh sudo stow jq go-yq
  unzip mise github-cli tailscale bash-completion`) and enables `tailscaled`;
- adds user `daniel` with passwordless sudo, and `devbox` on the PATH;
- installs Claude Code (native installer) and puts herdr and the 1Password
  CLI (`op`) in mise's system config, `/etc/mise/config.toml`;
- stows this repo's `dotfiles/` packages (`bash`, `git`, `gh`) into the
  user's home (files in the way are moved to `<file>.bak`). They hold no
  identity: git's `user.name`/`user.email` go in `~/.gitconfig.local`, shell
  extras in `~/.bashrc.local`, and git authenticates through `gh`;
- ends with `devbox sync`.

Every step checks first, so re-running `devbox bootstrap` is safe.

```
devbox sync                 # inside the box, as daniel or root
bin/devbox-sync <client>    # from your machine
```

`devbox sync` pulls the box's branch of this repo and converges the box to
the client's resolved config; `bin/devbox-sync` instead resolves the config
in your checkout (uncommitted edits included) and runs the sync with it over
`ssh` and `pct exec`, without pulling. A sync:

- **packages:** installs listed packages that are missing. Packages dropped
  from the list since the last sync (recorded in `/var/lib/devbox/packages`)
  are marked as dependencies and removed with `pacman -Rns` unless another
  package still needs them. Base packages are never removed.
- **tools:** writes `~/.config/mise/config.toml` from `tools:` (a tool listed
  twice gets both versions, the first the default), then `mise install` and
  `mise prune`, which drops versions no config uses.

With nothing changed, a sync installs and removes nothing.

## The Proxmox host

Devboxes run as LXC containers on a dedicated Proxmox VE 9 host (24 GB,
Ryzen 7 8c/16t). A host that already runs other guests is treated as shared: it gets no
host-level changes, and `host/setup.sh --apply` refuses to run there.

### Installing Proxmox from the ISO

1. Download the latest Proxmox VE 9 ISO from
   <https://www.proxmox.com/en/downloads> and check its SHA256 against the
   download page.
2. Write it to a USB stick (`dd if=proxmox-ve_9.*.iso of=/dev/sdX bs=4M
   conv=fsync status=progress`, with `sdX` the stick, not a disk you need),
   boot the host from it and pick **Install Proxmox VE (Graphical)**.
3. **Target disk:** the system disk, filesystem **ext4**. The installer then
   makes `local` (ISOs, templates) and `local-lvm` (LVM-thin, container disks).
   ZFS works too; `setup.sh` caps its ARC at 2 GB so it leaves memory for the
   containers.
4. **Location, timezone, keyboard:** your own.
5. **Root password:** a strong one, kept in the password manager. It is for
   the web UI and the physical console; SSH as root becomes key-only.
6. **Network:** the management NIC, a static address on the LAN and an FQDN
   for the new host.
7. Reboot, remove the stick, and check `https://<lan-ip>:8006` loads.

### Running the host setup

From your machine, copy the script and your public key over, then dry-run:

```
scp host/setup.sh ~/.ssh/id_ed25519.pub root@<lan-ip>:
ssh -t root@<lan-ip> ./setup.sh --dry-run --ssh-key id_ed25519.pub
```

The dry run prints every change it would make (file diffs included) and
changes nothing. Then apply:

```
ssh -t root@<lan-ip> ./setup.sh --apply --ssh-key id_ed25519.pub
```

`tailscale up` prints a login URL to open in a browser; set `TS_AUTHKEY` in
the environment to join with an auth key instead. `--apply` is idempotent:
each step checks the current state first, so a re-run only does what is still
missing and a run with nothing left to do reports `0 change(s) made`. It exits
non-zero when something needs a person (no thin storage, no SSH key, Tailscale
not up).

What it sets up:

- **Repos:** disables the enterprise repos and adds `pve-no-subscription`,
  plus Tailscale's apt repo.
- **Storage:** checks for active LVM-thin or ZFS container storage; with ZFS,
  caps the ARC at 2 GB now and from boot.
- **Root SSH key:** adds the `--ssh-key` keys to root's `authorized_keys`, then
  turns off password login over SSH.
- **Tailscale:** installs it, starts `tailscaled`, joins the tailnet.
- **Firewall:** the datacenter firewall drops all inbound traffic except over
  Tailscale, so neither the WAN nor the LAN can reach SSH or the web UI.
  It is only switched on once Tailscale is up. After that, use
  `https://<tailscale-ip>:8006` and `ssh root@<tailscale-ip>`.
- **Template:** downloads the latest `archlinux-base` LXC template to `local`.

If the firewall ever locks you out, log in on the physical console and run
`pve-firewall stop`.

## No secrets

This repo is public. Client files hold names, sizes and lists only: no
tokens, passwords, keys or email addresses. `claude_account` is a label, not
the account's email. `devbox-config` rejects any value that looks like an
email address.
