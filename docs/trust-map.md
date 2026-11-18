# Credential issuers and consumers

The sandbox root is an ECDSA P-256 CA under `.state/ca/` with a one-intermediate path constraint. Bootstrap uses it to issue service certificates and supplies it to cert-manager's `sandbox-ca` ClusterIssuer for the wildcard gateway certificate. OpenBao stores the private key in bootstrap KV and mounts the root in its PKI engine to sign SPIRE's 24-hour server CA. An additional OpenBao intermediate would exceed the root's path length.

## Trust paths

| Issuer | Credential | Consumer and trust configuration |
|---|---|---|
| Sandbox root and cert-manager | Harbor, OpenBao, and wildcard TLS certificates | Browsers and shell tools import the CA. Containerd receives node trust. ESO distributes the public bundle to workloads. Bootstrap supplies Argo CD the registry and Keycloak trust it needs. |
| OpenBao PKI | Intermediate SPIRE CA | The SPIRE server uses its ServiceAccount to call `pki/root/sign-intermediate`. |
| SPIRE `sandbox.local` | X.509-SVIDs and five-minute JWT-SVIDs | X.509 reaches workloads via CSI. JWT consumers fetch signing keys at `https://oidc-discovery.<domain>/keys`. |
| SPIRE → OpenBao | JWT-SVID for audience `openbao` | `auth/spiffe-jwt` validates discovery over the sandbox CA and binds the subject to a policy. |
| SPIRE → Keycloak | JWT-SVID client assertion | Keycloak compares the subject with the registered credential subject, checks the realm audience and a 300-second assertion age, and trusts the discovery endpoint. The proxy and PEP use this path. |
| Keycloak sandbox realm | Browser ID and access tokens with groups | Argo, Grafana, Harbor, Gitea, OpenBao, and Envoy use per-service clients. Confidential credentials live in OpenBao. |
| Keycloak MCP client | Access token with MCP resource audience | Agent Router validates the issuer and keys. Protected-resource metadata points clients to the realm. |
| Keycloak delegation | Token exchange output with user `sub`, agent `act.client_id`, and MCP audience | Consent via the portal or kagent client supplies `may_act`. Fine-grained admin permissions grant delegate. Agent Router checks policy and adds user and agent headers for the tool server. |
| Keycloak AuthZEN | Per-call decision | The PEP authenticates as `mcp-tools` and sends its decision to Agent Router. Errors close the request. |
| Substrate `cluster.local` | Pod certificates for runtime services and Kubernetes integrations | Bootstrap Jobs create the signer pools. ClusterTrustBundle adds the sandbox root for database trust. |
| Substrate IdP | ES256 actor JWT with `agent-router` audience | Agent Router reads in-cluster JWKS over TLS using the Substrate service DNS root. Both normal and local inference routes require it. |

SPIRE and Substrate issue identities in separate domains. Substrate owns the agent execution credentials. The delegation proxy receives the passed-through user token while its own SPIRE identity supplies the Keycloak client assertion. The agent name on that hop comes from configuration.

## Logins to OpenBao

| Principal | Method | Access |
|---|---|---|
| Bootstrap, verification, and access scripts | `openbao/sandbox-operator` ServiceAccount, `openbao-operator` audience | Operator role issues 15-minute tokens. Bootstrap revokes the initial root token. |
| External Secrets Operator | `external-secrets/external-secrets` ServiceAccount | Reads KV entries outside the bootstrap key material. |
| SPIRE server | `spire-server/spire-server` ServiceAccount, `vault` audience | Signs the SPIRE intermediate only. |
| SPIFFE demo workload | JWT-SVID with the `openbao` audience | Role permits access to one public entry. |
| People | Keycloak OIDC with role `sandbox` | Administrators manage data. Viewers list secret names. |

Open work includes moving OpenBao configuration into an Argo-managed Job, direct model credential retrieval by Agent Router when supported, and cryptographically binding the actor on the delegation proxy hop. See [workload identity](adr/015-workload-identity-for-secrets.md) and [delegation](adr/018-agent-delegation-proxy.md).
