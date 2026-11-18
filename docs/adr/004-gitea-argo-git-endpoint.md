# ADR-004 — An in-cluster Git endpoint for Argo CD

**Status** Accepted on 2026-11-15, originally decided on 2026-11-14

Argo needs a Git server reachable from the cluster. The default install should work without a hosted Git account. A hosted copy can still be used for distribution.

Bootstrap step `50-gitea` installs the MIT-licensed Gitea chart v12.7.0 in namespace `gitea`. It creates the sandbox repository and Argo's read-only account, keeps the token at `secret/platform/gitea-argocd` in OpenBao, and force-pushes the local HEAD to the internal repository's `main` branch. Argo fetches from `http://gitea-http.gitea.svc:3000/sandbox/kubeconsandbox.git`. Set `REPO_URL` to use a remote repository and skip this step.

Gitea runs as one pod with SQLite and a local queue, using the `Recreate` deployment strategy because both hold locks on the volume. A restart briefly interrupts Git fetches. The Git push webhook uses the public host while Applications use the internal URL, so bootstrap also triggers an Argo refresh after pushing. The `docker.gitea.com` image is compatible with Harbor's mirror configuration. Keycloak login is configured later by `70-sso`.

There is no comparable small Git server under CNCF or the Linux Foundation. Forgejo would also fit, but Gitea was already exercised in the prototype. Hosted Git adds network and account dependencies. OCI charts alone cannot supply the repository's manifests and values.
