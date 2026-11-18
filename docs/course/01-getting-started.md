# Module 1 — Bring up the platform

Start here before attempting any other lab. Bootstrap provisions the minimum needed to run Argo CD: Kubernetes, a CA, OpenBao, Harbor, Gitea, and Argo itself. The remaining applications deploy from Git. Each script in `scripts/steps/` checks the existing state and verifies the result. You can rerun bootstrap after an interruption.

## Prepare the host

The tested provider is `wsl-kind` with WSL2 and Docker Desktop integration. The native Linux and WSL k3s provider scripts are placeholders. Allow about 60 GiB of disk, 24 GiB of RAM for the default local model, or 16 GiB for the stub. Install Bash, curl, Git, jq, OpenSSL, Make, and Python 3 with bcrypt. Bootstrap verifies the published checksums of tools it installs under `bin/`.

## Lab 1.1 — Build and resume

From the repository root:

```bash
make tools
make bootstrap
```

Budget 20–30 minutes for a first build. Preflight checks tools, resources, ports, and model sizing. The cluster step creates the node. The CA and OpenBao steps establish trust and credentials. Harbor mirrors charts and stores the local model. Gitea receives the commit and Argo creates the applications. The final steps configure SSO and workload identity and print the service addresses.

On failure, inspect the file named under `.state/logs/`. Fix the cause and resume with `./bootstrap.sh --from <step>`. Use `make steps` to see the step status.

## Lab 1.2 — Verify the deployment

```bash
make verify
make verify LAYER=2
```

Read the individual assertions as a description of what the environment guarantees. A recent deployment may still be converging. Give it time and repeat any failing check.

## Lab 1.3 — Load trust and sign in

```bash
eval "$(scripts/ca-env.sh)"
scripts/lab.sh urls
```

Import `.state/ca/sandbox-root-ca.crt` for browser trust using the instructions in the bootstrap summary. The wildcard domain resolves to host loopback. Try Argo CD at `argocd.localtest.me`, the Agents dashboard at `grafana.localtest.me`, and kagent at `kagent.localtest.me`. Keycloak runs at `keycloak.localtest.me`, Jaeger at `jaeger.localtest.me`, and the registry, Git, and secrets UIs use `harbor`, `git`, and `openbao`. Use HTTPS.

`admin` operates the platform. `alice` represents a member of `sandbox-admins` and `bob` a member of `sandbox-viewers`. The access helper prints their passwords.

## Lab 1.4 — Inspect the cluster

```bash
export PATH="$PWD/bin:$PATH"
kubectl get applications -n argocd
kubectl get ns
kubectl get pods -A | wc -l
```

Expect roughly 34 Applications and 80 pods with the default configuration. Find OpenBao, kagent, and model workloads in their corresponding namespaces. Confirm that the Applications report Synced and Healthy.

## Lab 1.5 — Change inference providers

Copy `config.env.example` to `config.env` if needed, set `MODEL_PROVIDER=stub`, and rerun bootstrap. This removes the vLLM application and uses predictable responses. Check the active model with `scripts/lab.sh model`. The default vLLM provider serves Qwen2.5-1.5B-Instruct on CPU and adds roughly 7 GiB of memory use. Anthropic needs `MODEL_API_KEY`.

## Lab 1.6 — Pause or rebuild

| Action | Command or operation | State retained |
|---|---|---|
| Pause | Stop Docker Desktop | Cluster and local data |
| Recreate the cluster | `make teardown && make bootstrap` | CA, OpenBao material, downloaded model, and configuration |
| Reset local state too | `scripts/teardown.sh --all && make bootstrap` | `config.env` |
| Run a single step | `make step S=gitea` | Existing state the step still needs |

If the reset generates a new CA, reload shell trust and reimport the certificate for your browser.

## Publish a GitOps change

Commit the desired manifest or values change and run `./bootstrap.sh --only gitea`. The step publishes local HEAD to the in-cluster repository and refreshes Argo CD. Module 2 exercises this workflow.

Before moving on, explain why bootstrap can rerun, which dependencies precede Argo, how the two teardown modes differ, and where to diagnose a Harbor failure. See the [bootstrap decision](../adr/002-bootstrap-gitops-boundary.md) and [operating guide](../operating.md).
