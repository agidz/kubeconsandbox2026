# Module 12 — Account for one delegated tool call

Sign into kagent as Alice, grant delegation consent, and ask `mcp-agent` to echo “hello.” You can also use the lab helper.

```bash
scripts/lab.sh ask mcp-agent alice 'Use your echo tool to echo: hello'
```

## Trace the request

| Stage | What to verify |
|---|---|
| Ingress | The browser reaches kind on host port 443 and Envoy presents the wildcard certificate. |
| User login | Keycloak records Alice's consent and issues a token with `may_act`. Envoy passes the token on to kagent. |
| Runtime | Substrate resumes a gVisor actor. Check `scripts/lab.sh actors` and locate the actor in Jaeger. |
| Inference | The egress gateway adds the actor JWT. Agent Router validates it and uses llm-d to select a vLLM replica with weights mounted from Harbor. |
| Delegation | The agent passes Alice's token to the proxy. The proxy uses its SPIRE identity to obtain an MCP token with Alice as subject and `mcp-agent` as actor. |
| Tool authorization | Agent Router checks the token and agent allowlist. AuthZEN evaluates Alice's permission to call echo. |
| Tool execution | The MCP server receives user and agent headers and returns the echo result. The model uses it to answer and the actor suspends. |
| Telemetry | Jaeger joins the spans. Grafana reports model usage and counts the allowed delegated call for Alice, the agent, and the tool. |

Use the proxy, `mcp-pep`, and `everything` deployment logs in namespace `mcp`. Search `delegation-proxy` in Jaeger with `user.name=alice`. Connect the running resources back to the Argo Applications and the OpenBao credentials they consume.

## Predict and verify the denied cases

| Exercise | Expected boundary |
|---|---|
| Inference without an actor JWT (module 8) | Agent Router returns 401. |
| Anonymous MCP request (module 9) | Agent Router returns a 401 challenge with metadata. |
| MCP token for a different audience (module 9) | Agent Router refuses the token. |
| Bob requests get-env | Keycloak denies the user through the PEP. |
| Alice's agent requests get-sum | The agent allowlist denies the tool. |
| Exchange without Alice's consent (module 10) | Keycloak rejects the exchange. |
| Pod with the wrong ServiceAccount (layer 4 verify) | The workload cannot authenticate as mcp-agent. |
| Kagent API request from an unintended namespace (layer 3 verify) | NetworkPolicy blocks the connection. |
| Edit a managed Deployment (module 2) | Argo restores the declared setting. |
| Agent requests a public destination (module 8) | The egress gateway's network policy blocks it. |

## Review production differences

Explain how you would replace static unseal with a KMS or HSM, protect an offline root with a managed intermediate, and deploy replicated services with persistent telemetry storage. Plan distinct managed credentials for Harbor's database and RustFS, audit break-glass access, and consider a separate management cluster for Git, Argo, Harbor, and OpenBao.

Identify why kagent's insecure caller mode needs a validating proxy and authorization, why the delegation proxy needs authenticated actor evidence alongside the user token, and why one CPU-only kind node is a teaching choice. Consider how to handle missing egress spans, direct workload credential retrieval for Agent Router, and per-agent tool credentials.

## Extend the exercise

Add another MCP tool server and give it a Keycloak policy, or add an AgentTemplate with a different tool set. Try a larger model on suitable hardware and retune llm-d. Run `make verify` and explain which component enforces each assertion.
