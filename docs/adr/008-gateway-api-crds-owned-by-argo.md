# ADR-008 — One Argo application owns the Gateway API CRDs

**Status** Accepted on 2026-11-15, implemented on 2026-11-14

Gateway API schemas are shared cluster-wide. Multiple charts claiming them can cause sync drift, accidental downgrade, or a conflict on the safe-upgrades policy.

Deploy `gateway-crds-helm` v1.9.3 as its own Argo application ahead of the gateways. This provides Gateway API v1.6.1 and Envoy Gateway's CRDs. Set `crds.enabled: false` on Envoy Gateway's controller chart. Agent Router keeps a separate application for its own CRDs from `ai-gateway-crds-helm`. kind has no bundled Gateway API, and a future k3s provider must disable the bundled chart.

Upgrade via the pins in `versions.yaml` and verify that Envoy Gateway and Agent Router support the chosen version. The distribution's bundle would advance on the distribution's release cycle. Letting each controller chart supply its schemas would create overlapping ownership.
