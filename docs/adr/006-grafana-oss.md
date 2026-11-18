# ADR-006 — Grafana OSS for traces and metrics

**Status** Accepted on 2026-11-15, implemented on 2026-11-14

The observability demo needs to connect platform metrics to request traces that show a user, an agent, and a tool call. The OpenTelemetry Collector sends data into a stack with Prometheus for metrics and Jaeger for traces.

Use the AGPL-licensed Grafana OSS chart v14.4.1 with Grafana 13.3.1 in `monitoring`. Provision Prometheus and Jaeger datasources and load dashboards from ConfigMaps labeled `grafana_dashboard=1`. Keycloak handles browser login, and External Secrets Operator supplies the local admin password from OpenBao. Run Grafana unmodified and use its open-source plugins.

Keep Jaeger at 2.20.0 until Grafana's Jaeger datasource works with the newer query APIs. Grafana and Harbor use the SSO user's email to avoid a collision between the SSO `admin` and the local account. Revisit the exception if Perses supports the required trace datasource. Independent Jaeger and Prometheus interfaces would lose the unified dashboard and dashboard provisioning workflow.
