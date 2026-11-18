# Module 6 — Sign in with Keycloak

Keycloak's sandbox realm defines users, groups, clients, and scopes. An OpenID Connect client uses an ID token to establish the human session. A resource server uses an access token after checking the signature, issuer, expiration, and intended audience. The Inspector runs in a browser, where a client secret would be available to users. Instead, code flow with PKCE binds the exchange to the client that started it.

## Lab 6.1 — Inspect access-token claims

```bash
token=$(scripts/lab.sh token alice)
scripts/lab.sh claims "$token"
scripts/lab.sh token bob | scripts/lab.sh claims
```

Compare the groups. Confirm that `azp` identifies `mcp-inspector`, `aud` includes the MCP URL, and `iss` identifies the realm. Check the expiry in `exp`.

## Lab 6.2 — Reuse the realm session

In one private browser window, sign into Grafana as admin and then choose Keycloak login in Argo CD. The second site should reuse the Keycloak browser session while establishing its own application session. Try Gitea, Harbor, and OpenBao. Choose OIDC in OpenBao.

## Lab 6.3 — Reconcile the realm

```bash
yq '.clients[].name, .publicClients[].name' manifests/keycloak/values.yaml
yq '.users' manifests/keycloak/values.yaml
kubectl -n keycloak get jobs
```

Add a viewer named carol to the values and commit. Run `./bootstrap.sh --only openbao --force openbao` to seed the account's password, then `./bootstrap.sh --only gitea` to publish the realm change. A new Job reconciles the realm because its configuration hash changed. Read the password at `secret/platform/sso-users/carol`, try the login, and revert and publish the Git change after the lab.

## Lab 6.4 — Follow a group into policy

In the sandbox realm console, inspect Bob's group membership. Find references to `sandbox-viewers` in `manifests/` and `values/`. Compare the group's meaning in OpenBao, the gateway, and MCP policy. Explain what could happen if an MCP server accepted every token from the realm regardless of audience.

See [realm reconciliation](../adr/016-keycloak-realm-as-code.md). For protocol details, see OAuth 2.0 (RFC 6749), PKCE (RFC 7636), OIDC Core, and JWT (RFC 7519).
