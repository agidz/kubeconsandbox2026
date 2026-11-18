# Module 11 — Serve open weights from the local registry

Bootstrap resolves a Hugging Face model revision, verifies the downloaded files, packages them into an OCI image, and publishes it to Harbor with ORAS. The vLLM pods mount the image read-only under `/models/` using Kubernetes image volumes. Serving the weights requires neither a runtime download from Hugging Face nor bundling them inside the vLLM image.

Agent Router validates the actor JWT and forwards to an InferencePool. llm-d's endpoint picker scores replicas by load and cache information. Prefill reads input tokens before generation. Decode produces the output tokens. Cached key/value state lets a replica avoid repeating prefill for shared prefixes.

## Lab 11.1 — Locate the artifact and mount

```bash
scripts/lab.sh model
yq '.models' versions.yaml
ls -la .state/models/*/files/
kubectl -n models get deploy vllm -o yaml | yq '.spec.template.spec.volumes[] | select(.image)'
docker exec kubeconsandbox-control-plane crictl images | grep models/
```

Compare the image tag with the pinned revision. Find the artifact digest in Harbor's `models` project.

## Lab 11.2 — Compare the server and agent paths

```bash
kubectl -n models port-forward deploy/vllm 18000:8000
```

From a second shell, find the served model and send a request to it. Substitute the name you found if it differs from the default.

```bash
curl -s localhost:18000/v1/models | jq '.data[].id'
curl -s localhost:18000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"qwen2.5-1.5b-instruct","max_tokens":40,"messages":[{"role":"user","content":"What is a KV cache?"}]}' |
  jq -r '.choices[0].message.content'
scripts/lab.sh ask hello-substrate - 'What is a KV cache? One sentence.'
```

Stop the port-forward. The agent path includes identity checks, routing, and trace spans that the administrative port-forward bypasses.

## Lab 11.3 — Observe cache affinity

Send a few messages in the same agent conversation. Open the local model row of the Agents dashboard and examine prefix-cache hit rate. Shared system prompts can produce rates above 90%.

## Lab 11.4 — Change the model and compare its footprint

Set `VLLM_MODEL=Qwen/Qwen2.5-0.5B-Instruct` in `config.env`. Rerun bootstrap and use `scripts/lab.sh model` to check the name. Compare speed and memory against the default. The sizing logic uses repository file sizes and the model configuration to estimate weights and KV cache. See [measured model sizes](../model-sizing.md).

## Lab 11.5 — Add a replica

On a machine with enough RAM, set `VLLM_REPLICAS=2` for the small model and rerun bootstrap.

```bash
kubectl -n models get pods -l app=vllm
for i in 1 2 3 4 5 6; do
  scripts/lab.sh ask hello-substrate - "Topic $i: name one CNCF project." &
done
wait
```

Check requests per replica in Grafana. The tuned throughput and latency penalties in `values/llm-d-router/values.yaml` let the CPU replicas share load when one falls behind. The prior untuned GPU defaults concentrated requests on one replica. Restore your original model and replica settings after the lab.

## Lab 11.6 — Select a different provider

Set `MODEL_PROVIDER=stub` and rerun bootstrap. The vLLM application is removed. Set the provider back to `vllm` to restore it. Use `scripts/lab.sh model` after each change. The agents still use ModelConfig `default`. See the [model provider decision](../adr/014-remote-model-first.md) and [artifact registry decision](../adr/012-harbor-mirror-and-model-store.md).
