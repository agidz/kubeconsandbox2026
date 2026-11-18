# ADR-012 — Harbor holds artifacts, Git holds configuration

**Status** Accepted on 2026-11-15, implemented on 2026-11-14

Use Harbor chart 1.19.4 as the in-cluster artifact registry. `45-mirror-charts` copies the chart pins in `versions.yaml` to the `charts` project, from which Argo installs them. Containerd uses Harbor proxy caches for the upstreams listed in `scripts/lib/harbor.sh`. The `models` project stores OCI artifacts for vLLM image volumes. Maintain manifests and values in Git.

The first install needs roughly 1.5 GB for Harbor images. The local mirror reduces dependence on upstream availability on subsequent builds. `make verify` checks that running images use mirrored registries. Where a proxy cannot support an upstream image path, select a compatible source for the same artifact, as with the Substrate agentgateway image on GHCR.

Direct upstream pulls provide no local cache. A standalone Distribution registry lacks Harbor's per-upstream proxy projects, robot accounts, and interface.
