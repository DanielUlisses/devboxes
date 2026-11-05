# Project memory

Durable facts about this repo that the code does not make obvious.

- `bin/devbox-config` reads client files from `$DEVBOX_CLIENTS/clients/<name>.yaml`, so a temp fixture dir needs a `clients/` subdir. A runner (`role: runner`) needs `runners.org` and non-empty `runners.labels`. To add a validator case, put a file in `tests/config/` (see Checks in `CLAUDE.md` for the `# expect:` line); `bin/devbox-check` copies it to a scratch `clients/` dir and sets `DEVBOX_CLIENTS`.
- `bin/devbox-config` runs its email scan over every string except `git_email` and ADO URLs under `repos`. A new field whose values contain `@` must not look like an email address (user, `@`, dotted domain), or must be exempted from the scan.
- The jq program in `bin/devbox-config` is in single quotes: write a `'` inside it as `'"'"'`. A def must come after the helpers it calls.
- In `bin/devbox`, an update step's changes are counted in the `CHANGES` file. Functions must report through `changed`, prefixed with the step name, not `say`, or the step shows "up to date".
- `claude plugin list --json` lists `user`, `project`, `local` and `synced` scopes. `plugin_installed` filters on `.scope == "user"`, and every installed check goes through it, so a new plugin installed-check must use `plugin_installed`.
- `update` does `cd "$USER_HOME"` before its steps, but `finish` runs in whatever directory it was started from. Behaviour that depends on the current directory, such as project-scope plugins, can differ between them.
- Docker bind-mounts `/etc/resolv.conf`, `/etc/hosts` and `/etc/hostname` into a runner job's sandbox, so `bin/devbox-runner-job` must exclude them from its copy of the box's `/etc`, or tar fails writing to them. Its `dockerd` needs `--exec-opt native.cgroupdriver=cgroupfs` (no systemd inside) and the cgroup move in `setup_cgroups`, or containers fail to start under cgroup v2.
- `/var/lib/docker` on a runner box must be `discard` only. `nosuid` or `nodev`, as on `/tmp`'s volume, break images. A runner's jobs must never get the box's Docker socket: its `docker volume prune` and image prune assume everything there is either a sandbox or the mirror.
- The marketplace name after `@` in a plugin id comes from the marketplace's own manifest, not from its `<owner>/<repo>`.
