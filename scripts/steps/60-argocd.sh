#!/usr/bin/env bash
# STEP: argocd
# DESCRIPTION: Install Argo CD and hand reconciliation over to the root Application
# REQUIRES: harbor mirror-charts gitea
# PROVIDES: Argo CD in namespace argocd, Application "root" rendering every layer's Applications from Git
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Why (ADR-002): this is the hand-over point. After this step Argo CD reconciles everything from Git; bootstrap only
# writes what can't live in Git: credentials (from OpenBao), the per-install CA, and the root Application's parameters.
CHART_REPO="$(ver .charts.argo-cd.repo)"; CHART_VERSION="$(ver .charts.argo-cd.version)"
NS=argocd
GIT_URL="$ARGO_GIT_URL"
CHART_REGISTRY="$HARBOR_HOST/charts"

release_ok() {
  local installed
  installed=$(hlm -n "$NS" list --filter '^argocd$' -o json 2>/dev/null |
    jq -r '.[0].chart // ""') || return
  [[ "$installed" == "argo-cd-$CHART_VERSION" ]]
}

app_status() {
  kc -n "$NS" get application "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null
}

root_ok() {
  [[ "$(app_status root)" == Synced/Healthy ]] || return 1
  local desired deployed
  desired=$(root_values | yq -o=json | jq -cS .) || return
  deployed=$(kc -n "$NS" get application root -o json | jq -cS '.spec.source.helm.valuesObject') || return
  [[ "$desired" == "$deployed" ]]
}

check() {
  release_ok && root_ok && bao_connect && password_ok && webhook_ok
}

# Gitea → Argo CD push webhook, so a push syncs within seconds instead of Argo's ~3 min poll. Gitea's "gogs" hook type
# matches Argo CD's Gogs handler (HMAC with webhook.gogs.secret in argocd-secret).
WEBHOOK_URL="http://argocd-server.$NS.svc/api/webhook"
webhook_ok() {
  [[ -n "$REPO_URL" ]] && return 0
  gt_connect >/dev/null && gt_admin GET "/repos/$ORG/$REPO/hooks" | jq -e --arg u "$WEBHOOK_URL" 'any(.[]; .config.url == $u)' >/dev/null
}
webhook() {
  [[ -n "$REPO_URL" ]] && return 0
  jq -n --arg s "$(openssl rand -hex 20)" '{secret: $s}' | bao_kv_put_if_absent platform/argocd-webhook
  [[ "$DRY_RUN" == 1 ]] && return 0
  kc -n "$NS" patch secret argocd-secret --type merge --patch-file <(jq -n --arg s "$(bao_kv_get platform/argocd-webhook secret)" \
    '{stringData: {"webhook.gogs.secret": $s}}') >/dev/null
  gt_connect
  webhook_ok && { ok "Gitea webhook → $WEBHOOK_URL exists"; return 0; }
  jq -n --arg u "$WEBHOOK_URL" --arg s "$(bao_kv_get platform/argocd-webhook secret)" \
    '{type: "gogs", active: true, events: ["push"], config: {url: $u, content_type: "json", secret: $s}}' |
    gt_admin POST "/repos/$ORG/$REPO/hooks" >/dev/null
  ok "Gitea webhook → $WEBHOOK_URL created"
}

password_ok() { # stored bcrypt hash matches the password in OpenBao
  local hash; hash="$(kc -n "$NS" get secret argocd-secret -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d)"
  [[ -n "$hash" ]] && printf %s "$(bao_kv_get platform/argocd adminPassword)" |
    python3 -c 'import bcrypt,sys; sys.exit(0 if bcrypt.checkpw(sys.stdin.buffer.read(), sys.argv[1].encode()) else 1)' "$hash"
}

credentials() {
  ensure_ns "$NS"; bao_connect
  # argocd-secret: chart has createSecret=false (adoption-safe). Rewrite only when the password changed.
  if ! password_ok; then
    apply_secret "$NS" argocd-secret generic \
      --from-file=admin.password=<(printf %s "$(bao_kv_get platform/argocd adminPassword)" |
        python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt(10)).decode(), end="")') \
      --from-literal=admin.passwordMtime="$(date -u +%FT%TZ)"
    ok "argocd-secret: admin password from OpenBao secret/platform/argocd"
  fi
  # CA trust for Harbor's OCI chart registry (chart has tls.create=false).
  kc -n "$NS" create configmap argocd-tls-certs-cm --from-file="$HARBOR_HOST=$CA_CRT" --dry-run=client -o yaml |
    run kubectl --context "$KUBE_CONTEXT" apply -f - >/dev/null
  # Repository credentials: Git (read-only Gitea user, or a remote repo) and Harbor's charts project (robot).
  if [[ -z "$REPO_URL" ]]; then
    apply_secret "$NS" repo-git generic --from-literal=type=git --from-literal=url="$GIT_URL" \
      --from-literal=username="$(bao_kv_get platform/gitea-argocd username)" \
      --from-file=password=<(printf %s "$(bao_kv_get platform/gitea-argocd password)")
  else
    apply_secret "$NS" repo-git generic --from-literal=type=git --from-literal=url="$GIT_URL" # public remote repo
  fi
  apply_secret "$NS" repo-harbor-charts generic --from-literal=type=helm --from-literal=name=harbor-charts \
    --from-literal=enableOCI=true --from-literal=url="$CHART_REGISTRY" \
    --from-literal=username="$(bao_kv_get platform/harbor-robots/argocd username)" \
    --from-file=password=<(printf %s "$(bao_kv_get platform/harbor-robots/argocd password)")
  [[ "$DRY_RUN" == 1 ]] || kc -n "$NS" label secret repo-git repo-harbor-charts \
    argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
  ok "repositories: $GIT_URL, oci://$CHART_REGISTRY"
  # SSO client secret for Keycloak (oidc.config references $argocd-oidc:clientSecret; the label lets Argo read it).
  apply_secret "$NS" argocd-oidc generic --from-file=clientSecret=<(printf %s "$(bao_kv_get platform/oidc/argocd clientSecret)")
  [[ "$DRY_RUN" == 1 ]] || kc -n "$NS" label secret argocd-oidc app.kubernetes.io/part-of=argocd --overwrite >/dev/null
}

root_app() { # the only rendered object: install inputs live here, not in Git (ADR-009); see lib/argo.sh
  [[ "$DRY_RUN" == 1 ]] && { run kubectl apply "(root Application)"; return 0; }
  jq -n --arg repo "$GIT_URL" --arg rev "$REPO_REVISION" --arg ns "$NS" --argjson vals "$(root_values | yq -o=json)" '{
    apiVersion: "argoproj.io/v1alpha1", kind: "Application", metadata: {name: "root", namespace: $ns},
    spec: {project: "default",
      source: {repoURL: $repo, targetRevision: $rev, path: "argocd/root",
        helm: {valueFiles: ["../../versions.yaml"], valuesObject: $vals}},
      destination: {server: "https://kubernetes.default.svc", namespace: $ns},
      syncPolicy: {automated: {prune: true, selfHeal: true}}}}' | kc apply -f - >/dev/null
}

apply() {
  credentials
  local rendered; rendered="$(mktemp)"; rendered_app_values argocd "$rendered"   # same values Argo CD will use
  helm_upsert argocd "$NS" argo-cd "$CHART_VERSION" --repo "$CHART_REPO" -f "$ROOT/values/argocd/values.yaml" -f "$rendered"
  rm -f "$rendered"
  root_app
  webhook
  [[ "$DRY_RUN" == 1 ]] || wait_for "root Application Synced/Healthy" 180 root_ok
}

verify() {
  release_ok && ok "Argo CD $(kc -n "$NS" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')" ||
    { warn "Argo CD release missing"; return 1; }
  root_ok || { warn "root Application is $(app_status root)"; return 1; }
  ok "root Application Synced/Healthy"
  # Right after a fresh root apply, apps resolve their sources while Harbor/Gitea are being adopted: give transient
  # errors a few minutes to clear (Argo re-resolves on refresh) before calling it a failure.
  wait_for "every app resolves its sources (Harbor + Git)" 300 sources_resolved || {
    kc -n "$NS" get applications -o json | jq -r '.items[] | select(any(.status.conditions[]?; .type == "ComparisonError")) |
      "\(.metadata.name): \([.status.conditions[] | select(.type == "ComparisonError") | .message][0][0:200])"' | while read -r l; do warn "$l"; done
    return 1; }
  local app
  for app in $(kc -n "$NS" get applications -o jsonpath='{.items[*].metadata.name}'); do
    [[ "$app" == root ]] || ok "app $app: $(app_status "$app") (sources resolved from Harbor + Git)"
  done
}
sources_resolved() {   # none has a ComparisonError; ask Argo to re-resolve the ones that do
  local bad app
  bad="$(kc -n "$NS" get applications -o json | jq -r '.items[] | select(any(.status.conditions[]?; .type == "ComparisonError")) | .metadata.name')"
  [[ -z "$bad" ]] && return 0
  for app in $bad; do kc -n "$NS" annotate application "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null; done
  return 1
}

run_step check apply verify
