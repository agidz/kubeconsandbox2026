# ADR-010 — Generate Substrate identity material in a Kubernetes Job

**Status** Accepted and amended on 2026-11-15

Agent Substrate 1.0 needs certificate signer and actor-token pools normally set up by the kagent CLI. The bootstrap chart covers the missing pools, actor identity root, API authentication, database client CA bundle, and trust bundle containing the sandbox root.

Run the checksum-verified pinned `kubectl-ate` commands from a Job in `manifests/substrate-bootstrap`. Grant access only in the relevant namespaces. Create missing material and preserve existing keys across syncs. Rotate by removing the corresponding Secret and resyncing. A hand-written pool without its required `pool` field can surface as `GoldenActorCrashed`.

Name the Job from its spec hash so a change runs a new Job and Argo prunes the previous one. The earlier Sync hook could change without triggering a sync. An imperative laptop invocation would place the setup outside Argo, and committing the generated material would expose keys. Replace the Job when the upstream chart supports this setup.
