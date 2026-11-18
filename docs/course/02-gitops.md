# Module 2 — Reconcile the cluster from Git

Git records which platform settings and agent policies should be live. Argo CD continuously compares that declared state with the cluster. A sync applies the desired state, self-healing corrects drift, and pruning removes objects deleted from Git. Commits give reviewers an audit trail and a way to revert changes.

## Sources and ordering

`argocd/root` is a chart that renders one Application per component. Each Application points at a Helm chart, Git manifests, or both. The layer templates set sync waves so that CRDs appear before their controllers and dependencies appear before consumers. Upstream chart values live under `values/`, environment overlays under `envs/<ENV>/values/`, and local charts under `manifests/`. Bootstrap passes the domain, selected model, and CA to the root Application at installation.

Local HEAD is mirrored into Gitea unless `REPO_URL` points to another repository. Harbor serves the charts that Argo installs and proxies the upstream container registries. `versions.yaml` fixes the artifact versions for both bootstrap and Argo.

## Lab 2.1 — Inspect an Application

Sign into the Argo CD UI as admin. Find `root` and its children. Inspect the kagent Application's chart and manifest sources. Compare the sync-wave annotations for Keycloak and kagent.

```bash
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status --sort-by=.metadata.annotations.argocd\.argoproj\.io/sync-wave
```

## Lab 2.2 — Observe self-healing

```bash
kubectl -n agent-router scale deploy/model-stub --replicas=0
kubectl -n agent-router get deploy model-stub -w
```

The watch should show Argo restoring the replica count. Stop the watch with Ctrl-C.

## Lab 2.3 — Deploy from a commit

Find the `HELP` text in `manifests/agent-router/files/model-stub.py` and change its wording. Commit the edited file and publish the commit.

```bash
git add manifests/agent-router/files/model-stub.py
git commit -m 'Update the stub help text'
./bootstrap.sh --only gitea
kubectl -n agent-router rollout status deploy/model-stub
```

The Deployment hashes the script so Argo rolls out a new pod. Check the response with `scripts/lab.sh ask mcp-agent-stub - "hello"`. Use `git revert HEAD` and publish the revert to undo the exercise.

## Lab 2.4 — Inspect a registry mirror

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u | head
docker exec kubeconsandbox-control-plane cat /etc/containerd/certs.d/docker.io/hosts.toml
```

Container image names reference their upstream registries. The node's configuration sends those pulls through Harbor. In the Harbor Projects view, distinguish proxy caches from `charts` and `models`. Run `make verify LAYER=0` to check registry coverage.

## Lab 2.5 — Read the version manifest

Pick a version pin in `versions.yaml` and follow it into the relevant Application or install step. Explain how the pin helps reproduce a rebuild and interpret a security audit. Describe the effect of a Harbor outage versus an upstream registry outage, and why the CRD sync waves come early.

See [bootstrap ownership](../adr/002-bootstrap-gitops-boundary.md), [Gitea](../adr/004-gitea-argo-git-endpoint.md), [CRD ownership](../adr/008-gateway-api-crds-owned-by-argo.md), [install parameters](../adr/009-install-parameters-via-root-app.md), and [artifact storage](../adr/012-harbor-mirror-and-model-store.md).
