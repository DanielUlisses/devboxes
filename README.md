# devboxes

One dev VM per client, each described by a small YAML file in this repo.

## Layout

```
defaults.yaml          defaults every client inherits (resources, base skills)
clients/_template.yaml documented template; every field explained
clients/<client>.yaml  one file per client
bin/devbox-config      prints a client's resolved config, or fails naming the bad field
bin/devbox-create      creates and starts a client's container on the Proxmox host
bin/devbox-destroy     stops and destroys it
lib/pve.sh             the one way bin/ scripts talk to the host
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
every check and prints the `pct create` command instead of running it.

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
Overrides: `DEVBOX_HOST`, `DEVBOX_STORAGE` (rootfs, default `local-lvm`),
`DEVBOX_TEMPLATE_STORAGE` (default `local`), `DEVBOX_BRIDGE` (default `vmbr0`).

## No secrets

This repo is public. Client files hold names, sizes and lists only: no
tokens, passwords, keys or email addresses. `claude_account` is a label, not
the account's email. `devbox-config` rejects any value that looks like an
email address.
