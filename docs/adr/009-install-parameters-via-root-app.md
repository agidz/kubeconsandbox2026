# ADR-009 — Carry install parameters in the root Application

**Status** Accepted and amended on 2026-11-14, documented on 2026-11-15

Each installation supplies its own environment, profile, repository, revision, base domain, model selection, registry, and CA. These inputs need to reach Argo-managed components from a single source.

Bootstrap builds the root Application values in `scripts/lib/argo.sh`. The `argocd/root` Helm chart consumes those values along with `versions.yaml`. Layer templates select Applications and supply their version, sync wave, and component values. `_values.tpl` passes through inputs that must also match the bootstrap installs.

Rerun bootstrap to change install inputs. Keep the dependency versions in `versions.yaml` and use environment overlays for provider-specific values. Committing rendered resources would put per-install inputs in shared Git. Using ApplicationSet generators here would require duplicating the version pins.
