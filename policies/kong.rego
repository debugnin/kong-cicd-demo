package kong

# ---------------------------------------------------------------------------
# Conftest policies. Run in pr.yaml against the output of `kustomize build`.
#
# Rules:
#   1. deny_wildcard_hosts        — HTTPRoute may not use "*" hostnames
#   2. require_route_timeout      — HTTPRoute rules must set timeouts.request
#   3. plugin_allowlist           — KongPlugin.plugin must be in the allowlist
# ---------------------------------------------------------------------------

# ----- Rule 1: no wildcard hosts on HTTPRoute -----
deny contains msg if {
  input.kind == "HTTPRoute"
  some host in input.spec.hostnames
  host == "*"
  msg := sprintf(
    "HTTPRoute %q in namespace %q uses wildcard hostname '*' — explicit hostnames required",
    [input.metadata.name, input.metadata.namespace],
  )
}

# ----- Rule 2: every HTTPRoute rule must set timeouts.request -----
deny contains msg if {
  input.kind == "HTTPRoute"
  some i, rule in input.spec.rules
  not rule.timeouts.request
  msg := sprintf(
    "HTTPRoute %q in namespace %q rule[%d] is missing spec.rules[%d].timeouts.request",
    [input.metadata.name, input.metadata.namespace, i, i],
  )
}

# ----- Rule 3: KongPlugin must use an allowlisted plugin -----
allowed_plugins := {
  "rate-limiting",
  "key-auth",
  "request-transformer",
  "correlation-id",
  "cors",
}

deny contains msg if {
  input.kind == "KongPlugin"
  not allowed_plugins[input.plugin]
  msg := sprintf(
    "KongPlugin %q in namespace %q uses plugin %q which is not on the allowlist %v",
    [input.metadata.name, input.metadata.namespace, input.plugin, allowed_plugins],
  )
}
