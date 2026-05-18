# Architecture

End-to-end CI/CD demo for Kong gateway configuration on Kubernetes, managed by
the Kong Gateway Operator with Konnect (AU region) as the control plane and
Argo CD pulling manifests from this Git repository.

## Two-tier ownership model

This repo intentionally contains the manifests for **two different owners**:

| Tier | Path | Owner | Cadence | Argo CD `Application` |
|---|---|---|---|---|
| Platform | `manifests/platform/` | Platform team | Slow (1–5 PRs/month) | `platform` |
| App | `manifests/apps/httpbin/` | App-team-a | Fast (many PRs/day) | `httpbin` |

The platform team owns the gateway itself (the `Gateway` resource, the
`GatewayClass`, the Konnect wiring, the `GatewayConfiguration`). App teams own
the things that flow through the gateway (`HTTPRoute`, `KongPlugin`,
`KongConsumer`, the upstream service). The split mirrors how real organisations
operate Kong at scale; cramming both into one repo with one Argo `Application`
collapses that boundary and forces a single approval queue.

## Three-layer separation of concerns

A single repo can't enforce ownership purely through repo permissions. This
demo layers three controls that together approximate what separate repos give
you for free.

| Layer | When | Mechanism | Enforces |
|---|---|---|---|
| 1. PR-time | Before merge | `.github/CODEOWNERS` + branch protection | Human review by the correct owner |
| 2. Sync-time | Argo CD reconcile | `Application.source.path` + `AppProject` whitelists | Each Application can only deploy its path's resources |
| 3. Apply-time | Kubernetes API server | (Optional) Application impersonation via per-tier `ServiceAccount` | API server refuses out-of-scope writes |

Layer 3 is off by default to keep the first demo run simple. See
`argocd/rbac/README.md` to turn it on.

**Caveat noted in `docs/superpowers/specs/`:** even all three layers don't stop
a platform-team member from merging a bad change. The real production fix is
separating into two repos so the app team doesn't have write access to platform
files at all. The demo teaches the controls; the controls are not a substitute
for repo separation.

## Pipeline architecture

```
                  Developer
                     │
                     ▼
                  GitHub
              ┌─────┴─────┐
        Pull request    Push to main
              │            │
              ▼            ▼
           pr.yaml      main.yaml
        (fast lane)   (full E2E)
              │            │
              │      ┌─────┴───────────────────────┐
              │      ▼                             │
              │  Terraform                         │
              │  apply ─────▶ Konnect AU CP        │
              │                                    │
              │      ▼                             │
              │   kind cluster                     │
              │      │                             │
              │      ▼                             │
              │   bootstrap.sh                     │
              │   (operator + Argo CD)             │
              │      │                             │
              │      ▼                             │
              │   apply AppProjects + Applications │
              │      │                             │
              │      ▼                             │
              │   Argo CD syncs from this repo     │
              │   ├─ platform → manifests/platform │
              │   └─ httpbin  → manifests/apps/httpbin
              │      │                             │
              │      ▼                             │
              │   tests/smoke.sh + tests/k6        │
              │      │                             │
              │      ▼                             │
              │   cleanup (kind delete + tf destroy)
              │                                    │
              ▼                                    ▼
        (always green if    (only green if Kong is enforcing
         lint+render+policy   routing, rate-limit, and key-auth)
         pass)
```

### `pr.yaml` — fast lane (~1 min)

Three parallel jobs:
- **schema** — `kubeconform` against upstream and CRDs-catalog schemas
- **render** — `kustomize build` each tier; fails on overlay errors
- **policy** — `conftest test` against `policies/kong.rego` (wildcard hosts, missing timeouts, plugin allowlist)

No cluster, no Konnect, no secrets needed.

### `main.yaml` — full E2E (~10 min)

Three sequential jobs:
1. **terraform-up** — `terraform apply` creates `kong-cicd-demo` Konnect CP in AU.
2. **deploy-and-test** — kind cluster, operator + Argo CD install, AppProjects + Applications applied, Argo waits for `Healthy + Synced`, smoke + k6 functional tests.
3. **cleanup** (always runs) — `terraform destroy`.

The workflow `concurrency: kong-cicd-main` ensures only one run executes at a
time, so the fixed CP name never collides.

## Why fixed CP name vs per-run

An earlier design draft templated `KonnectExtension.spec.konnect.controlPlane.ref.name`
with `${{ github.run_id }}` and tried to commit the rendered manifest to a
temporary branch so Argo CD could pull it. That design didn't work cleanly —
Argo pulls from `main`, not the runner's working dir, so the templated value
would never reach the cluster without an extra commit step.

The simpler design: one fixed CP name (`kong-cicd-demo`), serial runs via
GitHub Actions `concurrency`. Each run creates the CP, the deploy succeeds
because the manifest's hardcoded name matches, and `terraform destroy` removes
the CP on the way out.

## Non-goals (deliberately excluded)

Documented here so they're visible as the upgrade path:

| Not in demo | Production answer |
|---|---|
| Multi-env overlays (dev/stg/prod) | Add `manifests/platform/envs/{dev,stg,prod}/` overlays with Kustomize `patches`. Drive promotion with an Argo CD `ApplicationSet` (Git generator). |
| External Secrets Operator | Replace the manually-created `konnect-token` Secret with an `ExternalSecret` pointing at AWS/GCP/Azure SM. |
| Drift detection | `deck gateway dump` on a nightly schedule against the prod CP, committed to a backup repo. |
| Argo CD Notifications | Slack/Teams alerts on `OutOfSync` / `Degraded` Application states. |
| Per-PR preview clusters | `ApplicationSet` PullRequest generator + ephemeral namespaces. |
| Promotion automation | Kargo for stage-by-stage promotion, or a PR bot that opens `dev → stg → prod` PRs. |
| TLS / HTTPS listener | Add a TLS listener to `Gateway`, install `cert-manager`, automate cert issuance. |
| Self-managed Kong (no Konnect) | Remove `KonnectAPIAuthConfiguration` and `KonnectExtension`, use the operator's standalone DataPlane + ControlPlane. |

## File map

See repository root layout — every file is referenced in this design.

## Source of truth

The full design history lives at
`/Users/.../DataAction/docs/superpowers/specs/2026-05-17-kong-cicd-demo-design.md`
in the shared workspace. This file mirrors the customer-facing pieces of that
spec.
