# devboxes

One dev VM per client, each described by a small YAML file in this repo.

## Layout

```
defaults.yaml          defaults every client inherits (resources, base skills)
clients/_template.yaml documented template; every field explained
clients/<client>.yaml  one file per client
bin/devbox-config      prints a client's resolved config, or fails naming the bad field
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

## No secrets

This repo is public. Client files hold names, sizes and lists only: no
tokens, passwords, keys or email addresses. `claude_account` is a label, not
the account's email. `devbox-config` rejects any value that looks like an
email address.
