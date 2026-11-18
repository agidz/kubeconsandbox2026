#!/usr/bin/env bash
# STEP: gitea
# DESCRIPTION: Create the in-cluster Git mirror and sync the local Git revision
# REQUIRES: openbao harbor
# PROVIDES: http://gitea-http.gitea.svc:3000/sandbox/kubeconsandbox.git, read-only Argo CD credentials in OpenBao
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Why (ADR-004): Argo CD needs a Git URL. Gitea exists only for that, so the sandbox works offline from GitHub; set
# REPO_URL to use a remote repo instead and this step does nothing.
CHART_REPO="$(ver .charts.gitea.repo)"; CHART_VERSION="$(ver .charts.gitea.version)"
VALUES="$ROOT/values/gitea/values.yaml"
release_ok() { [[ "$(hlm -n "$GITEA_NS" list -f '^gitea$' -o json 2>/dev/null | jq -r '.[0].chart // ""')" == "gitea-$CHART_VERSION" ]]; }
check() {
  [[ -n "$REPO_URL" ]] && return 0
  release_ok && bao_connect && gt_connect && synced && [[ -n "$(bao_kv_get platform/gitea-argocd password)" ]]
}

install() {
  ensure_ns "$GITEA_NS"; bao_connect
  apply_secret "$GITEA_NS" gitea-admin generic --from-literal=username="$ADMIN" \
    --from-file=password=<(printf %s "$(bao_kv_get platform/gitea adminPassword)")
  # The sandbox CA for Gitea's calls to Keycloak (SSO is added later by 70-sso; Gitea runs before ESO exists).
  apply_secret "$GITEA_NS" sandbox-ca generic --from-file=ca.crt="$CA_CRT"
  local rendered; rendered="$(mktemp)"; rendered_app_values gitea "$rendered"   # the same values Argo CD applies
  helm_upsert gitea "$GITEA_NS" gitea "$CHART_VERSION" --repo "$CHART_REPO" -f "$VALUES" -f "$rendered"
  rm -f "$rendered"
  # A changed value replaces the pod (Recreate), which breaks port-forwards opened before: wait, then reconnect.
  [[ "$DRY_RUN" == 1 ]] && return 0
  wait_rollout "$GITEA_NS" deploy/gitea 300s >/dev/null
  _kcs_pf_stop; _gt_connected=0; _bao_connected=0
  bao_connect >/dev/null
}

configure() {
  gt_connect
  gt_admin GET "/orgs/$ORG" >/dev/null 2>&1 || echo "{\"username\":\"$ORG\",\"visibility\":\"private\"}" | gt_admin POST /orgs >/dev/null
  gt_admin GET "/repos/$ORG/$REPO" >/dev/null 2>&1 ||
    echo "{\"name\":\"$REPO\",\"private\":true,\"default_branch\":\"main\"}" | gt_admin POST "/orgs/$ORG/repos" >/dev/null
  ok "repo $ORG/$REPO"
  # Least privilege for Argo CD: its own user with read access to this one repo, and a read-only token.
  jq -n --arg p "$(gen_password)" '{adminPassword: $p}' | bao_kv_put_if_absent platform/gitea-argocd-user
  gt_admin GET "/users/$BOT" >/dev/null 2>&1 || jq -n --arg u "$BOT" --rawfile p <(printf %s "$(bao_kv_get platform/gitea-argocd-user adminPassword)") \
    '{username: $u, email: "argocd@localtest.me", password: $p, must_change_password: false}' | gt_admin POST /admin/users >/dev/null
  echo '{"permission":"read"}' | gt_admin PUT "/repos/$ORG/$REPO/collaborators/$BOT" >/dev/null
  if [[ -z "$(bao_kv_get platform/gitea-argocd password)" ]]; then
    gt_api "$BOT" platform/gitea-argocd-user DELETE "/users/$BOT/tokens/argocd-read" >/dev/null 2>&1 || true
    echo '{"name":"argocd-read","scopes":["read:repository"]}' | gt_api "$BOT" platform/gitea-argocd-user POST "/users/$BOT/tokens" |
      jq --arg u "$BOT" '{data: {username: $u, password: .sha1}}' | bao_api POST secret/data/platform/gitea-argocd >/dev/null
  fi
  ok "Argo CD user '$BOT': read on $ORG/$REPO, token in OpenBao secret/platform/gitea-argocd"
  push
}

push() {
  local revision pending
  revision=$(git -C "$ROOT" rev-parse --short HEAD) || return
  pending=$(git -C "$ROOT" status --porcelain) || return
  if [[ -n "$pending" ]]; then
    warn 'Gitea receives the committed revision. Commit working-tree edits to deploy them.'
  fi
  run git_auth push --quiet --force "$GT/$ORG/$REPO.git" HEAD:main
  ok "Mirrored $revision to $ORG/$REPO main"

  # The webhook reports the browser URL, while Applications use the Service URL.
  if kc get crd applications.argoproj.io >/dev/null 2>&1; then
    kc -n argocd annotate applications --all argocd.argoproj.io/refresh=normal --overwrite >/dev/null &&
      ok 'Requested an Argo CD refresh'
  fi
}

apply() {
  install
  [[ "$DRY_RUN" == 1 ]] && { log "dry-run: would create org/repo, Argo CD user and push HEAD"; return 0; }
  configure
}

verify() {
  if [[ -n "$REPO_URL" ]]; then ok "remote mode: Argo CD will use $REPO_URL (Gitea not installed)"; return 0; fi
  bao_connect; gt_connect
  ok "Gitea $(curl -sf "$GT/api/v1/version" | jq -r .version)"
  synced && ok "$ORG/$REPO main = local HEAD $(git -C "$ROOT" rev-parse --short HEAD)" || { warn "Gitea is behind local HEAD"; return 1; }
  [[ -n "$(bao_kv_get platform/gitea-argocd password)" ]] || { warn "Argo CD token missing in OpenBao"; return 1; }
}

run_step check apply verify
