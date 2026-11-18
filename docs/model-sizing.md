# Size the local inference deployment

The numbers below were measured on 2026-11-15 using a Ryzen 7 9850X3D with eight cores, 16 threads, AVX-512 BF16, and 31 GiB RAM. The kind cluster ran under WSL2. vLLM CPU v0.33.0 mounted bf16 weights from Harbor and used an 8,192-token context. Prefill tests sent a unique 3,000-token prompt with one output token. Decode tests requested 256 tokens. The tests used one request at a time unless noted.

## Measured results

| Hugging Face model | Weights | 8k KV allocation | Replica RAM | Threads | Prefill tok/s | Decode tok/s | One-word reply |
|---|---:|---:|---:|---:|---:|---:|---:|
| Qwen/Qwen2.5-0.5B-Instruct | 1 GiB | 1 GiB | 5.0 GiB | 4 | 1,475 | 36 | 0.05 s |
| Qwen/Qwen2.5-1.5B-Instruct | 3 GiB | 1 GiB | 7.3 GiB | 8 | 719 | 11.6 | 0.14 s |
| Qwen/Qwen3-4B | 8 GiB | 2 GiB | 13.6 GiB | 8 | 256 | 5.0 | 0.20 s |

All three use Apache-2.0. The 1.5B model chose and executed a delegated tool call. Tool calling was not evaluated for the other models. Qwen3 thinking mode would require a reasoning parser. Two 0.5B replicas with four threads each handled eight concurrent conversations in three seconds, with four running on each replica.

A typical 1–2k-token agent prompt takes roughly 1.5–3 seconds to begin streaming with 1.5B. The 4B model takes around 5–8 seconds. Shared prompts and conversation prefixes benefit from cached prefill.

## Compute memory and CPU

Bootstrap rounds the weight size up to GiB. It estimates BF16 key/value storage as layers × KV heads × head dimension × two tensors × two bytes × configured tokens × 1.25. The allocation rounds up to at least 1 GiB. Raw per-token KV state is about 28 KB for Qwen2.5-1.5B and 144 KB for Qwen3-4B, or about 0.23 and 1.12 GiB at 8k tokens.

The chart requests weights plus KV allocation plus overhead. Runtime overhead is 3 GiB plus one eighth of the weight size. Add 2 GiB to get the memory limit. The chart divides eight OpenMP threads across replicas without pinning cores. Each replica loads the entire model, so replicas raise concurrency and memory consumption while sharing the CPU.

| Docker/WSL RAM | Approximate inference budget | Example |
|---:|---:|---|
| 24 GiB | 8 GiB | One 1.5B |
| 31 GiB | 15 GiB | Two 0.5B or one 4B |
| 48 GiB | 30 GiB | Two 1.5B or two 4B |

Reserve about 14 GiB for the rest of the platform plus room for the host.

## Tune endpoint selection for CPU replicas

The picker favors a cached prefix unless the estimated first-token time exceeds the configured penalty relative to another replica. It estimates prefill cost using in-flight tokens and `peakPrefillThroughput`. The upstream H100 values of 15,928 tokens/s and 18 seconds sent all eight test requests to one CPU replica. Around 1,500 tokens/s and 1 second split the test four and four.

For another model, benchmark a single 3,000-token prompt with `max_tokens: 1` against a port-forward to vLLM's `/v1/chat/completions`. Divide `usage.prompt_tokens` by the elapsed time and update `values/llm-d-router/values.yaml` when using multiple replicas.

## GPU estimates

The GPU provider remains unimplemented. The same weight and KV estimates apply to VRAM with less CPU-specific overhead. A 16 GB RTX 5080 might fit roughly a 7–8B bf16 model at 8k context or a 14B four-bit model. These estimates are unmeasured. WSL kind GPU support would require driver mounts in the node container and cluster recreation.
