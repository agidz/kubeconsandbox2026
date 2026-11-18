# InferencePool API definitions

This directory contains the Gateway API Inference Extension v1.6.2 resources. Agent Router and llm-d use `inference.networking.k8s.io/v1`. The layer 1 Argo application owns the API because Envoy Gateway watches InferencePools as soon as it starts. The layer 5 router uses those pools to select vLLM endpoints.

When changing the dependency pin under `operators.gateway-api-inference-extension` in `versions.yaml`, refresh the manifest from that upstream release.

```bash
release=v1.6.2
upstream=https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download
curl --fail --silent --show-error --location "$upstream/$release/v1-manifests.yaml" \
  --output manifests/gateway-api-inference-extension/v1-manifests.yaml
```

See [third-party notices](../../THIRD_PARTY_NOTICES.md) for license and modification details.
