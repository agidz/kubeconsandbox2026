# shellcheck shell=bash
GITEA_NS=gitea
ORG=sandbox
REPO=kubeconsandbox
ADMIN=sandbox-admin
BOT=argocd
GT_PORT=${GT_PORT:-13000}
GT="http://127.0.0.1:$GT_PORT"
_gt_connected=0

gt_connect() {
  if ((_gt_connected)); then return 0; fi
  port_forward "$GITEA_NS" gitea-http "$GT_PORT" 3000
  wait_for "Gitea API on port $GT_PORT" 60 curl -sf "$GT/api/v1/version" || return
  _gt_connected=1
}

gt_api() {
  local account=$1 secret=$2 method=$3 endpoint=$4
  local body=()
  case "$method" in
    GET|DELETE) ;;
    *) body=(-H 'Content-Type: application/json' --data-binary @-) ;;
  esac
  curl -sS --fail-with-body --request "$method" "${body[@]}" \
    --netrc-file <(printf 'machine 127.0.0.1 login %s password %s\n' \
      "$account" "$(bao_kv_get "$secret" adminPassword)") \
    "$GT/api/v1$endpoint"
}

gt_admin() {
  gt_api "$ADMIN" platform/gitea "$@"
}

git_auth() {
  local password credentials
  password=$(bao_kv_get platform/gitea adminPassword) || return
  credentials=$(printf '%s:%s' "$ADMIN" "$password" | base64 -w0) || return
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="Authorization: Basic $credentials" git -C "$ROOT" "$@"
}

remote_head() {
  git_auth ls-remote "$GT/$ORG/$REPO.git" refs/heads/main 2>/dev/null | cut -f1
}

synced() {
  local local_revision remote_revision
  local_revision=$(git -C "$ROOT" rev-parse HEAD) || return
  remote_revision=$(remote_head) || return
  [[ "$local_revision" == "$remote_revision" ]]
}
