# Module 9 — Authorize an MCP tool request

The demo MCP server exposes tools through Agent Router. Protected-resource metadata tells a client where to get a token. Agent Router validates that token for the resource and enforces tool rules. With AuthZEN enabled, a policy enforcement service asks Keycloak about each tool call. In token mode, authorization is based on the claims already minted into the token. The backend receives request identity headers rather than the original caller credential.

## Lab 9.1 — Discover authentication

```bash
curl -s -D - -o /dev/null https://mcp.localtest.me/mcp -H 'content-type: application/json' -d '{}' | grep -iE '^HTTP|www-auth'
curl -s https://mcp.localtest.me/.well-known/oauth-protected-resource/mcp | jq
```

Follow the 401 challenge to the metadata. Find the sandbox realm and the MCP scope.

## Lab 9.2 — Compare users on the same tool

```bash
scripts/lab.sh mcp alice echo 'hello from alice'
scripts/lab.sh mcp bob echo 'hello from bob'
scripts/lab.sh mcp alice get-env
scripts/lab.sh mcp bob get-env
kubectl -n mcp logs deploy/mcp-pep --tail=4
```

Both users can echo. Alice's admin group grants `mcp-env-reader`. Bob receives 403 for that tool. Compare the PEP log entries.

## Lab 9.3 — Change a live decision

```bash
scripts/lab.sh role bob mcp-env-reader grant
scripts/lab.sh mcp bob get-env
scripts/lab.sh role bob mcp-env-reader revoke
scripts/lab.sh mcp bob get-env
```

The grant permits the call and the revoke removes access. `make verify LAYER=4` exercises the change with the same access token. Explain why a static group rule would have to wait for another token.

## Lab 9.4 — Use the Inspector

Sign in to the Inspector as admin and connect to the preconfigured server. Sign into the MCP server when prompted, inspect the tools, and use echo. Follow the two login boundaries in `manifests/mcp-demo/templates/inspector.yaml`. A visible tool can still be refused when called.

## Lab 9.5 — Check audience binding

```bash
wrong=$(scripts/lab.sh token alice portal)
scripts/lab.sh claims "$wrong" | jq '{aud, azp}'
curl -s -o /dev/null -w '%{http_code}\n' https://mcp.localtest.me/mcp -H "Authorization: Bearer $wrong" \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab","version":"1"}}}'
```

Expect 403 for the portal token even though it came from the same issuer. See [AuthZEN enforcement](../adr/017-authzen-pep.md) and OAuth protected resource metadata (RFC 9728).
