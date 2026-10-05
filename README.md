# devboxes

One dev VM per client, each described by a small YAML file in this repo.

## Layout

```
defaults.yaml          defaults every client inherits (resources, base skills)
clients/_template.yaml documented template; every field explained
clients/<client>.yaml  one file per client
bin/devbox-config      prints a client's resolved config, or fails naming the bad field
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
