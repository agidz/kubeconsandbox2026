# ADR-013 — Require Agent Router for model egress

**Status** Accepted on 2026-11-15 after S3 and S4

Every inference call must use the same identity, telemetry, and credential controls. kagent can add the public inference provider to the actor's destination allowlist even when the configured model endpoint is internal. EgressPolicy can add destinations, so the network boundary must independently limit reachability.

`atenet-egress-in-cluster-only` restricts Substrate's egress gateway to in-cluster destinations. ModelConfigs use `actorJwt`. Agent Router validates the Substrate actor JWT through the `models` HTTPRoute's SecurityPolicy before forwarding with the provider credential. Keep that credential at Agent Router.

The experiments verified that the agent reaches external inference only through the router and that a request without the JWT receives 401. Use fully qualified cluster DNS names because the sandbox has no DNS search domains. Revisit this decision when `XAccessPolicy` is available. Giving each agent a key would increase credential distribution and bypass the shared metering path.
