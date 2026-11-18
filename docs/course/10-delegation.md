# Module 10 — Let an agent act with user consent

OAuth Token Exchange (RFC 8693) lets Keycloak issue an MCP access token carrying both the user in `sub` and the agent in `act`. Keycloak checks `may_act` on the user's token, which records consent from the browser login. Agent Router applies the agent's tool allowlist and checks the user's rights through the AuthZEN policy service.

The kagent UI gets the user's access token from the gateway. The RemoteMCPServer passes that token to the delegation proxy. The proxy proves its own identity to Keycloak using its SPIRE JWT-SVID, then calls Agent Router with the exchanged token. kagent 1.0.1 cannot attach a separate actor JWT to the passed-through token, so the committed MCP server configuration names the agent for this hop. NetworkPolicy restricts who can reach the proxy.

## Lab 10.1 — Read the subject and actor claims

```bash
user_token=$(scripts/lab.sh token alice portal)
scripts/lab.sh claims "$user_token" | jq '{sub, aud, azp, may_act}'
delegated=$(scripts/lab.sh delegate alice)
scripts/lab.sh claims "$delegated" | jq '{sub, preferred_username, azp, act, aud, groups}'
```

Verify that Alice is the subject, `mcp-agent` is the actor, and the MCP resource is the audience. Then compare permissions.

```bash
scripts/lab.sh agent-mcp alice echo
scripts/lab.sh agent-mcp alice get-sum
scripts/lab.sh agent-mcp bob get-env
```

Echo succeeds. The agent's allowlist denies get-sum even for Alice. Bob lacks user permission for get-env even though the agent may request it.

## Lab 10.2 — Consent in the UI

Sign in to `https://kagent.localtest.me` as Alice and read the consent prompt. Ask `mcp-agent` to echo a phrase and show the environment. Try the environment request again after signing out and signing in as Bob. Use `mcp-agent-stub` for predictable calls. It cannot invoke get-sum because the gateway filters that tool from the agent's list.

## Lab 10.3 — Locate the audit evidence

```bash
kubectl -n mcp logs deploy/delegation-proxy -c proxy --tail=5 |
  grep '^{' | jq -c '{user, agent, act, method, tool, status}'
kubectl -n mcp logs deploy/everything --tail=5
```

Search Jaeger for service `delegation-proxy` with `user.name=alice`. Find the agent and tool attributes, then follow the Agent Router child span and the Substrate actor in the same trace. In Grafana, check the Delegated tool calls row for the same user, agent, tool, and outcome.

## Lab 10.4 — Look for absent consent

```bash
without_consent=$(scripts/lab.sh token alice)
scripts/lab.sh claims "$without_consent" | jq '.may_act'
make verify LAYER=4
```

The Inspector token does not request delegation. Find the verification of Keycloak's rejected exchange in `no_exchange_without_consent`. Explain why a single broad agent credential would obscure the user and widen access. See the [proxy design](../adr/018-agent-delegation-proxy.md) and [trust map](../trust-map.md).
