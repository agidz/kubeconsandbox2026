# ADR-018 — Exchange the user's token through an agent delegation proxy

**Status** Accepted on 2026-11-15 for layer 4

The earlier delegation experiment used a script to demonstrate Keycloak consent, the `may_act` claim, and token exchange with an agent identity. kagent 1.0.1 exposes caller-token passthrough and an actor JWT, but a single RemoteMCPServer cannot combine them. Keycloak also requires the actor token to represent its own client.

The kagent UI requests consent for `delegation:client:mcp-agent`. The gateway forwards the signed-in user's token through the UI and controller. The agent's `mcp-delegated` RemoteMCPServer uses `tokenPassthrough` and names the agent in `x-kagent-agent`. A NetworkPolicy permits requests to the proxy from Substrate's egress gateway.

The proxy runs as `mcp/mcp-agent`. It presents that ServiceAccount's SPIRE JWT-SVID to Keycloak, exchanges the user's token, caches the delegated token until expiry, and forwards to Agent Router. The exchanged token identifies the user, the agent actor, and the MCP audience. Agent Router checks the token and agent allowlist before the tool policy runs. The proxy also adds a delegation span to the trace and handles streaming MCP responses.

The current proxy binds the agent by committed configuration. Another Agent able to bind the same RemoteMCPServer can act as `mcp-agent` for users who granted consent. When passthrough can carry the actor JWT alongside the user token, verify it and resolve its Agent through `AgentIdentityService/ResolveAgentIdentity`. Each additional delegating agent needs a dedicated Keycloak client and ServiceAccount.

Using actor identity alone would require separate user impersonation. Exchanging after MCPRoute OAuth validation would be too late because the incoming user token lacks the delegated audience. A scripted model makes the full tool path reproducible without an inference API key.
