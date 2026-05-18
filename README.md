# kong-cicd-demo

End-to-end CI/CD demo for Kong gateway configuration on Kubernetes, using:

- **Kong Gateway Operator** managing the DataPlane lifecycle
- **Konnect** (AU region) as the control plane, provisioned by **Terraform**
- **Argo CD** pulling manifests from this Git repo
- **GitHub Actions** for PR validation (fast lane) and full E2E on merge (kind + Argo + k6)

Two-tier ownership model in one repo: **platform** (gateway, GatewayClass,
Konnect wiring) and **app** (HTTPRoute, plugins, consumer). Three layers of
separation enforcement: CODEOWNERS, Argo `AppProject` whitelists, optional
Application impersonation.

## Quickstart

1. Fork this folder into a public GitHub repo.
2. Replace `debugnin` everywhere:
   ```bash
   grep -rl 'debugnin' . | xargs sed -i '' "s|debugnin|your-gh-org|g"
   ```
3. `gh secret set KONNECT_TOKEN -b "kpat_..."`
4. Push to `main`. Watch `.github/workflows/main.yaml` in the Actions tab.

Full instructions and local-development flow in [`docs/runbook.md`](docs/runbook.md).
Architecture detail in [`docs/architecture.md`](docs/architecture.md).

## Pipelines

| Workflow | Trigger | What it does | Duration |
|---|---|---|---|
| [`pr.yaml`](.github/workflows/pr.yaml) | PR | `kubeconform` + `kustomize build` + `conftest` | ~1 min |
| [`main.yaml`](.github/workflows/main.yaml) | push to main, manual | Terraform → kind → Operator → Argo CD → smoke + k6 → destroy | ~10 min |

## Folder map

```
.github/         workflows + CODEOWNERS (Layer-1 control)
infra/           Terraform (Konnect CP) + kind config + helm bootstrap
argocd/          AppProjects (Layer-2) + Applications + optional RBAC (Layer-3)
manifests/
  platform/      platform-tier (Argo app: platform)
  apps/httpbin/  app-tier (Argo app: httpbin)
policies/        Conftest rules (CI-time enforcement)
tests/           smoke.sh + k6-functional.js
docs/            architecture, runbook
```

## What this is not

A production reference. Multi-env overlays, External Secrets, drift detection,
TLS, and promotion automation are deliberately excluded — see
[`docs/architecture.md`](docs/architecture.md) "Non-goals" for the upgrade path.
