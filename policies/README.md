# policies/

Conftest (OPA) policies enforced in `pr.yaml`. Each rule denies a manifest that
violates a platform-team convention.

## Rules

| Rule | What it denies | Why |
|---|---|---|
| `deny_wildcard_hosts` | `HTTPRoute` with `hostnames: ["*"]` | Forces explicit hostnames or namespace-scoped attachment; a wildcard route can shadow other teams' traffic. |
| `require_route_timeout` | `HTTPRoute` rule missing `timeouts.request` | A route without an explicit request timeout inherits Kong's default, which is too generous for shared infra. |
| `plugin_allowlist` | `KongPlugin` whose `plugin` is not in the allowlist | Stops app teams from enabling plugins (e.g. `pre-function`, custom auth) that haven't been reviewed by the platform team. |

## Running locally

```bash
# Render each tier and pipe into conftest.
kustomize build manifests/platform     | conftest test --policy policies/ -
kustomize build manifests/apps/httpbin | conftest test --policy policies/ -
```

A non-zero exit means at least one rule fired. The error message names the
offending file, kind, namespace, and rule.

## Extending the allowlist

Edit `kong.rego`'s `allowed_plugins` set. Changes to the allowlist require a
platform-team review (enforced via `.github/CODEOWNERS`).
