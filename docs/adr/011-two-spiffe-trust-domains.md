# ADR-011 — Keep distinct platform and agent trust domains

**Status** Accepted on 2026-11-15

Use SPIRE in `sandbox.local` for platform workload identities, with a chain anchored at the sandbox CA through OpenBao PKI. The AuthZEN PEP and delegation proxy use SPIRE JWT-SVIDs for Keycloak client authentication, and OpenBao offers `auth/spiffe-jwt` for workload login. SPIRE itself and External Secrets Operator authenticate to OpenBao with Kubernetes credentials.

Agent Substrate 1.0 issues identities in `cluster.local` using its own pools and Kubernetes Pod Certificates. These cover the agent runtime, API, and egress. Agent Router trusts the Substrate issuer for actor JWTs. Substrate trusts the sandbox root for the CloudNativePG server through a ClusterTrustBundle.

A trust domain assigns responsibility for issuing names. Substrate 1.0 does not support using SPIRE for its own issuance. Configure trust for each interaction so no component gains broader trust than its function needs. The [trust map](../trust-map.md) records those interactions. The delegation proxy's inability to verify a Substrate actor alongside the user's token is tracked in [ADR-018](018-agent-delegation-proxy.md).
