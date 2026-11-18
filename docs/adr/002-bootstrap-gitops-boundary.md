# ADR-002 — Bootstrap the dependencies of Argo CD

**Status** Accepted on 2026-11-14

A new clone should come up with one command and then teach the GitOps workflow it actually uses. Argo CD needs a cluster, trust, credentials, a chart registry, and a Git endpoint before it can reconcile Applications.

## Decision

The bootstrap runner executes the idempotent steps in `scripts/steps/` in order. These bring up the cluster, CA, OpenBao, Harbor, Gitea, and Argo CD's root Application. Argo then adopts the bootstrapped components with matching values and installs the remaining components in sync waves. Subsequent platform changes flow through Git.

Each step implements check, apply, and verify. Local state tracks completion, including the hash of `versions.yaml`, so a manifest change prompts the next run to revisit completed steps. A failure reports the log and resume command. Inputs come from configuration, the version manifest, or OpenBao, which allows the run to proceed without prompts.

Bootstrap and Argo must use the same component values under `values/` to avoid a rollout during adoption. A fully imperative install would leave drift management to scripts. Starting with Argo alone would require the external Git and registry dependencies this design is intended to avoid.
