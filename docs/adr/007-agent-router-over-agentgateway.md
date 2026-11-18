# ADR-007 — Agent Router for model and MCP traffic

**Status** Accepted on 2026-11-15

Agent traffic needs a shared enforcement point for caller authentication, provider credentials, tool-level authorization, metrics, and traces. Use Agent Router v1.2.1 from `ai-gateway-helm` as an Envoy Gateway extension. The in-cluster `agent-router` Gateway serves the `models` AIGatewayRoute and the `mcp` MCPRoute.

The model route validates actor JWTs and adds provider credentials. The MCP route uses Keycloak OAuth, CEL predicates over tool names and token claims, and the AuthZEN policy enforcement point. MCP tool names use the `<backend>__<tool>` form, including in filtering rules for `tools/list`.

The model listener runs external processing before JWT authentication, so malformed messages can receive 400 before an authentication failure. This release supports session-based MCP, so kagent's `server/discover` can return 400 before the client falls back. Substrate keeps its bundled internal agentgateway installation.

The open-source Agent Router supports the authorization features used in this demo. agentgateway's equivalent advanced features require Solo's enterprise build. Using Envoy Gateway alone would require custom model and MCP processing.
