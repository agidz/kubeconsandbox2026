# ADR-017 — Ask Keycloak to authorize each MCP tool call

**Status** Accepted on 2026-11-15 after S7

Agent Router delegates authorization to a small Python policy enforcement point through MCPRoute external authorization. Keycloak 26.8 provides the AuthZEN 1.0 evaluation endpoint and uses its Authorization Services as the decision point.

For a JSON-RPC `tools/call`, the PEP sends the user's subject as `id:<sub>`, the resource as `mcp:tool/<tool>`, and the action as `call` to `/realms/sandbox/authzen/access/v1/evaluation`. Other methods pass this PEP. Agent Router independently verifies the bearer token, and both checks must pass for a tool call. The PEP authenticates to Keycloak as `mcp-tools` with a SPIRE JWT-SVID maintained by spiffe-helper. Errors deny the tool call.

The service uses the Python standard library and mounts its code from a ConfigMap. Keycloak role updates take effect at the next evaluation. The extra request is acceptable for this demo. For larger deployments, evaluate batch requests or short-lived caching. The `decisions` chart setting can select `keycloak` or `token`; Agent Router retains the agent's allowlist in either mode.

OPA-Envoy would need a client secret for this Keycloak endpoint. Other candidates served as decision points or did not provide reusable enforcement code. Revisit when a maintained AuthZEN enforcement service supports Envoy and workload identity.
