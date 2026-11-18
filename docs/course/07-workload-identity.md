# Module 7 — Authenticate workloads with SPIFFE

SPIRE attests where a workload is running and issues an SVID for its registered identity. In this sandbox the SPIFFE path includes the Kubernetes namespace and ServiceAccount. X.509-SVIDs support certificate authentication. JWT-SVIDs have an audience for the service that consumes them. A workload can exchange its short-lived JWT-SVID for scoped credentials without handling a password.

## Lab 7.1 — Obtain an SVID

```bash
svid=$(scripts/lab.sh svid)
scripts/lab.sh claims "$svid"
```

Find the `lab-svid/default` identity, `openbao` audience, and five-minute lifetime. SPIRE may reuse a JWT-SVID for about half of its lifetime. The short lifetime keeps reused assertions within Keycloak's 300-second age limit.

## Lab 7.2 — Compare OpenBao decisions

```bash
source scripts/lib/common.sh
bao_connect
bao_api GET auth/spiffe-jwt/role/spiffe-demo | jq '.data | {bound_subject, bound_audiences, token_policies}'
login() {
  jq -n --arg jwt "$1" '{role: "spiffe-demo", jwt: $jwt}' |
    curl -s --cacert "$CA_CRT" -X POST --data-binary @- "$BAO_URL/v1/auth/spiffe-jwt/login" |
    jq -c '.auth.policies // .errors'
}
login "$svid"
login "$(scripts/lab.sh svid kcs-verify-l2)"
```

The first subject is refused. The second matches and can read only the public CA entry. `make verify LAYER=2` checks both permitted and denied access.

## Lab 7.3 — Identify the delegation proxy's credential

```bash
yq '.clients[] | select(.spiffeId) | {name, spiffeId}' manifests/keycloak/values.yaml
kubectl -n mcp get pods -l app=delegation-proxy -o jsonpath='{.items[0].spec.serviceAccountName}'
kubectl -n mcp logs deploy/delegation-proxy -c spiffe-helper --tail=3
```

A sidecar refreshes the proxy's JWT-SVID in memory. Keycloak recognizes that subject as client `mcp-agent`. Verify layer 4 to see the assertions for a different ServiceAccount and for password-based login.

## Lab 7.4 — Distinguish the trust domains

```bash
curl -s https://oidc-discovery.localtest.me/.well-known/openid-configuration | jq '{issuer, jwks_uri}'
kubectl get clustertrustbundles
```

SPIRE serves platform workloads in `sandbox.local`. Substrate issues identities for its runtime in `cluster.local`. Explain how Agent Router can trust actor tokens from Substrate alongside those two roles without merging their issuing authorities. See the [trust map](../trust-map.md) and [workload identity decision](../adr/011-two-spiffe-trust-domains.md).
