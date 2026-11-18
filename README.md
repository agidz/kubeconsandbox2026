# kubeconsandbox

Run a cloud-native agent platform on one host and follow a request through identity, authorization, model inference, and tool execution. The sandbox uses kagent and Agent Substrate for agents, Argo CD for GitOps, SPIFFE/SPIRE for workload identity, OpenBao for secrets, and Envoy Gateway and Agent Router for agent egress.

The original project exercised layers 0–5 on `wsl-kind`. The k3s environments are placeholders. The [course](docs/course/README.md) contains 12 hands-on modules. See the [architecture decisions](docs/adr/) and [maintainer guide](docs/operating.md) for implementation details.

## Run the sandbox

Use WSL2 with Docker Desktop integration enabled. Install Bash, curl, Git, jq, OpenSSL, Make, and Python 3 with bcrypt. The bootstrap installs the other command-line tools into `bin/` at the versions recorded in `versions.yaml` and verifies their release checksums.

Plan for about 24 GiB of RAM with the default local model or 16 GiB with the stub or Anthropic provider. Preflight requires at least 12 GiB of host RAM and recommends 60 GiB of free disk.

```bash
cp config.env.example config.env  # Optional. Defaults are built in.
make bootstrap
make verify
```

| Command | Use |
|---|---|
| `make steps` | Inspect the step list and recorded status |
| `make step S=cluster` | Run a single step |
| `make resume S=cluster` | Continue from a named step |
| `make dry-run` | Preview bootstrap actions |
| `make verify LAYER=0` | Check a specific layer |
| `make tools` | Install the pinned command-line tools |
| `make teardown` | Remove the cluster and step markers while retaining the root CA |

Each step writes a log under `.state/logs/`. If a step fails, bootstrap displays the log tail and prints a resume command.

For HTTPS access to `*.localtest.me`, load the sandbox CA into the current shell.

```bash
eval "$(scripts/ca-env.sh)"
```

This sets trust bundle variables for curl, Git, Helm, kubectl, Python, and Node. Use `eval "$(scripts/ca-env.sh --unset)"` to undo it. Bootstrap also prints optional commands for installing the CA on Linux and Windows.

## Select an inference provider

Set `MODEL_PROVIDER` in `config.env` and rerun bootstrap. All agents share the kagent `default` ModelConfig and reach inference through Agent Router with a short-lived actor JWT.

| Provider | Behavior and configuration |
|---|---|
| `stub` | Returns deterministic tool calls for prompts such as “echo hello,” “add 2 and 3,” and “show the environment.” The delegation checks use it. |
| `anthropic` | Calls Anthropic's API. Set `MODEL_API_KEY` and optionally `MODEL_NAME`. OpenBao stores the key for Agent Router. |
| `vllm` | Serves a model on CPU through llm-d. Bootstrap verifies and publishes the model weights to Harbor, and pods mount them from the registry. Defaults are Qwen2.5-1.5B-Instruct, one replica, and 8192 tokens. Configure `VLLM_MODEL`, `VLLM_MODEL_REVISION`, `VLLM_REPLICAS`, and `VLLM_MAX_TOKENS` as needed. |

The [model sizing guide](docs/model-sizing.md) reports measured resource use and performance. Choose a small instruction-tuned model with tool calling support. Bootstrap sizes each replica and removes the local deployment if you switch providers.

## Repository layout

| Path | Role |
|---|---|
| `bootstrap.sh` | Selects and executes the deployment steps |
| `scripts/steps/` | Implements the check, apply, and verify lifecycle for each step |
| `scripts/lib/` | Supplies shared configuration, state, logging, and cluster operations |
| `envs/` | Defines cluster-provider operations and overrides |
| `versions.yaml` | Records the pinned tools and dependencies |
| `argocd/root/`, `manifests/`, `values/` | Defines the GitOps applications, charts, and chart configuration |
| `docs/` | Contains course material, architecture decisions, and operating guides |

## Deployment tradeoffs

The sandbox uses small, colocated services so it can run on one host. The [course](docs/course/README.md) covers changes needed for production.

- OpenBao uses a Kubernetes Secret for static unseal. A managed KMS or HSM supports production auto-unseal.
- Services run as single replicas and Jaeger keeps traces in memory. Production deployments need availability and persistence.
- The root CA key lives on disk, and CA rotation requires deleting a Secret and resyncing. Production systems can use an offline root, managed intermediates, and automated rotation.
- Harbor's bundled database uses its chart's `changeit` password. Agent Substrate's bundled RustFS uses its chart credentials. External services can use separately generated credentials.
- Argo CD, Gitea, Harbor, and Grafana retain local administrator accounts alongside SSO. The passwords live in OpenBao.
- Gitea, Harbor, Argo CD, and OpenBao run in the same cluster they support. A separate management cluster and managed Git service reduce that coupling.

## Third-party materials

See [third-party notices](THIRD_PARTY_NOTICES.md) for the origins, modifications, and license of the vendored files.
