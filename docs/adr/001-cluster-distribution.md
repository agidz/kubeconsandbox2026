# ADR-001 — Kubernetes distributions for development and handoff

**Status** Accepted and amended on 2026-11-14

Agent Substrate requires Kubernetes 1.37 with the v1 Pod Certificate and ClusterTrustBundle APIs and a runtime that supports gVisor. The platform must fit on a single host and eventually support WSL2, native Linux, and Linux with a GPU.

## Decision

Use kind on Docker Desktop for development under `ENV=wsl-kind`. Keep k3s as the intended single-binary distribution for `wsl-k3s`, `linux`, and `linux-gpu`. Confine provider-specific bootstrap logic to `envs/<ENV>/` and express differences in Argo-managed components with provider values overlays.

## Evidence and follow-up

The k3s kubelet failed in the development WSL distro because Docker Desktop 4.99.0 mounted `/Docker/host` with an unescaped space. The mount table entry had seven fields where kubelet expected six. A kind node runs kubelet in a separate mount namespace and avoided the error. In the kind experiments, a gVisor-backed Agent became ready in about 18 seconds and resumed in about 0.2–0.3 seconds.

The k3s providers still stop at preflight. Validate them on Linux before enabling them. For WSL, use a distro without Docker Desktop integration and reject malformed entries in `/proc/mounts` with the `awk 'NF!=6' /proc/mounts` check. Record any differences in load balancing, ingress, bundled CRDs, and CoreDNS in the provider design.

Disabling Docker Desktop conflicts with the development host setup. Unmounting its host mount would need to be repeated after restarts. Running kind everywhere would require Docker on every recipient's machine. minikube and k0s offered no additional benefit for these environments.
