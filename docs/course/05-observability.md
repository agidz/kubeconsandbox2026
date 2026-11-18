# Module 5 — Inspect metrics and traces

Counters and histograms show patterns across requests. Traces show which components handled a particular request and how long each operation took. Services propagate a trace ID and parent span ID and send OTLP to the OpenTelemetry Collector. Jaeger stores traces, Prometheus receives metrics, and Grafana presents both. Consistent OpenTelemetry attribute names make records from different services comparable.

## Lab 5.1 — Generate inference traffic

```bash
scripts/lab.sh ask hello-substrate - "In one sentence, what is Prometheus?"
```

Open Grafana at `https://grafana.localtest.me` and find **Agents (Substrate + Agent Router)**. Follow the runtime resume and suspend counters, Agent Router request totals and token counts, delegation outcomes, and vLLM prefix-cache and throughput panels.

## Lab 5.2 — Compare spans in the same trace

In Jaeger, search for service `kagent-controller` and open the latest trace. Locate the actor name on an agentgateway span, the runtime span, and the Agent Router chat span with model and token attributes. The Substrate egress gateway rewrites the parent context without exporting its own span, so there can be a missing parent even while the trace ID stays the same.

## Lab 5.3 — Query the measurements directly

In Prometheus, run these expressions individually.

```promql
sum(rate(gen_ai_server_request_duration_seconds_count[5m])) by (gen_ai_request_model)
histogram_quantile(0.95, sum(rate(gen_ai_server_request_duration_seconds_bucket[15m])) by (le))
sum by (user_name, gen_ai_agent_name, outcome) (delegation_proxy_calls_total)
```

The results give per-model request rate, a p95 duration estimate, and delegation calls grouped by the user, agent, and result.

## Lab 5.4 — Send an OTLP span

```bash
kubectl -n monitoring port-forward svc/otel-collector 4318:4318
```

From a second terminal, submit a span to the collector. Use current nanosecond timestamps so Jaeger can find it in the default window.

```bash
start=$(date +%s%N)
end=$((start + 1000000))
jq -n --arg start "$start" --arg end "$end" '{
  resourceSpans: [{
    resource: {attributes: [{key: "service.name", value: {stringValue: "my-lab"}}]},
    scopeSpans: [{spans: [{
      traceId: "5b8efff798038103d269b633813fc60c",
      spanId: "eee19b7ec3c1b174",
      name: "hello",
      kind: 1,
      startTimeUnixNano: $start,
      endTimeUnixNano: $end
    }]}]
  }]
}' | curl -sS localhost:4318/v1/traces -H 'content-type: application/json' --data-binary @-
```

Find `my-lab` in Jaeger and stop the port-forward. Explain why counting model requests at Agent Router gives a single source for usage figures. See the [Grafana decision](../adr/006-grafana-oss.md).
