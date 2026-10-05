# devboxes

Per-client dev VMs, described in YAML. README.md has the layout and the
add-a-client flow.

## Rules

- **Public repo.** Every file holds values safe to publish: names, sizes, lists. Secrets, tokens, keys and email addresses live outside the repo; `claude_account` is a label.
- **Schema has one home.** `clients/_template.yaml` documents every field, `defaults.yaml` holds every default (except `hostname`, derived from the client name in `bin/devbox-config`), and the validator in `bin/devbox-config` enforces both. A schema change touches all three together.
- **Consumers read the resolved config.** Later scripts call `bin/devbox-config --json <client>` and read its output, so merging and validation stay in one place.
- **Client files live in the private `DanielUlisses/devbox-clients` repo**, never here: `bin/devbox-config` reads them from `$DEVBOX_CLIENTS` (default `../devbox-clients`). Only underscore-prefixed files stay in `clients/`; they are not clients, and `_template` still resolves (as hostname `dev-template`) so the template stays valid.

## Checks

One-time setup per clone: `git config core.hooksPath .githooks`. The
pre-commit hook runs the checks below on staged content and refuses secrets,
emails and deny-listed host names (`.git/devbox-deny-hosts`).

No test suite. After changing `bin/`, `host/`, `lib/`, `bootstrap.sh` or the schema:

```
shellcheck bin/* lib/*.sh host/* bootstrap.sh .githooks/* dotfiles/bash/.[!.]*
bin/devbox-config _template
```

and run a deliberately broken client file to confirm the error names the field.
