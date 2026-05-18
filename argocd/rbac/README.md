# Argo CD Application impersonation (optional Layer-3 control)

Off by default. Enables the third layer of the platform/app separation described
in `docs/architecture.md` — Argo CD applies each tier's manifests under a
distinct Kubernetes `ServiceAccount` whose RBAC matches the tier's scope.

## What this prevents

Even if a malicious manifest bypasses CODEOWNERS review (Layer 1) and AppProject
resource whitelists (Layer 2), the Kubernetes API server itself will reject
out-of-scope writes — because the impersonated ServiceAccount lacks the
required RBAC.

Example: a `manifests/apps/httpbin/` change that adds a `GatewayClass` would be
refused by the API server when `httpbin-deployer` (which has no
`gatewayclasses` RBAC) tries to create it.

## How to enable

1. Apply the SA + Role + Binding manifests:
   ```bash
   kubectl apply -f argocd/rbac/
   ```

2. Uncomment the `destinationServiceAccount` line in:
   - `argocd/app-platform.yaml`
   - `argocd/app-httpbin.yaml`

3. Sync the Applications. Argo CD will start impersonating the respective SA on
   every reconcile.

## How to verify

Force a denied case to confirm enforcement:

```bash
# As a smoke test, try to create a GatewayClass using the httpbin SA token —
# should fail with "forbidden".
kubectl --as=system:serviceaccount:argocd:httpbin-deployer \
  auth can-i create gatewayclasses
# Expected: no
```

## Why off by default

Adds three artifacts (SA + ClusterRole + Binding per tier) to track and
explains a concept that's secondary to the demo's core lesson. The default
demo run focuses on the PR/sync layers; impersonation is the take-home
upgrade path.
