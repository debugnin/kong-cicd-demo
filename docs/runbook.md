# Runbook

How to fork, configure, run, and debug `kong-cicd-demo`.

## Prerequisites

| Tool | Version | Where used |
|---|---|---|
| `gh` or GitHub web | — | Forking, secret setup |
| Konnect account | AU region | CP creation |
| `KONNECT_TOKEN` | PAT or service-account token with CP create/delete | TF + KIC |

For local development:

| Tool | Version |
|---|---|
| Terraform | ≥ 1.6 |
| kubectl | ≥ 1.30 |
| Helm | ≥ 3.13 |
| kind | ≥ 0.22 |
| kustomize | ≥ 5.0 |
| conftest | ≥ 0.55 |
| kubeconform | ≥ 0.6 |
| k6 | ≥ 0.50 |

## One-time fork setup

1. **Fork or copy** this folder into a public GitHub repo. The demo assumes
   public so Argo CD can clone without auth; for private, see "Private repo"
   below.

2. **Replace `debugnin`** in the following files:
   - `argocd/projects/platform.yaml`
   - `argocd/projects/app-httpbin.yaml`
   - `argocd/app-platform.yaml`
   - `argocd/app-httpbin.yaml`
   - `.github/CODEOWNERS`

   ```bash
   grep -rl 'debugnin' . | xargs sed -i '' "s|debugnin|your-gh-org|g"
   ```

3. **Add the GitHub Actions secret:**
   ```bash
   gh secret set KONNECT_TOKEN -b "kpat_..."
   ```

4. **Create platform-team and app-team-a GitHub teams** (or rename the slugs
   in `.github/CODEOWNERS` to whatever you have).

5. **Branch protection on `main`:**
   - Require pull request before merging
   - Require approvals: 1
   - Require review from Code Owners
   - Require status checks: `schema`, `render`, `policy` (from `pr.yaml`)

## Running locally (no GitHub)

You can run the entire `main.yaml` pipeline on your laptop. Useful for
iterating without burning CI minutes.

```bash
export KONNECT_TOKEN="kpat_..."

# 1. Create the Konnect CP
cd infra/terraform
terraform init
terraform apply -auto-approve
cd ../..

# 2. Create kind cluster
kind create cluster --config infra/kind-config.yaml --name kong-cicd-demo

# 3. Bootstrap
bash infra/bootstrap.sh

# 4. Konnect token Secret
kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kong create secret generic konnect-token \
  --from-literal=token="${KONNECT_TOKEN}"

# 5. Apply Argo CD configs
#    NOTE: edit argocd/app-*.yaml to point at your fork first, OR replace
#    repoURL with a local path (see "Private/local repo" below).
kubectl apply -f argocd/projects/
kubectl apply -f argocd/app-platform.yaml -f argocd/app-httpbin.yaml

# 6. Wait
kubectl -n kong wait gateway/kong --for=condition=Programmed=True --timeout=300s

# 7. Tests
GATEWAY_URL=http://localhost:8080 bash tests/smoke.sh
GATEWAY_URL=http://localhost:8080 k6 run tests/k6-functional.js

# 8. Cleanup
kind delete cluster --name kong-cicd-demo
cd infra/terraform && terraform destroy -auto-approve
```

## Debugging failed runs

### Gateway never reaches `Programmed=True`

```bash
kubectl -n kong describe gateway kong
kubectl -n kong get dataplane,controlplane -o wide
kubectl -n kong get pods -l app.kubernetes.io/managed-by=gateway-operator
kubectl -n kong logs -l app.kubernetes.io/managed-by=gateway-operator --tail=200
```

Likely causes:
- `KONNECT_TOKEN` secret missing or wrong → `konnect-api-auth` will error
- Konnect CP `kong-cicd-demo` doesn't exist → Terraform apply failed silently
- Operator image pull failure → check kind node has internet

### Argo CD application stuck `OutOfSync`

```bash
kubectl -n argocd get applications
argocd app get platform --core
argocd app get httpbin --core
```

Most common: `debugnin` placeholder not replaced, so Argo can't reach the repo.

### k6 test 3 (rate-limit) flaky

Rate-limit policy: `local`. In a single-replica DataPlane this is reliable.
If you scale the DP to >1 replica, switch the plugin policy to `cluster` (with
a Postgres DB) or `redis`, or accept the flakiness.

### Tests pass locally but Konnect UI shows nothing

The data plane sends config to Konnect asynchronously after Argo syncs.
Wait 30–60 seconds, then refresh the Konnect UI. If still empty, check
DataPlane pod logs for Konnect connectivity errors.

## Private repo variant (not built — sketch)

If you can't make the repo public:

1. Create a GitHub deploy key for the repo (read-only).
2. Add it as a Kubernetes secret in `argocd` namespace:
   ```bash
   kubectl -n argocd create secret generic repo-creds \
     --from-file=sshPrivateKey=/path/to/key
   kubectl -n argocd label secret repo-creds \
     argocd.argoproj.io/secret-type=repository
   ```
3. Switch all `argocd/app-*.yaml` `repoURL:` values to `git@github.com:...`.
4. Argo CD will pick the credentials up automatically.

## Modifying the demo

| Want to | Change |
|---|---|
| Different upstream service | Edit `manifests/apps/httpbin/deployment.yaml` + `service.yaml`; update `httproute.yaml` paths |
| Different plugin | Add new `KongPlugin` YAML; append to HTTPRoute annotation; add plugin name to `policies/kong.rego` allowlist (or accept the policy denial) |
| Different region | `infra/terraform/variables.tf` `konnect_server_url` + `manifests/platform/konnect-api-auth.yaml` `serverURL` |
| Multiple environments | Add `manifests/platform/envs/<env>/` kustomize overlays and one Argo `Application` per env (or use an `ApplicationSet`) |
