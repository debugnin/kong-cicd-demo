# Runbook

How to install the external prerequisites, point them at this repo, and apply.
This repo contains **only Kong CRDs** — cluster, operator, Argo CD, and the
Konnect token Secret are all managed outside.

## Prerequisites

| Component                                  | Where                                              | Version              |
| ------------------------------------------ | -------------------------------------------------- | -------------------- |
| Kubernetes cluster                         | Provided by you                                    | ≥ 1.30               |
| Kong Operator (chart `kong/kong-operator`) | Installed in the cluster                           | ≥ 2.1                |
| Gateway API CRDs                           | Installed in the cluster                           | ≥ v1.4.1             |
| Argo CD                                    | Installed in the cluster                           | ≥ v3.4 (chart ≥ 9.5) |
| Konnect account                            | AU region                                          | —                    |
| `KONNECT_TOKEN`                            | PAT or service-account token with CP create/delete |                      |

## One-time setup (do this once per cluster)

### 1. Cluster

Provide your own — kind for local, EKS/AKS/GKE/on-prem for real. This repo
does not opine.

```bash
# Local kind example (run from anywhere outside this repo):
kind create cluster --name kong-cicd-demo
```

### 2. Kong Operator

Use the script in this repo (matches
[Kong's official install guide](https://developer.konghq.com/operator/get-started/gateway-api/install/)):

```bash
./helm/deploy-kong-operator.sh
```

The script installs the Gateway API CRDs (`v1.4.1`, server-side apply) and the
`kong/kong-operator` Helm chart into namespace `kong-system`, with
`ENABLE_CONTROLLER_KONNECT=true` so the operator reconciles
`KonnectGatewayControlPlane` / `KonnectExtension` /
`KonnectAPIAuthConfiguration` CRs.

Optionally create the Konnect secret during install:

```bash
./helm/deploy-kong-operator.sh --konnect-token "kpat_..."
```

Run `./helm/deploy-kong-operator.sh --help` for flag overrides
(version pin, namespace, cert-manager hook).

### 3. Argo CD

Use the script in this repo:

```bash
./helm/deploy-argocd.sh
```

### 4. Konnect token Secret

```bash
# Option 1: Use the operator deployment script
./helm/deploy-kong-operator.sh --konnect-token "kpat_..."

# Option 2: Create manually with required labels
kubectl create namespace kong
kubectl -n kong create secret generic konnect-api-auth \
  --from-literal=token="kpat_..." \
  --dry-run=client -o yaml | \
  kubectl label -f- --local --dry-run=client -o yaml \
    konghq.com/credential=konnect konghq.com/secret=true | \
  kubectl apply -f -
```

The secret requires:

- Name: `konnect-api-auth` (referenced by KonnectAPIAuthConfiguration)
- Label: `konghq.com/credential=konnect` (required for operator discovery)
- Label: `konghq.com/secret="true"` (required for operator discovery)

Production: replace this with an `ExternalSecret` from your cloud's Secret
Manager / Vault. Not committed to this repo.

### 5. Argo CD project + Applications

```bash
# From the root of this repo:
kubectl apply -f argocd/projects/
kubectl apply -f argocd/app-platform.yaml -f argocd/app-httpbin.yaml
```

Argo CD will now pull from `https://github.com/debugnin/kong-cicd-demo@main`
and sync the manifests. The Kong Gateway Operator reconciles the `Gateway`
resource, which auto-creates:

- `KonnectGatewayControlPlane` (creates a CP in Konnect AU region)
- `KonnectExtension` (wires DataPlane to CP)
- `DataPlane` pods (via ownerReferences)

All resources are owned by the Gateway and managed via ownerReferences.

## Day-2 operation

### Adding a route or plugin

1. Open a PR that adds/edits files under `manifests/apps/<app>/`.
2. PR CI runs `pr.yaml` (kubeconform + kustomize + conftest).
3. After approval and merge, Argo CD picks up the change on its next reconcile
   (default 3 min, or trigger immediately via Argo's webhook).
4. Config propagates to Konnect; the data plane picks it up.

**Note**: HTTPRoute requires Kong Ingress Controller for translation in Konnect
hybrid mode. Alternatively, use Kong-native CRDs (KongService/KongRoute).

### Adding a new app team

1. Add `manifests/apps/<team>/` with kustomization + manifests.
2. Add `argocd/projects/app-<team>.yaml` (copy `app-httpbin.yaml`, adjust
   namespace).
3. Add `argocd/app-<team>.yaml` for the new Application.
4. Update `.github/CODEOWNERS` to give that team approval rights on their path.

## One-off verification

The tests under `tests/` are runnable manually — they're **not** wired into CI
because this repo has no cluster access. Use them locally or in a separate
post-deploy job.

```bash
# Smoke
GATEWAY_URL=http://<gateway-host> bash tests/smoke.sh

# Functional
GATEWAY_URL=http://<gateway-host> API_KEY=demo-key-12345 \
  k6 run tests/k6-functional.js
```

`<gateway-host>` is whatever exposes the `kong/kong` Gateway — a real
LoadBalancer IP, a kind port mapping, or `kubectl port-forward` for ad-hoc
checks.

## Debugging

### `KonnectGatewayControlPlane` stuck (or Gateway not creating it)

```bash
# Check if Gateway created the control plane
kubectl -n kong get konnectgatewaycontrolplane
kubectl -n kong get gateway kong -o yaml | grep -A20 status

# Check operator logs
kubectl -n kong-system logs -l app.kubernetes.io/name=gateway-operator --tail=200
```

Most common causes:

- `konnect-api-auth` Secret missing, lacks required labels, or contains a stale token
- Secret labels missing: `konghq.com/credential=konnect` and `konghq.com/secret=true`
- `KonnectAPIAuthConfiguration.serverURL` doesn't match the region your token
  belongs to (should be `https://au.api.konghq.com` for AU region)
- Token lacks `Control Planes: Admin` Konnect role
- `GatewayConfiguration.spec.konnect.authRef` not pointing to correct
  KonnectAPIAuthConfiguration

### Gateway never reaches `Programmed=True`

```bash
kubectl -n kong describe gateway kong
kubectl -n kong get konnectgatewaycontrolplane,konnectextension,dataplane -o wide
```

Likely causes:

- `KonnectGatewayControlPlane` not yet `Programmed` → wait for Konnect API
- `GatewayConfiguration.spec.konnect.authRef` misconfigured
- Gateway auto-creation failed — check `kubectl get events -n kong`
- Operator version too old — upgrade to ≥2.1

### Routes not visible in Konnect

```bash
# Check HTTPRoute status
kubectl get httproute -A
kubectl describe httproute httpbin -n httpbin

# Check operator logs for translation
kubectl -n kong-system logs -l app.kubernetes.io/name=gateway-operator --tail=200 | grep httproute

# Check if KIC is deployed (required for HTTPRoute translation in Konnect mode)
kubectl get pods -n kong | grep ingress-controller
```

Common causes:

- HTTPRoute requires Kong Ingress Controller for translation in Konnect hybrid mode
- Operator logs show "No supported parent references found, skipping translation"
- `GatewayConfiguration.spec.konnect.source: Origin` expects config from Konnect, not Gateway API

Solutions:

- Deploy Kong Ingress Controller to translate HTTPRoute
- Switch to Kong-native CRDs (KongService/KongRoute)
- Change `konnect.source` to `Gateway` instead of `Origin`

### Argo CD application stuck `OutOfSync`

```bash
kubectl -n argocd get applications
argocd app get platform
argocd app get httpbin
```

Most common: `repoURL` typo, repo private and Argo lacks credentials, or
branch other than `main` (check `targetRevision`).

### Rate-limit test flaky

`KongPlugin` `rate-limit-status` uses `policy: local`. In a multi-replica
DataPlane each replica has its own counter, so 5/min becomes 5 × N/min across
the cluster. For deterministic enforcement at scale, switch to `policy:
redis` or `policy: cluster` (Postgres) and configure the backing store.

## Reverting a bad change

GitOps revert is `git revert <commit> && git push`. Argo CD picks up the
revert on its next reconcile and reapplies the previous state. No special
playbook needed.

To temporarily pause Argo CD reconciliation on one Application:

```bash
kubectl -n argocd patch application httpbin \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

Re-enable by restoring the `automated` block from `argocd/app-httpbin.yaml`.

## Forking for your own org

```bash
# 1. Fork or copy the repo into your GitHub org.
# 2. Replace 'debugnin' with your org/user:
grep -rl 'debugnin' . | xargs sed -i '' "s|debugnin|your-gh-org|g"

# 3. Adjust the team slugs in .github/CODEOWNERS to teams that exist in your
#    org, or replace them with @username references.

# 4. Set a branch protection rule on main:
#    - Require pull request before merging
#    - Require approvals: 1
#    - Require review from Code Owners
#    - Require status checks: schema, render, policy (from pr.yaml)
```
