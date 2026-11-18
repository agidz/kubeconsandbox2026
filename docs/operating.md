# Operate and debug the sandbox

## Publish a change

1. Edit the local repository and render the affected chart with `bin/helm template`. Supply `versions.yaml` for the root chart and any install inputs the affected chart requires.
2. Commit the change and run `./bootstrap.sh --only gitea`. The mirror receives HEAD and the step requests an Argo refresh. Gitea's push webhook uses the public URL and does not match Applications using the internal URL.
3. Check Argo sync and health. If needed, annotate the Application with `argocd.argoproj.io/refresh=hard`, then run `make verify` or choose `LAYER=n`.

Set `REPO_URL` to deploy from a reachable remote instead of Gitea. Keep `config.env` and `.state/` out of commits. Change the profile, model, or base domain through configuration and rerun bootstrap so the root Application receives the new inputs.

## Inspect access and policy

Use `scripts/print-access.sh --passwords` in your terminal, and load CA trust with `eval "$(scripts/ca-env.sh)"`. Admin operates the platform, alice is the administrator demo user, and bob is the viewer. Source `scripts/lib/common.sh` for the following helpers.

| Helper | Purpose |
|---|---|
| `bao_connect`, `bao_kv_get` | Reach OpenBao and read a KV field with the short-lived operator role |
| `kc_admin` | Call the sandbox realm admin API |
| `pkce_token`, `sso_browser_login` | Complete browser-style login and obtain a token or session cookies |
| `delegated_token`, `actor_token`, `agent_run` | Exercise token exchange or run delegate.sh as the mcp-agent ServiceAccount |
| `mcp_session`, `mcp_call` in verify.sh | Exercise direct and delegated MCP sessions |

The Keycloak chart values declare users, clients, delegation actors, and AuthZEN tool policies. Commit changes to managed realm objects. For a live policy demo, grant and revoke `mcp-env-reader` on Bob. Switch the MCP chart's `decisions` between `keycloak` and `token` to compare fresh decisions with claim-based checks. Both use Agent Router's delegated agent allowlists.

## Deployment diagnostics

- Argo's root waves order Application creation. Argo CD 3.6 does not wait for child Application health by default. Keep a route with the layer that installs its backend. Create non-destination namespaces explicitly.
- Within the SPIRE Application, wave −1 applies the OpenBao CA ExternalSecret. This gives Argo a chance to retry if the External Secrets webhook is still starting. Wave 0 brings up the server and its admission webhook. Wave 1 applies workload identity registrations. Wave 2 starts OIDC discovery, which needs a registered identity to fetch signing keys.
- A sync retries its original commit. If it sticks, terminate the operation through the Argo API using `DELETE /api/v1/applications/<app>/operation`, refresh, and retry. A Gitea restart can interrupt all Git fetches until refresh.
- Self-heal quickly reverses manual Deployment changes, including rollout restart annotations. Restart an Argo-managed pod by deleting the pod. Use regular Jobs named from the spec hash for reconciliation jobs that must run again after a Git change.
- Put every source registry in `registry_mirrors`. Use a compatible source path for images with single-segment names that Harbor cannot proxy. The kind node pulls Harbor-hosted artifacts via the static ClusterIP in containerd's `hosts.toml`.
- The realm CLI needs explicit default scopes for clients that also declare optional scopes. It does not own fine-grained admin permissions, which the realm Job applies separately. Realm feature changes restart Keycloak. Users created in Git get `default-roles-sandbox` through realm configuration.
- Keycloak accepts a SPIRE client assertion only within five minutes of issuance. Use the configured five-minute SVID lifetime so reuse stays within that limit.
- Gitea's Keycloak source is installed by `70-sso` after Keycloak is up. Configuring it as a Gitea init step creates a fresh-install dependency cycle.
- Harbor's internal DNS rule precedes the anchored wildcard rewrite. DNS search suffixes must not send Harbor through a gateway that may not yet exist.

## Runtime diagnostics

- Agent Router's external model processor runs before the JWT check. Use a well-formed request to check for 401. A wrong-audience MCP token gets 403. An anonymous MCP request receives a 401 challenge.
- Tool names on the route use `<backend>__<tool>`. Compare the tool bindings with the offered tools logged by the stub. A failed call may appear to the model as an `isError` tool result.
- The current MCP implementation expects a session. kagent may get one discovery 400 before falling back to initialize. During route replacement, let Envoy converge before treating a requirement-name 403 as persistent.
- In Keycloak decision mode, a directly authenticated user may list a tool that they cannot invoke. Delegated lists still reflect the agent allowlist.
- Keep long-lived chat, Inspector, and MCP routes at `timeout: 0s`. The default 15-second timeout disrupts streams. The verification script exercises a 25-second stream.
- Keep MCPRoute in the tool backend namespace and permit that namespace on the internal gateway. The Inspector preset disables refresh-token requests because its client cannot use `offline_access`.
- Use fully qualified DNS names in Substrate. The OpenTelemetry Go SDK needs the gRPC protocol for OTLP port 4317. Probe pods using `kubectl run -i` should wait for input to avoid producing output before attachment.
- Trace a delegated call by searching Jaeger for `delegation-proxy` and `user.name`, `gen_ai.agent.name`, or `gen_ai.tool.name`. Missing Substrate egress spans can leave children with missing parents in the correct trace.
- Concurrent kagent CLI calls collide on port 8083. For load tests, use one forward to the controller's A2A endpoint. The vLLM Deployment disables service links to avoid a Service-generated `VLLM_PORT`. Restart Envoy Gateway when changing its extension backend resource types on a running cluster.
- Check [model sizing](model-sizing.md) before adding replicas. An empty NetworkPolicy egress list can be omitted by the API while still denying egress.

## Rebuild evidence and current limitations

The original WSL kind build on 2026-11-15 ran all 99 verification checks and the course labs. Bootstrap took about 11 minutes with the model download. The rebuild exposed OpenBao init file handling, the need for a distinct realm-admin grant Job, CoreDNS rule anchoring, and the Gitea bootstrap dependency. k3s and GPU deployment remain untested.

OpenBao config still runs in bootstrap. For emergency root recovery, use the recovery key from ignored local state with OpenBao's generate-root procedure. The realm config job uses the restricted `realm-config` client. Only the admin-bootstrap and realm-admin grant jobs use the operator's temporary master credentials.

The verification script uses the kagent A2A endpoint and does not exercise the browser's gRPC-Web path. The agent-to-proxy hop uses configuration and NetworkPolicy for its agent binding until kagent can supply actor evidence along with token passthrough. kagent's insecure mode depends on the controller NetworkPolicy. RustFS retains its bundled credentials. See the [trust map](trust-map.md) and [delegation decision](adr/018-agent-delegation-proxy.md).
