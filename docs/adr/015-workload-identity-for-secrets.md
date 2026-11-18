# ADR-015 — Prefer workload identity for authentication

**Status** Accepted on 2026-11-14, documented on 2026-11-15

An installation should generate its own credentials, keep them out of Git, and make every path to a credential explainable. Use this order when integrating a component.

1. Authenticate with the identity the workload already has. Options include a SPIFFE SVID, a Substrate Pod Certificate or actor JWT, a Kubernetes ServiceAccount token, or an OAuth token with a delegated actor claim.
2. If the component requires a secret, use workload identity to fetch it from OpenBao at runtime.
3. Where the component consumes only Kubernetes Secrets, provision one with External Secrets Operator or bootstrap before ESO is available. Record why it is needed in the credential inventory.

Runtime retrieval keeps a credential in one place to audit and rotate. The Kubernetes copy is needed by interfaces such as Argo CD, Grafana, Harbor, and Envoy's OIDC filter. Move components to direct identity authentication when upstream supports it. Bootstrap uses the short-lived `sandbox-operator` login after revoking its initial root token.

Sealed or encrypted secrets in Git would still distribute their lifecycle across namespaces. Using an agent or CSI mount everywhere would still deliver passwords to components capable of using identity directly. See the [trust map](../trust-map.md) for exercised paths.
