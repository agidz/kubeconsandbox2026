# Command reference

| Task | Command |
|---|---|
| Deploy or recover | `make bootstrap` |
| Identify a failed step | `make steps` and `.state/logs/` |
| Retry a step | `make step S=gitea` |
| Resume a sequence | `make resume S=harbor` |
| Verify one layer or the whole platform | `make verify LAYER=4` or `make verify` |
| Make pinned binaries available | `export PATH="$PWD/bin:$PATH"` |
| Load shell trust | `eval "$(scripts/ca-env.sh)"` |
| Find URLs and demo credentials | `scripts/lab.sh urls` |
| Deploy the committed revision | `./bootstrap.sh --only gitea` |
| Inspect the model | `scripts/lab.sh model` |
| Recreate the cluster with existing local state | `make teardown && make bootstrap` |
| Recreate with new local state | `scripts/teardown.sh --all && make bootstrap` |

Stopping Docker Desktop pauses the cluster. To change inference, edit `MODEL_PROVIDER` in `config.env`, along with any model or replica settings, and rerun bootstrap.

## Lab helper

Run each command with `scripts/lab.sh`. The demo accounts are admin, alice (administrator persona), and bob (viewer persona).

| Arguments | Operation |
|---|---|
| `token USER [inspector\|portal\|kagent]` | Obtain a user access token |
| `claims TOKEN` | Decode token claims |
| `mcp USER TOOL [MESSAGE]` | Call a tool with a user's credential |
| `delegate USER` | Exchange a consented token as the agent |
| `agent-mcp USER TOOL` | Invoke a tool on behalf of a user |
| `ask AGENT USER_OR_DASH TEXT` | Send a message to `hello-substrate`, `mcp-agent`, or `mcp-agent-stub` |
| `role USER ROLE grant\|revoke` | Change a Keycloak realm role |
| `svid [NAMESPACE]` | Request a JWT-SVID from a temporary pod |
| `actors` | List Substrate sessions |

## Locate components

| Layer | Namespaces |
|---|---|
| Bootstrap | `argocd`, `gitea`, `harbor`, `openbao` |
| Platform | `envoy-gateway-system`, `cert-manager`, `external-secrets`, `cnpg-system`, `monitoring` |
| Identity | `keycloak`, `spire-server`, `spire-system` |
| Agents | `envoy-ai-gateway-system`, `agent-router`, `ate-system`, `kagent` |
| Delegation | `mcp` |
| Local inference | `models` |

Use `argocd/root/` for application composition, `manifests/` and `values/` for deployment inputs, `envs/` for provider settings, and `versions.yaml` for pins.

## Diagnose common failures

| Problem | Check |
|---|---|
| Certificate warning in browser | Import the current `.state/ca/sandbox-root-ca.crt`. A full reset generates a new CA. |
| curl error 60 | Evaluate the output of `scripts/ca-env.sh`. |
| Wrong context | Use the pinned kubectl and select `kind-kubeconsandbox` or the context for your configured name. |
| App does not sync | Check Argo's sync status. A failed commit may need a new push or a manual sync. |
| Verification just after a change | Wait for convergence and retry. |
| No tool calls in an answer | Ask explicitly or use `mcp-agent-stub`. |
| Local pod is OOMKilled | Check the [model sizing guide](../model-sizing.md) and pick a smaller model. |
| No kind cluster after a Docker reset | Rebuild. Use `--all` only if you also want new local state. |
| kagent port 8083 is occupied | Avoid simultaneous CLI port-forwards or use `scripts/lab.sh ask`. |

See the [operating guide](../operating.md) for deployment and debugging details.
