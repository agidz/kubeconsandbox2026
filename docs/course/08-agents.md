# Module 8 — Run and inspect a sandboxed agent

kagent describes agents and their models. Agent Substrate runs the agent process in a gVisor sandbox and tracks each session as an actor. Substrate snapshots idle actors so the worker can serve other sessions, then restores the snapshot when a new message arrives. Network and identity controls still apply when a runtime resumes.

## Lab 8.1 — Inspect agent configuration

```bash
kubectl -n kagent get harness,agenttemplates,agents,modelconfigs
kubectl -n kagent get modelconfig default -o yaml | yq '.spec'
kubectl get workerpools -A
```

The ModelConfig requests `actorJwt` injection by the egress gateway. Agent Router validates the evidence that the call came from a live actor session.

## Lab 8.2 — Watch an actor idle and resume

```bash
scripts/lab.sh ask hello-substrate - "In one sentence, what is gVisor?"
scripts/lab.sh actors | tail -5
```

Observe a suspended session. Continue a session in the kagent UI and check that the snapshot version advances. Grafana reports resume and suspend latency. The original measurements were around 250 ms and 150 ms at p95.

## Lab 8.3 — Call inference without an actor JWT

```bash
kubectl -n agent-router run probe --rm -i --restart=Never --image=docker.io/alpine/k8s:1.37.0 --command -- \
  curl -s -o /dev/null -w '%{http_code}\n' -H 'content-type: application/json' \
  -d '{"model":"sandbox-stub","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
  http://agent-router.envoy-gateway-system.svc.cluster.local/anthropic/v1/messages
kubectl -n agent-router get securitypolicy require-actor-jwt -o yaml | yq '.spec.jwt'
```

Expect 401 and identify the issuer configured in the policy.

## Lab 8.4 — Locate provider credentials and the network boundary

```bash
kubectl -n kagent get secrets
kubectl -n agent-router get externalsecret anthropic-apikey -o yaml | yq '.spec.data'
kubectl -n ate-system get networkpolicy atenet-egress-in-cluster-only -o yaml | yq '.spec'
```

The Anthropic key is seeded in OpenBao and synchronized near Agent Router. The agent namespace does not receive it. The egress policy restricts the gateway to in-cluster destinations even if kagent lists an upstream hostname. Verify with `make verify LAYER=3`.

## Lab 8.5 — Trace a deterministic model call

```bash
scripts/lab.sh ask mcp-agent-stub alice "echo hello"
kubectl -n agent-router logs deploy/model-stub --tail=3
```

Read which actor sent the call and which tools were offered. Compare with “add 2 and 3” and “show the environment.” Explain what identity and network access an agent runtime has even if its code misbehaves.

See [inference gateway selection](../adr/007-agent-router-over-agentgateway.md), [identity material](../adr/010-substrate-ca-pools-job.md), and [egress policy](../adr/013-agent-egress-only-via-agent-router.md).
