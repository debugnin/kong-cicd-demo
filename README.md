# kong-cicd-demo

A CRD-only source-of-truth repo for a Kong gateway managed by the **Kong
Operator** with **Konnect (AU region)** as the control plane. Argo CD syncs
the manifests; the operator reconciles them against Konnect.

Cluster, Kong Operator, Argo CD, and the Konnect token Secret are all
provisioned **outside this repo**.

## Quickstart

1. Fork this repo. Replace `debugnin` with your GitHub org/user:
   ```bash
   grep -rl 'debugnin' . | xargs sed -i '' "s|debugnin|your-gh-org|g"
   ```

2. Install the prerequisites in your cluster (see [`docs/runbook.md`](docs/runbook.md)):
   - Kong Operator — use [`../helm/deploy-kong-operator.sh`](../helm/deploy-kong-operator.sh)
   - Argo CD — use the workspace's [`../helm/deploy-argocd.sh`](../helm/deploy-argocd.sh)
   - Gateway API CRDs

3. Create the Konnect token Secret:
   ```bash
   kubectl create namespace kong
   kubectl -n kong create secret generic konnect-token \
     --from-literal=token="kpat_..."
   ```

4. Apply Argo CD configs:
   ```bash
   kubectl apply -f argocd/projects/
   kubectl apply -f argocd/app-platform.yaml -f argocd/app-httpbin.yaml
   ```

5. Argo CD pulls from `main`, the operator creates the Konnect CP
   `kong-cicd-demo`, and the gateway comes up.

## What's in here

```
.github/         CODEOWNERS + pr.yaml (only CI workflow)
argocd/          AppProjects + Applications + optional RBAC
manifests/
  platform/      KonnectGatewayControlPlane + Gateway + Konnect wiring
  apps/httpbin/  HTTPRoute + plugins + consumer + upstream service
policies/        Conftest rules enforced in PR CI
tests/           Manual-run smoke + k6 functional tests
docs/            Architecture + runbook
```

## What's NOT in here

| Externalised | Where it lives |
|---|---|
| Kubernetes cluster | Provided by you |
| Kong Operator install | `../helm/deploy-kong-operator.sh` |
| Argo CD install | `../helm/deploy-argocd.sh` |
| Konnect token Secret | `kubectl create secret` once, or ESO |

See [`docs/architecture.md`](docs/architecture.md) for the full picture and
[`docs/runbook.md`](docs/runbook.md) for operating instructions.

## CI

One workflow, [`.github/workflows/pr.yaml`](.github/workflows/pr.yaml):

| Job | Tool | Catches |
|---|---|---|
| `schema` | kubeconform | Bad fields/types in manifests |
| `render` | kustomize | Overlay errors |
| `policy` | conftest | Wildcard hosts, missing timeouts, non-allowlisted plugins |

No `main` workflow. Deployment is GitOps — merge to `main`, Argo CD pulls.
