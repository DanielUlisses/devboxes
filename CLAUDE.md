# devboxes

Per-client dev VMs, described in YAML. README.md has the layout and the
add-a-client flow.

## Rules

- **Public repo.** Every file holds values safe to publish: names, sizes, lists. Secrets, tokens, keys and email addresses live outside the repo; `claude_account` is a label.
- **Schema has one home.** `clients/_template.yaml` documents every field, `defaults.yaml` holds every default (except `hostname`, derived from the client name in `bin/devbox-config`), and the validator in `bin/devbox-config` enforces both. A schema change touches all three together.
- **Consumers read the resolved config.** Later scripts call `bin/devbox-config --json <client>` and read its output, so merging and validation stay in one place.
- **Underscore-prefixed files in `clients/` are not clients.** `_template` still resolves (as hostname `dev-template`) so the template stays valid.

## Checks

No test suite. After changing `bin/`, `host/`, `lib/`, `bootstrap.sh` or the schema:

```
shellcheck bin/* host/* bootstrap.sh
bin/devbox-config _template
```

and run a deliberately broken client file to confirm the error names the field.
