# ADR-016 — Reconcile Keycloak realm configuration from Git

**Status** Accepted on 2026-11-15

The operator's realm import runs when the realm is first created. Subsequent changes to redirect URIs, PKCE clients, audiences, delegation, and authorization need a repeatable reconciliation. The operator's OIDC client API cannot describe all the needed mappers, scopes, users, and groups.

Use Apache-2.0 keycloak-config-cli to apply the rendered `realm-config.yaml`. Argo runs a Job named after the configuration hash. The CLI owns its managed resources, records ownership in realm attributes, and reapplies Git settings while preserving unrelated manually created objects. Keep edits to managed resources in Git.

External Secrets Operator fills `realm-placeholders` from OpenBao. The realm Job logs in with the least-privilege master client `realm-config`; the one-time admin bootstrap creates that client using `keycloak-initial-admin`. OpenBao supplies user passwords on each run. Match `ssoHosts` in the Keycloak chart to the gateway's SSO routes, which layer 2 verification checks.

Version 6.5.1 of the CLI was built against Keycloak 26.5.5 and tested here with 26.8.2. Recheck compatibility when updating the pinned images. The CLI is an exception to the foundation preference because of its focused declarative API. A Terraform or OpenTofu provider adds a state backend and GitOps controller. Maintaining custom admin API code would duplicate the CLI's reconciliation.
