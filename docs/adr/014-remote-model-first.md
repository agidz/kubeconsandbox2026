# ADR-014 — Select the inference provider through one setting

**Status** Accepted and amended on 2026-11-15

The platform's identity, delegation, and tracing examples should work across hardware and API access. Originally the default was Anthropic, with local vLLM as an optional layer. A scripted model was added to demonstrate tool calls without paid API credits. The final amendment made CPU inference the default.

Set `MODEL_PROVIDER` to `vllm`, `anthropic`, or `stub`, then rerun bootstrap. Every agent uses ModelConfig `default`, and Agent Router applies the same actor identity policy to each backend. The Anthropic key lives at `secret/models/provider` in OpenBao. Requests without a valid key receive 401. The scripted stub responds predictably to tool-call prompts.

The default local deployment serves Qwen2.5-1.5B through llm-d with one CPU replica. Bootstrap mirrors the chosen Hugging Face revision into Harbor. Selecting vLLM enables layer 5 independently of the profile, and switching providers removes the local application. Preflight compares model memory needs with host capacity. See [model sizing](../model-sizing.md).

Live models decide which tools to call, so the deterministic kagent delegation checks require `stub`. The delegation and authorization checks that bypass kagent run independently. Direct calls to providers would lose centralized identity enforcement, credentials, and metrics.
