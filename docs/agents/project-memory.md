# Project memory

Durable facts about this repo that the code does not make obvious.

- `bin/devbox-config` reads client files from `$DEVBOX_CLIENTS/clients/<name>.yaml`, so a temp fixture dir needs a `clients/` subdir. A runner (`role: runner`) needs `runners.org` and non-empty `runners.labels`. To add a validator case, put a file in `tests/config/` (see Checks in `CLAUDE.md` for the `# expect:` line); `bin/devbox-check` copies it to a scratch `clients/` dir and sets `DEVBOX_CLIENTS`.
- `bin/devbox-config` runs its email scan over every string except `git_email` and ADO URLs under `repos`. A new field whose values contain `@` must not look like an email address (user, `@`, dotted domain), or must be exempted from the scan.
- The jq program in `bin/devbox-config` is in single quotes: write a `'` inside it as `'"'"'`. A def must come after the helpers it calls.
- In `bin/devbox`, an update step's changes are counted in the `CHANGES` file. Functions must report through `changed`, prefixed with the step name, not `say`, or the step shows "up to date".
- `claude plugin list --json` lists `user`, `project`, `local` and `synced` scopes. `plugin_installed` filters on `.scope == "user"`, and every installed check goes through it, so a new plugin installed-check must use `plugin_installed`.
- `update` does `cd "$USER_HOME"` before its steps, but `finish` runs in whatever directory it was started from. Behaviour that depends on the current directory, such as project-scope plugins, can differ between them.
- The marketplace name after `@` in a plugin id comes from the marketplace's own manifest, not from its `<owner>/<repo>`.
