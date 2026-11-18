# Glossary

| Term | Meaning in this course | Module |
|---|---|---|
| A2A | Agent-to-Agent protocol used by clients to send work to an agent. | 8 |
| Actor | A Substrate session that can be suspended and restored in its sandbox. | 8 |
| Actor JWT | Short-lived proof of the session identity added at Substrate egress. | 8 |
| Agent Router | Envoy-based entry point for inference and MCP calls. | 8, 9 |
| Agent Substrate | Runtime for sandboxes, workers, snapshots, and agent egress. | 8 |
| Argo CD | Controller that reconciles deployments from Git. | 2 |
| AuthZEN | Standard API for requesting a decision about a subject, action, and resource. | 9 |
| Bootstrap | Steps that stand up the dependencies required for GitOps. | 1, 2 |
| CEL | Common Expression Language, used to express request policy. | 9 |
| cert-manager | Kubernetes controller that issues and renews certificates. | 3 |
| Client assertion | Signed proof of an OAuth client's identity. | 7 |
| CloudNativePG | PostgreSQL operator for Keycloak and the agent platform. | 3 |
| Consent | User approval for a client to act on their behalf. | 10 |
| CRD | Kubernetes object that defines an additional resource type. | 2 |
| Decode | Generate output tokens one at a time. | 11 |
| Delegation proxy | Exchange service that acts as the agent's Keycloak client. | 10 |
| Endpoint picker | Chooses an inference replica based on load and cache state. | 11 |
| Envoy Gateway | Controller that configures Envoy using Gateway API and extensions. | 4 |
| ESO | External Secrets Operator, which synchronizes OpenBao values to Secrets. | 3 |
| Gateway API | Kubernetes API for listeners, gateways, and application routes. | 4 |
| gVisor | User-space kernel that isolates sandboxed workloads. | 8 |
| Harbor | Registry for OCI charts, image mirrors, and model artifacts. | 2, 11 |
| Image volume | Mount of an OCI image's files into a Pod. | 11 |
| InferencePool | Resource describing model endpoints and an endpoint picker. | 11 |
| JWKS | Published JSON Web Key Set used to verify signatures. | 6, 7 |
| JWT | Token format carrying JSON claims and optionally a signature. | 6 |
| kagent | Kubernetes controller, API, and UI for agents. | 8 |
| Keycloak | Provider for sign-in, tokens, delegation, and tool policy. | 6, 9 |
| KV cache | Saved key/value attention tensors reused in inference. | 11 |
| llm-d | Distributed inference project supplying the endpoint picker. | 11 |
| MCP | Protocol for discovering and using model tools. | 9 |
| MCPRoute | Agent Router object describing routes and tool policy. | 9 |
| ModelConfig | kagent object that selects the inference service and model. | 8 |
| NetworkPolicy | Kubernetes rules that limit traffic between workloads. | 8 |
| OCI | Open Container Initiative format used for images and registry artifacts. | 2, 11 |
| OIDC | OpenID Connect, the OAuth-based identity protocol. | 6 |
| OpenBao | Credential store and certificate authority service. | 3 |
| OpenTelemetry | Standard SDKs, protocols, and formats for telemetry. | 5 |
| PDP / PEP | Decision service and the component that requests and enforces its answer. | 9 |
| PKCE | Binds an OAuth authorization code to the client that initiated the flow. | 6 |
| Prefill | Process a prompt before decoding response tokens. | 11 |
| Protected resource metadata | RFC 9728 document identifying the authorization server. | 9 |
| Realm | Scoped Keycloak users, clients, and settings. | 6 |
| RFC 8693 | OAuth Token Exchange, used here to obtain delegated access. | 10 |
| SecurityPolicy | Envoy Gateway authentication and authorization settings. | 4 |
| Self-heal | Reconciliation of live drift back to Git's declared state. | 2 |
| SPIFFE ID | Workload URI such as `spiffe://sandbox.local/ns/mcp/sa/mcp-agent`. | 7 |
| SPIRE | Implementation that attests workloads and issues SVIDs. | 7 |
| Stub model | Scripted inference responses used for repeatable demos. | 8 |
| SVID | SPIFFE Verifiable Identity Document in X.509 or JWT form. | 7 |
| Sync wave | Ordering annotation for Argo-managed resources. | 2 |
| Trust domain | Authority responsible for a set of SPIFFE names. | 7 |
| vLLM | Inference server supporting an OpenAI-compatible API. | 11 |
| Workload identity | An assertion issued to a process based on where and how it runs. | 7 |
| `act` | Token claim naming the party acting for the subject. | 10 |
| `aud` | Token claim naming the intended recipients. | 6, 9 |
| `may_act` | Token claim expressing which client can act on a user's behalf. | 10 |
