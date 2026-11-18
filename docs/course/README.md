# Build and inspect an agent platform

This course takes you from a new single-node Kubernetes cluster to an agent that acts for a named user with consent. You'll configure GitOps, examine TLS and workload identities, follow inference and tool requests through gateways, and compare allowed and denied calls using traces and metrics.

You'll need basic terminal and Kubernetes Pod familiarity. The labs use kubectl, browser UIs, and `scripts/lab.sh` for flows such as login and token exchange.

## Course sequence

| Module | Lab focus | Time |
|---|---|---|
| [1. Getting started](01-getting-started.md) | Build, validate, and recover the sandbox | 45 min plus build |
| [2. GitOps](02-gitops.md) | Argo Applications, sync waves, Gitea, and registry mirrors | 60 min |
| [3. Trust and secrets](03-trust-and-secrets.md) | Read a certificate chain and trace a credential | 60 min |
| [4. Gateway](04-gateway.md) | Route by hostname and inspect TLS and OIDC behavior | 45 min |
| [5. Observability](05-observability.md) | Read spans and query metrics | 45 min |
| [6. Identity for people](06-people-identity.md) | Use Keycloak SSO and inspect OAuth claims | 60 min |
| [7. Workload identity](07-workload-identity.md) | Obtain an SVID and authenticate without a password | 60 min |
| [8. Agents](08-agents.md) | Inspect gVisor sessions, actor tokens, and egress | 75 min |
| [9. Tools and authorization](09-tools-and-authorization.md) | Compare MCP calls under Keycloak tool policy | 60 min |
| [10. Delegation](10-delegation.md) | Exchange a consented token and attribute a tool call | 75 min |
| [11. Local models](11-local-models.md) | Package, serve, and route a model | 60 min |
| [12. Capstone](12-capstone.md) | Explain the full request and the production gaps | 60 min |

Finish module 1 before the other labs. Modules 2–5 can be taken in any order. Complete 6–10 in sequence. Module 11 can follow module 8. Keep the [command reference](appendix-cheatsheet.md) and [glossary](appendix-glossary.md) nearby.

## Platform layers

| Layer | Components |
|---|---|
| Bootstrap | Kubernetes, local CA, OpenBao, Harbor, Gitea, and Argo CD |
| Platform | Envoy Gateway, cert-manager, External Secrets, CloudNativePG, and telemetry |
| Identity | Keycloak for people and SPIRE for workloads |
| Agents | Agent Router, Substrate, kagent, and demo agents |
| Delegation | MCP tools, per-call policy, and the token exchange proxy |
| Local model | vLLM on CPU with Harbor image volumes behind llm-d |

The browser reaches services through the shared Envoy Gateway. Agent processes run in Substrate and reach inference through Agent Router, which validates the actor identity. Tool requests for a user first go through token exchange. Agent Router checks the resulting token and Keycloak decides whether the user can invoke each tool. Argo manages the deployment, OpenBao supplies credentials, and OpenTelemetry carries evidence about requests to Jaeger and Prometheus.

## Teaching notes

Allow about 24 GiB RAM with the default model or 16 GiB using the stub. Budget 20–30 minutes and roughly 10 GB of downloads for an initial build. Use `make verify LAYER=<number>` to confirm a module's prerequisites. The [decision records](../adr/) explain the choices behind the exercises. Have students identify production limitations before reading the capstone list.
