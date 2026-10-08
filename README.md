# devboxes

One dev VM per client, each described by a small YAML file. The code,
defaults and template are here; the client files themselves live in a
private repo, `DanielUlisses/devbox-clients`, so client names, orgs and repo
names stay out of this public one.

## Layout

```
defaults.yaml          defaults every client inherits (resources, base skills)
clients/_template.yaml documented template; every field explained (the only file in clients/)
bin/devbox-config      prints a client's resolved config, or fails naming the bad field
bin/devbox-create      creates, starts and bootstraps a client's container on the Proxmox host
bin/devbox-sync        syncs a client's box to this checkout's config, from your machine
bin/devbox-destroy     stops and destroys it
bin/devbox-host        this machine's side of the boxes: ssh config entries, herdr machines, host keys
bin/devbox             runs inside a box: `devbox bootstrap`, `sync`, `login`, `finish`, `update`, `logout`, `rc`
bin/devbox-agent-instructions  prints a box's agent instructions (~/.claude/CLAUDE.md, ~/AGENTS.md) from a resolved config
bin/devbox-browser     $BROWSER in a box: prints URLs instead of opening them
bootstrap.sh           first thing a new box runs: clones this repo, hands over to devbox
dotfiles/              bash, git, gh and nvim config stowed into every box (no identity, no secrets)
lib/pve.sh             the one way bin/ scripts talk to the host
lib/host-name.sh       what a Proxmox host's ssh name may be, for devbox-config and the bash scripts
host/setup.sh          prepares the dedicated Proxmox host (run on the host)
host/tailscale-only.sh no-subscription repo + tailnet for a shared Proxmox host, no firewall
.githooks/pre-commit   refuses commits that fail the checks or leak secrets
```

## Pre-commit checks

Once per clone:

```
git config core.hooksPath .githooks
```

The hook checks the staged content (not the working tree) and refuses the
commit, naming the file and the reason, when:

- `shellcheck` fails on a staged shell file (`bin/*`, `lib/*.sh`,
  `bootstrap.sh`, `host/*.sh`, `.githooks/*`, `dotfiles/bash/*`);
- `bin/devbox-config` rejects a staged client file or `_template` (a staged
  `defaults.yaml` checks every client);
- a staged file holds an email address (other than `users.noreply.github.com`,
  or a `git@<host>` SSH remote),
  a private key block, a 1Password token (`ops_…`), a GitHub token (`ghp_`,
  `gho_`, `github_pat_`), or a host name listed in `.git/devbox-deny-hosts`.

The deny-list is local and untracked, one host name per line (`#` comments
allowed), so the names it blocks never have to be written into this repo.
`DEVBOX_DENY_HOSTS` points the hook at another file. `shellcheck`, `yq` and
`jq` come from PATH or, failing that, `mise exec`; a missing tool refuses the
commit rather than skipping the check.

## Client files: the devbox-clients repo

Client files are `clients/<client>.yaml` in the private
`DanielUlisses/devbox-clients` repo, checked out next to this one:

```
devboxes/           this repo
devbox-clients/     clients/<client>.yaml, one per client
```

`bin/devbox-config`, `devbox-create`, `devbox-sync` and `devbox-destroy` read
clients from `$DEVBOX_CLIENTS`, by default `../devbox-clients` next to this
checkout; `_template` still resolves from this repo. A client file in this
repo's `clients/` is ignored by git, and `devbox-config` refuses it.

Creating the private repo (once; already done):

```
gh repo create DanielUlisses/devbox-clients --private --clone
mkdir devbox-clients/clients
```

then add the first client (below) and push: a box that syncs from the repo
needs at least one commit on it.

Run it in the directory holding this checkout. On another machine, clone it
there with `gh repo clone DanielUlisses/devbox-clients`, or point
`DEVBOX_CLIENTS` at wherever it is.

## Adding a client

From this checkout:

1. `cp clients/_template.yaml ../devbox-clients/clients/<client>.yaml` (name: lowercase letters, digits, dashes).
2. Edit it. Delete anything you don't need; it falls back to `defaults.yaml`.
3. `bin/devbox-config <client>` and check the output.
4. Commit and push it in `devbox-clients`.

## devbox-config

```
bin/devbox-config [--json] <client>
```

Prints `defaults.yaml` merged with the client's file
(`$DEVBOX_CLIENTS/clients/<client>.yaml`), as YAML (or JSON with
`--json`). Mappings merge key by key, lists replace, except `skills`, which
appends the client's extras to the base list (duplicates dropped). `hostname` defaults to
`dev-<client>`. `role` is `devbox` (the default) or `runner` (see [Runner
boxes](#runner-boxes)); `claude_account` is required only for a devbox, and a
runner starts from `runner_resources` instead of `resources`. `host`, the ssh name of the Proxmox host the box runs on
(as in `ssh root@<host>`), defaults to empty, meaning `$DEVBOX_HOST`; it is
a label like `claude_account`, and like every client value it lives only in
the private `devbox-clients` files.

On an invalid file it prints one line per problem, each naming the field, and
exits 1:

```
devbox-clients/clients/acme.yaml: resources.cores: must be an integer >= 1 (got 2.5)
devbox-clients/clients/acme.yaml: tools[0]: must be <tool>@<version> (got "terraform")
```

Needs `jq` and [mikefarah/yq](https://github.com/mikefarah/yq) v4
(`pacman -S jq go-yq`; Arch's plain `yq` package is a different tool).

## devbox-create / devbox-destroy

```
bin/devbox-create [--light] [--dry-run] [--allow-unpushed] <client>
bin/devbox-destroy [--skip-logout] <client>
```

Both run `ssh root@<host> pct ...`, where `<host>` is the client's `host`
or, when its file sets none, `$DEVBOX_HOST`; so does `devbox-sync`, and the
first line each prints names the host it targets. `DEVBOX_HOST` has no
default: a client without `host` needs it exported (host names stay out of
this public repo), and the scripts stop before any host call when neither is
set. `devbox-create` makes an unprivileged Arch container
with `nesting=1,keyctl=1` (what Docker needs, see [Docker](#docker)) and `/dev/net/tun`, hostname from the config, tag `devbox`,
the first free VMID in 2000-2099, sized from `resources` (memory, swap,
cores, disk and `cpuunits`, its CPU weight against the host's other guests;
100 is Proxmox's default), then starts it.
`--light` caps it at 1 GB memory, 512 MB swap, 1 core and an 8 GB disk; `--dry-run` runs
every check and prints the `pct create` and `pct exec` commands, and the
backup job's `pvesh` command (see [Backups](#backups)), instead of running them.

Once started, the box bootstraps itself: `devbox-create` looks up the pushed
head of the repo's `main` on GitHub (`DEVBOX_BRANCH` picks another branch)
and `pct exec`s a fetch of `bootstrap.sh` at that commit, handing it the
client's resolved config (`devbox-config --json`, from your machine). The box
clones this public repo anonymously, so script changes must be pushed first;
the client file only needs pushing to `devbox-clients` before a sync inside
the box after `devbox login`, as the box never reads the private repo before
that. Since the box runs the pushed `bootstrap.sh` while your machine runs
its local scripts, `devbox-create` refuses when this checkout's HEAD is not
that pushed commit; `--allow-unpushed` creates anyway.

The test host is shared, so the scripts never change the host itself:
`lib/pve.sh` only lets through `pct create/start/stop/destroy/exec/list`
and read-only queries (`pct config/status`, `pvesh get /cluster/resources`
and `/cluster/backup`, `pveam list`, `/proc/meminfo`), and refuses any `pct`
call on a VMID outside 2000-2099. The one exception is a box's backup job,
which `lib/pve.sh` only creates, changes or deletes on a dedicated host
(below). `devbox-create` refuses when the host has under 1 GB memory
available, or when the hostname is already taken. `devbox-destroy` only
touches a container tagged `devbox`, in range, with the client's hostname,
re-read from its live config just before; with no such container it exits 0.
Before stopping it, `devbox-destroy` runs `devbox logout` inside the box
(starting it first if it is stopped), which deletes the box's SSH keys from
GitHub and logs it out of tailscale; if that fails it stops, and
`--skip-logout` destroys anyway (then delete the keys titled with its
hostname on GitHub by hand).

The Arch template must already be on the host (downloading it is a host
change, left to a person): `pveam download local archlinux-base_<date>_amd64.tar.zst`.
Once a box is created, `devbox-create` runs `bin/devbox-host add` for it;
`devbox-destroy` runs `bin/devbox-host remove` once the box is gone (or when
there was none), so a box recreated under the same name starts clean. See
[devbox-host](#devbox-host).

Overrides: `DEVBOX_HOST`, `DEVBOX_BRANCH` (default `main`), `DEVBOX_STORAGE` (rootfs, default `local-lvm`),
`DEVBOX_TEMPLATE_STORAGE` (default `local`), `DEVBOX_BRIDGE` (default `vmbr0`),
`DEVBOX_BACKUP_STORAGE` (backups, default `local`).

### Backups

With `backup: true` in the client file, `devbox-create` adds a Proxmox
backup job for the box: vzdump of its VMID in snapshot mode, zstd, to
`$DEVBOX_BACKUP_STORAGE` (default `local`), on `backup_schedule` (a Proxmox
calendar event, default `02:00`, daily), keeping the last `backup_keep`
(default 7). The job's id is `devbox-<hostname>` and its comment starts with
`devbox <hostname>`; the scripts touch no other job.

- `bin/devbox-sync` adds the job when `backup` turns on, removes it when it
  turns off, and updates its schedule, retention, storage (from
  `$DEVBOX_BACKUP_STORAGE` on the machine running it) or VMID when they
  differ.
- `devbox-destroy` removes the job before anything else, and refuses to
  destroy the box when it can't, since the job would back up whichever box
  gets that VMID next. The backups already taken stay on the storage.

A backup job is a host-level change. `lib/pve.sh` only allows it on a
dedicated host, where every guest is a devbox (a container in 2000-2099
tagged `devbox`), the same rule `host/setup.sh --apply` uses. On a host
running anything else it refuses, naming the other guests: `devbox-create`
still creates and bootstraps the box, without a job, and `--dry-run` prints
the job with a note that it would be refused.

**Restoring a box**, on the host as root (a person's job, like the
template):

```
pvesm list local --content backup --vmid <vmid>     # pick the archive
pct stop <vmid>                                     # if the box still exists
pct restore <vmid> local:backup/vzdump-lxc-<vmid>-<date>.tar.zst --storage local-lvm --force
pct start <vmid>
```

`--force` overwrites the existing container; leave it out to restore a
destroyed box into a free VMID in 2000-2099 (the archive keeps the hostname
and the `devbox` tag). Run `bin/devbox-sync <client>` afterwards so the job
follows a new VMID. The box comes back as it was at backup time, with the
SSH key, gh and tailscale logins inside it; those may no longer be valid
(`devbox-destroy` deletes the box's keys from GitHub and logs it out of
tailscale), so get a shell in it and run `devbox login`, then `devbox
finish`, which re-adds its key to GitHub.

## devbox-host

```
bin/devbox-host [--dry-run] add [--new-box] <client>
bin/devbox-host [--dry-run] remove <client>
bin/devbox-host [--dry-run] sync
bin/devbox-host doctor
```

The developer-machine side of each box, run on your machine (WSL):

- **ssh config, twice:** a `Host <hostname>` entry (`HostName` the box's
  MagicDNS name, `User daniel`; Tailscale SSH, so no key) in `~/.ssh/config`
  and, on WSL, in the Windows `%USERPROFILE%\.ssh\config` that VS Code
  Remote-SSH reads (found with `cmd.exe` and `wslpath`, or set
  `DEVBOX_WINDOWS_SSH_CONFIG`; not on WSL, only the first). Only the block
  between `# BEGIN devboxes managed` and `# END devboxes managed` is ever
  written, rewritten whole, appended the first time; your own entries stay as
  they are, and the file is copied to `<file>.devboxes.bak` before devboxes
  first writes to it. A stowed (symlinked) config is written through the link.
- **known_hosts:** `remove`, and `add` for a box not yet listed, delete the
  box's old host keys (hostname and MagicDNS name) from the `known_hosts` next
  to each config, so a recreated box's new key doesn't stop ssh or VS Code.
  `add --new-box` (what `devbox-create` runs) deletes them even when the box
  is listed, and re-learns the key for an already saved herdr machine.
- **herdr:** `herdr machine add daniel@<hostname> --label <client>`, skipped
  when already saved; `remove` drops it. Adding needs the box on the tailnet,
  which happens at `devbox login`: until then `add` reports it pending (and
  exits 1); run `bin/devbox-host add <client>` again after logging in. It
  accepts the box's new host key first (over Tailscale, so trusting it on
  first use is safe), since herdr has no terminal to ask. A client whose
  resolved config has `role: runner` gets no herdr machine: `add` (and
  `--dry-run`) says so and removes one saved earlier for that hostname; it
  still gets both ssh config entries.

`sync` rebuilds all of it from the devbox containers on every Proxmox host:
each host a client file in `$DEVBOX_CLIENTS` names in `host`, plus
`$DEVBOX_HOST`. It is for a new laptop or after boxes changed elsewhere: the
blocks list exactly the boxes found across those hosts, herdr machines and
host keys of boxes on none of them are removed, and missing herdr machines
are added, labelled with the client whose file resolves to that hostname, or
the hostname. A runner box's herdr machine is removed instead of added (a box
no client file resolves to counts as a devbox). Boxes are matched by hostname, not VMID, since VMIDs on two
hosts can coincide. `sync` refuses to change anything when a host can't be
listed, when a client file doesn't resolve, or when a client sets no `host`
and `DEVBOX_HOST` is unset. That way a box on one host is never dropped
because another lacks it. It warns of a hostname found on several hosts.
`doctor` checks each box on those hosts (a client file that doesn't resolve
counts as a failure there, though the `host` it names is still checked):
listed in both configs, its MagicDNS name
resolves, `ssh daniel@<hostname> true` works from WSL and from Windows
(`ssh.exe`), and its herdr machine is reachable (for a runner box: that it
has none); it also flags entries for
boxes that are gone, and exits 1 on any failure.

With nothing changed, `add`, `remove` and `sync` write nothing. The MagicDNS
suffix comes from `tailscale status` (`tailscale` or `tailscale.exe`), or
`DEVBOX_TAILNET`.

## Inside a box

`bootstrap.sh` gets pacman working (keyring, mirror, and pacman's download
sandbox turned off when the kernel has no Landlock, as the stock Proxmox one
doesn't), clones this repo to
`/opt/devboxes` at the pinned commit, records the client, branch and the
resolved config it was handed in `/var/lib/devbox/`, then runs `devbox
bootstrap`, which:

- installs the base packages (`base-devel git openssh sudo stow jq go-yq
  unzip less mise github-cli tailscale bash-completion starship zoxide neovim
  tree-sitter-cli ripgrep fd docker docker-buildx docker-compose`; `tree-sitter-cli` builds
  nvim's treesitter parsers), generates the `en_US.UTF-8` locale and enables
  `tailscaled`;
- sets Docker's storage driver, enables `docker.service` and adds `daniel`
  to the `docker` group (below);
- adds user `daniel` with passwordless sudo, and `devbox` on the PATH;
- installs Claude Code (native installer) and puts herdr, the 1Password
  CLI (`op`) and node 26 (global, for `npx`) in mise's system config,
  `/etc/mise/config.toml`;
- stows this repo's `dotfiles/` `bash` and `git` packages into the user's
  home (files in the way are moved to `<file>.bak`), and copies gh's
  `config.yml` and the nvim config, since both tools write there (a re-run
  only adds files missing from the box). The shell prompt is starship's
  (its defaults; a `~/.config/starship.toml` on the box overrides them),
  and `z <fragment>` (zoxide) jumps to directories visited before. The nvim
  config is LazyVim with the plugin versions pinned in `lazy-lock.json`; its clipboard goes over OSC 52,
  so yanks reach your local clipboard through ssh and herdr. They hold no
  identity: git's `user.name`/`user.email` go in `~/.gitconfig.local`, shell
  extras in `~/.bashrc.local`, and git authenticates through `gh`;
- ends with `devbox sync`.

Every step checks first, so re-running `devbox bootstrap` is safe.

```
devbox sync [--no-pacman-upgrade]                 # inside the box, as daniel or root
bin/devbox-sync [--no-pacman-upgrade] <client>    # from your machine
```

`devbox sync` pulls the box's branch of this repo and converges the box to
the client's resolved config. Until gh is logged in, the box can't read the
private clients repo, so that config is the last one it was given
(`/var/lib/devbox/config.json`, from `devbox-create` or `bin/devbox-sync`);
once it is, `devbox sync` clones or pulls `devbox-clients` with gh into
`/opt/devbox-clients` and resolves the client from there, failing if it
can't (not pushed, no network) rather than falling back. `bin/devbox-sync`
instead resolves the config on your machine (uncommitted edits included) and
runs the sync with it over `ssh` and `pct exec`, without pulling. Each sync
stores the config it applied, which `devbox login`, `finish` and `logout`
also read. A sync:

- **packages:** installs listed packages that are missing, and base packages
  added to this repo since the box was bootstrapped. Packages dropped
  from the list since the last sync (recorded in `/var/lib/devbox/packages`)
  are marked as dependencies and removed with `pacman -Rns` unless another
  package still needs them. Base packages are never removed. A client with
  Azure DevOps repos also gets `azure-cli`, as if listed, so it goes when
  the last of them is dropped.
- **tools:** rewrites `/etc/mise/config.toml` when this repo's base tools
  changed, writes `~/.config/mise/config.toml` from `tools:` (a tool listed
  twice gets both versions, the first the default), then `mise install` and
  `mise prune`, which drops versions no config uses.
- **repos:** clones listed repos that are missing into `~/work/<repo>`:
  GitHub ones once gh is logged in, Azure DevOps ones once the box's Azure
  DevOps key is added there (below); until then those are reported pending
  and the rest still clone. Repos dropped from the list are reported, never
  deleted.
- **git identity:** once `devbox finish` has run, re-applies the client's
  `git_name` and `git_email` when they changed.
- **update:** once `devbox finish` has run, `devbox update` as `daniel`
  (below).

With nothing changed, a sync installs and removes nothing.

### Docker

Every box runs Docker, for agents and dev work: `docker`, `docker buildx`
and `docker compose`, as `daniel` without sudo (the `docker` group applies
from the next login). In an unprivileged container it needs the container
features `nesting=1,keyctl=1`, which `devbox-create` sets.

Bootstrap picks the storage driver, written to `/etc/docker/daemon.json`;
`docker info` shows it as `Storage Driver:`:

- **`overlay2`** when the box's rootfs takes an overlay mount, which
  bootstrap tries first. The default `local-lvm` (LVM-thin, ext4) does, and
  so does ZFS 2.2 or later.
- **`fuse-overlayfs`** otherwise (older ZFS), installed then. It needs
  `/dev/fuse`, which `devbox-create` doesn't give the box: on the host, `pct
  set <vmid> --features nesting=1,keyctl=1,fuse=1`, restart the box and
  re-run `devbox bootstrap`. Proxmox warns that fuse in a container can
  deadlock with the freezer, which snapshot backups use.
- **`vfs`** with neither: Docker's own fallback, a full copy of every layer.
  Bootstrap says so.

A box made before Docker was added gets it from `devbox bootstrap` (as
root, in the box) once its features include `keyctl=1`: `pct set <vmid>
--features nesting=1,keyctl=1` on the host, then restart it.

Containers count against the box's own memory limit (`resources.memory_mb`,
plus swap), not the host's, and images fill its own disk. A `--light` box
runs small containers only, one or two light services or a test run, and
holds few images; anything heavier (databases, a compose stack, image
builds) wants a full-size box. `docker stats` and `docker system df` show
what they use.

### Keeping a box current: `devbox update`

```
devbox update [--no-pacman-upgrade]    # inside the box; sync runs it for you
```

Brings current what `devbox finish` and bootstrap installed. It refuses to
run before `finish` has (which leaves `~/.local/state/devbox/finished`; a
box finished before `update` existed needs `devbox finish` once more). Each
step reports what it changed, or `<step>: up to date`; a failing step is
reported and the rest still run, then `update` (and the sync) exits 1:

- **skills:** pulls each skill repo and re-runs its install (as `finish`
  does) when its head moved since the last install, recorded in the clone's
  `.git/devbox-installed`; a failed install is retried next time.
  `mattpocock-skills` is re-added with `npx skills@latest add` when the
  head of `mattpocock/skills` moved (recorded in
  `~/.local/state/devbox/skills/`). Skills newly listed in the client file
  are installed.
- **plugins:** `claude plugin marketplace update`, then `claude plugin
  update` for every user-scope plugin.
- **herdr:** reinstalls each herdr plugin whose GitHub default branch moved
  past the installed commit (herdr has no plugin update; its config is
  kept), and installs missing ones. A plugin linked from a local checkout
  is left alone.
- **pacman:** `pacman -Syu` (Arch upgrades the whole system together, base
  packages included); `--no-pacman-upgrade` skips it.
- **mise:** `mise upgrade` of the tools asked for as `latest` (herdr and
  1password, plus any client `<tool>@latest`), then `mise prune`.
- **claude:** `claude update`.
- **az:** with Azure DevOps repos, `az extension update --name
  azure-devops` (added when missing); `az` itself comes with pacman.
- **configs:** gh's `config.yml` and the nvim config gain files new in this
  repo; files already on the box, edited or not, are left alone. A
  `bin/devbox-sync` doesn't pull the box's checkout, so new files reach it
  once pushed and pulled by a `devbox sync` inside the box.
- **nvim:** `nvim --headless "+Lazy! restore" +qa`, so the plugins match the
  box's `lazy-lock.json` (the repo's, unless edited on the box).

### Logging in and finishing

A new box needs a person once. Get a shell in it (`pct enter <vmid>` on the
host, or as `daniel` once it's on the tailnet), then:

```
devbox login     # interactive; run as daniel (root hands it over)
devbox finish
```

`devbox login` skips what's already done, so re-running it only asks for
what's missing:

- **tailscale:** `sudo tailscale up --ssh --advertise-tags=tag:devbox`;
  open the URL it prints.
- **gh:** `gh auth login` in the browser, with the extra `admin:public_key`
  and `admin:ssh_signing_key` scopes `finish` and `logout` need for the box's
  key (`gh auth refresh` adds them when gh is already logged in).
- **1Password:** paste the client's service-account token (hidden input;
  `op whoami` checks it). Stored in `~/.config/op/service-account-token`,
  mode 600, and exported as `OP_SERVICE_ACCOUNT_TOKEN` by `.bashrc`.
- **Claude:** `claude auth login`, telling you which account the client
  file's `claude_account` names; when already logged in it prints the
  logged-in account to compare.
- **az**, with Azure DevOps repos only: `az login --use-device-code
  --allow-no-subscriptions` (open the URL, enter the code). When the login
  reaches several tenants it lists them and asks which one holds the Azure
  DevOps orgs, making it the default. Then `az extension add --name
  azure-devops`. `az` comes from `devbox sync`; on a box synced before it
  had Azure DevOps repos, sync first.

`devbox finish` then, again skipping what's done:

- generates `~/.ssh/id_ed25519`, unique to the box, and adds it to GitHub
  for authentication and for signing, titled with the box's hostname
  (`dev-<client>` by default);
- writes git's identity and SSH commit and tag signing into
  `~/.gitconfig.local`, with `~/.config/git/allowed_signers` (kept in step
  with the email) so `git log --show-signature` verifies locally. The
  identity is the client's `git_name` and `git_email`, overriding what is
  there; left empty, what is there is kept, or your GitHub name and
  `<id>+<login>@users.noreply.github.com` are set. GitHub shows a signed
  commit as Verified only when its email is a verified address on the
  GitHub account; Azure DevOps doesn't check signatures;
- with Azure DevOps repos (`git@ssh.dev.azure.com:v3/<org>/<project>/<repo>`
  in `repos:`), makes a second key, `~/.ssh/id_rsa_ado` (Azure DevOps only
  takes RSA keys), which ssh uses for `ssh.dev.azure.com` alone, and pins
  that host's key in `~/.ssh/known_hosts` (the RSA key whose fingerprint
  Microsoft documents, `SHA256:ohD8VZEXGWo6Ez8GSEJQ9WpafgLFsOfLOtGGQCQo6Og`;
  never trusted on first use). It does not register the key: until you add
  it in Azure DevOps (User settings -> SSH public keys -> + New Key, titled
  with the box's hostname), `finish` and `sync` print the key and the
  settings page of each org, and report those repos pending;
- installs the `skills:` list: `mattpocock-skills` is every skill in
  `mattpocock/skills`, installed with `npx skills@latest add mattpocock/skills
  --global --agent claude-code --skill '*' --yes` into `~/.claude/skills/`
  (a box that had it as the `mattpocock-skills@claude-plugins-official`
  plugin has that uninstalled); every other entry is a
  GitHub repo (`<owner>/<repo>`, or a bare name under `DanielUlisses`) cloned
  with gh into `~/.claude/skill-repos/` and installed by its layout: its
  `install.sh`, a plugin marketplace (`.claude-plugin/marketplace.json`), or
  a `SKILL.md` at its root linked into `~/.claude/skills/` (`-skill` dropped
  from the name);
- installs the herdr plugins: [reviewr](https://github.com/persiyanov/herdr-reviewr)
  (`herdr plugin install persiyanov/herdr-reviewr`), a pane to review the
  agent's diff and send line comments back to it;
- clones `repos:` into `~/work`, as a sync does. Once the Azure DevOps key
  is added, `devbox sync` (or `finish` again) clones the pending ones.

`devbox logout` undoes the outward-facing part: deletes the GitHub keys that
match the box's public key or carry its title, `az logout` when az is
logged in, and `tailscale logout`. The Azure DevOps key has to be removed by
hand: it prints the key's title and fingerprint to delete under User settings -> SSH public keys. `bin/devbox-destroy` runs
it for you.

## Working in a box

Once a box is finished, everything happens in herdr on the box, reached from
your machine over the tailnet.

### Remote herdr

```
herdr --remote daniel@dev-<client>
```

attaches your local herdr client to the box's herdr server over SSH (Tailscale
SSH, so no key to manage). The session persists on the box: detach, close the laptop, and the next `herdr
--remote` picks up the same workspaces and panes. `--session <name>` picks a
named session; `--remote-keybindings server` uses the box's keybindings
instead of yours.

### Claude in worktrees

Each ticket gets its own git worktree under `~/work`, next to the clone, and
its own herdr pane or tab with Claude running in it, so tickets don't share a
checkout:

```
cd ~/work/<repo>
git worktree add ../<repo>--<ticket> -b <ticket>
cd ../<repo>--<ticket> && claude
```

The ticket framework comes with the skills `devbox finish` installs (the
`skills:` list): Claude implements the ticket in the
worktree, reviews it, and leaves the change unstaged for you to review,
commit and push. `herdr worktree create` makes the worktree and opens it as
a herdr workspace in one step.

### Azure DevOps pull requests

In a clone (or worktree) of an Azure DevOps repo, after `devbox login`:

```
az repos pr create --draft --title "<title>" --description "<text>"
```

needs no other flags and asks nothing: the azure-devops extension reads the
org, project and repo from the clone's `origin`
(`git@ssh.dev.azure.com:v3/<org>/<project>/<repo>`), takes the current
branch as the source and the repo's default branch as the target. Push the
branch first. Outside a clone, name them:
`az repos pr create --org https://dev.azure.com/<org> --project <project>
--repository <repo> --source-branch <branch>`.

### Remote Control: `devbox rc`

```
devbox rc [<name>]
```

Run inside herdr on the box, as `daniel`. It opens a pane to the right of the
current one, in `~/work`, running `claude --remote-control [<name>]`. The
session then shows up in the Claude app (desktop, mobile, claude.ai/code)
under that name, or the box's hostname when there is none, so you can follow
and steer it away from the laptop; it also stays a normal Claude session in
its herdr pane. Close it with `/exit` or by closing the pane. It needs `devbox
login` done (Claude logged in) and refuses outside herdr.

### Tailscale ACL

Boxes join the tailnet as `tag:devbox`. They hold client credentials, so only
your own devices reach them, and they reach nothing: no box-to-box traffic
and no way back to your machines. In the tailnet policy file (admin console,
Access controls), with `<you>` your own login:

```jsonc
{
  "tagOwners": {
    // devbox login advertises this tag; only you may apply it.
    "tag:devbox": ["<you>"]
  },
  "grants": [
    // Your own devices reach the boxes. Nothing grants tag:devbox as a
    // source, so boxes reach neither each other nor anything else.
    { "src": ["<you>"], "dst": ["tag:devbox"], "ip": ["*"] }
  ],
  "ssh": [
    // Tailscale SSH into a box (herdr --remote), as daniel, from your devices.
    {
      "action": "accept",
      "src":    ["<you>"],
      "dst":    ["tag:devbox"],
      "users":  ["daniel"]
    }
  ]
}
```

Merge these into your existing policy, and remove the default allow-all
rule (`"src": ["*"], "dst": ["*:*"]`) or any other rule whose `src` matches
`tag:devbox`, or boxes can reach everything again. Check from a box that
`nc -zv dev-<other-client> 22` fails.

## Runner boxes

A client file with `role: runner` describes a runner box: an LXC like any
devbox, made, synced and destroyed by the same scripts, that will host CI
runners (added by a later change) on a shared host. It carries none of a
devbox's developer tooling or credentials. Its client file usually sets
`hostname` itself, to drop the `dev-` prefix, and `host` to the shared host;
`claude_account` isn't needed.

- **What it skips.** `devbox bootstrap` installs only the base packages a
  runner needs (`git sudo jq go-yq unzip less mise tailscale docker
  docker-buildx docker-compose`), Docker, Tailscale and the 1Password CLI:
  no Claude, skills, nvim, dotfiles, mise dev tools, repos or git identity.
  `op` is installed by root with mise into `/opt/mise` and linked as
  `/usr/local/bin/op`, outside any home, so the runner user can run it.
  `devbox finish` and `devbox update` refuse on a runner box; `devbox sync`
  converges it. A runner has no gh, so a sync inside the box reuses the
  config it was last given; client-file changes reach it through
  `bin/devbox-sync <client>` from your machine.
- **The runner user.** `devbox sync` adds `ghrunner`, a system user that
  is not in `wheel` and has no login shell, and closes every home under
  `/home` to other users (mode 700). `daniel` stays the admin login, with
  sudo.
- **Logins.** `devbox login` asks only for Tailscale, joining as
  **`tag:runner`** (not `tag:devbox`), and the runner's 1Password
  service-account token, checked with `op whoami`. No gh, Claude or az. The
  token goes in `/etc/ghrunner/op-service-account-token`: the directory is
  `root:ghrunner`, mode 750, so only root and `ghrunner` enter it and
  `ghrunner` can't add or swap files there; the file is `root:ghrunner`,
  mode 640, so root owns it and `ghrunner` (alone in its own group) can
  only read it. 640 rather than 600: a root-owned 600 file would shut
  `ghrunner` out. It is never in a home directory.
- **Resources.** `defaults.yaml`'s `runner_resources` replaces `resources`
  for a runner: CPU weight (`cpuunits`) 50 against the default 100, so the
  HA VM and other guests win under contention; 3 GB memory plus 1 GB swap,
  a 4 GB hard cap; 2 cores; a 16 GB disk. A runner's own `resources:` still
  overrides it key by key. `devbox-create --dry-run` shows all of them in
  the `pct create` line.
- **No LAN listeners.** `devbox sync` masks `sshd` (Tailscale SSH serves the
  tailnet; `pct enter` on the host still works) and turns off
  systemd-resolved's LLMNR and mDNS listeners. It then reports anything
  still listening beyond loopback and the tailnet. The one expected
  exception is tailscaled's WireGuard UDP port, which accepts only packets
  from tailnet peers.
- **No herdr machine.** You reach a runner as `daniel` over Tailscale SSH
  (`ssh <hostname>`; `bin/devbox-host` still writes its ssh config entries),
  not through herdr: `bin/devbox-host` saves no herdr machine for it and
  `sync` removes one saved before. See [devbox-host](#devbox-host).
- **No backup job.** On a shared host `lib/pve.sh` refuses host-level
  changes, so a runner box there gets no backup job, whatever `backup`
  says. That is fine: the box holds no state worth restoring. Its config
  is in `devbox-clients`, its token in 1Password, and a broken box is
  destroyed and created again.

In the tailnet policy, `tag:runner` needs its own `tagOwners` entry and the
same kind of grant and ssh rule as `tag:devbox` (see [Tailscale
ACL](#tailscale-acl)), with nothing granting `tag:runner` as a source.

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
- **Landlock:** adds `landlock` to the front of the kernel's `lsm=` list,
  keeping the other modules in order, so pacman's download sandbox works
  inside Arch boxes. On systemd-boot (ZFS on UEFI) it edits
  `/etc/kernel/cmdline`; on GRUB it edits `GRUB_CMDLINE_LINUX_DEFAULT` in
  `/etc/default/grub`. Then it runs `proxmox-boot-tool refresh` where that
  tool manages the boot partitions (ZFS installs), `update-grub` otherwise. **It takes a reboot:** until
  `cat /sys/kernel/security/lsm` lists `landlock`, every run says so, and
  boxes created before then get the sandbox turned off by `bootstrap.sh`.
- **Root SSH key:** adds the `--ssh-key` keys to root's `authorized_keys`, then
  turns off password login over SSH.
- **Tailscale:** installs it, starts `tailscaled`, joins the tailnet.
- **Firewall:** the datacenter firewall drops all inbound traffic except over
  Tailscale, so neither the WAN nor the LAN can reach SSH or the web UI. The
  one exception is Home Assistant (`HOME_ASSISTANT_IP`), which may reach the
  API on port 8006.
  It is only switched on once Tailscale is up. After that, use
  `https://<tailscale-ip>:8006` and `ssh root@<tailscale-ip>`.
- **Template:** downloads the latest `archlinux-base` LXC template to `local`.

If the firewall ever locks you out, log in on the physical console and run
`pve-firewall stop`.

### A shared host on the tailnet

`setup.sh --apply` refuses a host that already runs other guests. To reach
such a host over the tailnet anyway, `host/tailscale-only.sh` switches it
from the enterprise repos (disabled, as they need a subscription) to
`pve-no-subscription` (added unless already there), installs Tailscale from
its own apt repo, starts it and joins the tailnet. It changes no firewall,
SSH or boot settings, and is safe to re-run:

```
scp host/tailscale-only.sh root@<host>:
ssh -t root@<host> ./tailscale-only.sh     # TS_AUTHKEY=... to skip the login URL
```

## No secrets

This repo is public, so client files live in the private `devbox-clients`
repo. They still hold names, sizes and lists only: no tokens, passwords,
keys or email addresses, except `git_email`, the address commits are made
with. `claude_account` is a label, not the account's email. `devbox-config`
rejects any other value that looks like an email address (an Azure DevOps
SSH URL, `git@ssh.dev.azure.com:...`, is not one).
