# Architecture

This repository is the **CRD source of truth** for a Kong gateway running on
Kubernetes with Konnect (AU region) as the control plane. Cluster, Kong Gateway
Operator, and Argo CD are deployed and managed **outside the manifests** (see
`./helm/deploy-argocd.sh` for an Argo CD installer and other deployment scripts).

Every Kong-side object — the Konnect control plane itself, the API-auth
configuration, the data-plane wiring, the gateway, the routes, the plugins —
is expressed as a Kubernetes Custom Resource committed to this repo. Argo CD
syncs the resources into the cluster; the Kong Operator reconciles
them, talking to Konnect via the Konnect API.

## What lives where

| Concern | Where | Notes |
|---|---|---|
| Kubernetes cluster | External | Any conformant cluster (kind, EKS, AKS, GKE, on-prem) |
| Kong Operator | External | Installed via Helm; required CRDs come with it |
| Argo CD | External | Use `./helm/deploy-argocd.sh` for a one-line install |
| Konnect token (Secret) | External | Created out-of-band; `KonnectAPIAuthConfiguration` references it |
| Konnect control plane | **This repo** | Auto-created by `Gateway` via `KonnectGatewayControlPlane` |
| Gateway + data plane wiring | **This repo** | `Gateway`, `GatewayClass`, `GatewayConfiguration` (auto-creates DataPlane, KonnectExtension) |
| HTTPRoutes, plugins, consumers | **This repo** | App tier under `manifests/apps/<app>/` |
| Argo CD `AppProject`s, `Application`s | **This repo** | Defines what Argo CD syncs and where |
| Conftest policies | **This repo** | Enforced in PR CI |

## Two-tier ownership model

| Tier | Path | Owner | Argo `Application` |
|---|---|---|---|
| Platform | `manifests/platform/` | Platform team | `platform` |
| App | `manifests/apps/httpbin/` | App-team-a | `httpbin` |

The platform team owns the gateway itself (the `Gateway` resource, the
`GatewayClass`, the Konnect wiring, the Konnect control plane CR). App teams
own the things that flow through the gateway (`HTTPRoute`, `KongPlugin`,
`KongConsumer`, the upstream service). The split mirrors how real organisations
operate Kong at scale.

## Three-layer separation-of-concerns

A single repo can't enforce ownership purely through repo permissions. Three
layered controls together approximate what separate repos give you for free.

| Layer | When | Mechanism | Enforces |
|---|---|---|---|
| 1. PR-time | Before merge | `.github/CODEOWNERS` + branch protection | Human review by the correct owner |
| 2. Sync-time | Argo CD reconcile | `Application.source.path` + `AppProject` whitelists | Each Application can only deploy its path's resources |
| 3. Apply-time | Kubernetes API server | (Optional) Application impersonation via per-tier `ServiceAccount` | API server refuses out-of-scope writes |

Layer 3 is off by default. See `argocd/rbac/README.md` to turn it on.

## Reconciliation flow

```
                     This Git repo
                          │
                          │ (Argo CD pulls)
                          ▼
                  ┌────────────────────┐
                  │ Argo CD            │  (external, managed once)
                  │                    │
                  │ Application:       │
                  │  - platform        │
                  │  - httpbin         │
                  └─────────┬──────────┘
                            │ kubectl apply
                            ▼
            ┌────────────────────────────────┐
            │ Kubernetes cluster             │
            │                                │
            │  Namespace: kong               │
            │   KonnectAPIAuthConfiguration  │
            │   KonnectGatewayControlPlane   │◄──┐
            │   KonnectExtension             │   │
            │   GatewayClass                 │   │
            │   GatewayConfiguration         │   │
            │   Gateway                      │   │
            │                                │   │
            │  Namespace: httpbin            │   │  Kong Operator
            │   Deployment / Service         │   │  watches these CRs,
            │   HTTPRoute                    │   │  talks to Konnect API,
            │   KongPlugin (rate-limit, key-auth)  │  reconciles Konnect-side state
            │   KongConsumer + key-auth Secret │ │
            └─────────────────────────────────┘  │
                            │                    │
                            ▼                    │
                  ┌─────────────────────┐        │
                  │ Konnect (AU region) │────────┘
                  │  - control plane    │
                  │  - data-plane certs │
                  │  - config sync      │
                  └─────────────────────┘
```

Sequence on initial sync:

1. Argo CD applies `manifests/platform/` to namespace `kong`.
2. Operator sees `Gateway` + `GatewayConfiguration` (with `konnect.authRef`),
   auto-creates `KonnectGatewayControlPlane`, calls the Konnect API, creates
   a control plane in Konnect.
3. Operator auto-creates `KonnectExtension`, requests client certificates from
   Konnect, stores them in a Kubernetes Secret.
4. Operator auto-creates `DataPlane` pods (via ownerReferences from Gateway),
   points them at the Konnect CP, opens the proxy listener.
5. Argo CD applies `manifests/apps/httpbin/`. In Konnect hybrid mode with
   `konnect.source: Origin`, Gateway API resources (HTTPRoute) require Kong
   Ingress Controller for translation. Alternatively, use Kong-native CRDs
   (KongService, KongRoute) which sync directly.
6. Konnect propagates the config back down to the data plane via the
   long-lived client cert connection. Traffic starts flowing.

No Terraform. No in-repo cluster bootstrap. No in-CI cluster manipulation.

## CI pipeline

Only one workflow: `.github/workflows/pr.yaml`. It validates manifests at PR
time and is the **only** check this repo enforces in CI.

| Job | Tool | Purpose |
|---|---|---|
| `schema` | kubeconform | Schema-check manifests against upstream + CRDs-catalog schemas |
| `render` | kustomize | `kustomize build` each tier; fails on overlay errors |
| `policy` | conftest | Enforces `policies/kong.rego` rules (wildcard hosts, missing timeouts, plugin allowlist) |

There is **no** `main` workflow. Deployment is implicit: a merge to `main`
becomes the new revision Argo CD pulls. Argo CD's reconcile loop (default 3
min, or webhook-triggered) does the apply.

## Konnect token Secret

The `KonnectAPIAuthConfiguration` references a `Secret` named `konnect-api-auth`
in the `kong` namespace, with key `token`. The secret requires labels:
- `konghq.com/credential: konnect`
- `konghq.com/secret: "true"`

Creating this Secret is **out of scope** for the manifests. Pick one of:

- **Operator script** (demo / dev): `./helm/deploy-kong-operator.sh --konnect-token kpat_...` (creates secret with labels)
- **Manual** (demo / dev): See README for manual creation with required labels
- **External Secrets Operator** (production): an `ExternalSecret` pulls the
  value from your cloud's Secret Manager / Vault and materialises the K8s
  Secret. Recommended for prod.
- **Sealed Secrets / SOPS** (production alternative): an encrypted Secret is
  committed to a separate ops repo, decrypted at apply time.

The `kong-cicd-app-httpbin` and `kong-cicd-platform` `AppProject`s do **not**
include the `konnect-api-auth` Secret in their `namespaceResourceWhitelist`s for
the platform Project — that's deliberate. The Secret is bootstrap, not
reconciled.

## Non-goals (deliberately excluded)

| Not in repo | Production answer |
|---|---|
| Cluster creation | External — Terraform/CF/whatever creates the cluster |
| Kong Operator install | External — see `./helm/deploy-kong-operator.sh` |
| Argo CD install | External — see `./helm/deploy-argocd.sh` |
| Konnect token provisioning | External — ESO + cloud Secret Manager in prod |
| Multi-env overlays (dev/stg/prod) | Add `manifests/platform/envs/*` and an `ApplicationSet` |
| Drift detection | `deck gateway dump` cron in a separate ops repo |
| Argo CD Notifications | Configure in the Argo CD install, not here |
| Promotion automation | Kargo, or PR-bot that bumps `targetRevision` per env |
| TLS / HTTPS listener | Add TLS listener to `Gateway` + cert-manager |

## File map

```
.github/
  CODEOWNERS                          Layer-1 control
  workflows/pr.yaml                   only CI workflow
argocd/
  projects/platform.yaml              AppProject for platform tier
  projects/app-httpbin.yaml           AppProject for app tier
  app-platform.yaml                   Application → manifests/platform
  app-httpbin.yaml                    Application → manifests/apps/httpbin
  rbac/                               optional Layer-3 impersonation
helm/
  deploy-kong-operator.sh             Install Kong Operator with optional secret creation
  deploy-argocd.sh                    Install Argo CD
  deploy-*.sh                         Other infrastructure scripts
manifests/
  platform/                           platform-team tier (Argo app: platform)
    namespace.yaml
    konnect-api-auth.yaml             KonnectAPIAuthConfiguration → token Secret
    gatewayclass.yaml                 GatewayClass with Kong Operator controller
    gatewayconfiguration.yaml         Gateway config with konnect.authRef
    gateway.yaml                      Gateway (auto-creates CP, Extension, DataPlane)
    kustomization.yaml
  apps/httpbin/                       app-team tier (Argo app: httpbin)
    namespace.yaml
    deployment.yaml + service.yaml    upstream httpbin
    httproute.yaml                    /headers + /status routes
    kongplugin-rate-limit.yaml
    kongplugin-key-auth.yaml
    kongconsumer.yaml + credentials Secret
    kustomization.yaml
policies/
  kong.rego                           Conftest rules
  README.md
tests/
  smoke.sh                            gateway-up check (manual run, not CI)
  k6-functional.js                    rate-limit + key-auth (manual run, not CI)
docs/
  architecture.md                     this file
  runbook.md                          how to install prerequisites + apply
```
