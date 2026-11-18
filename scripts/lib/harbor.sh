# shellcheck shell=bash
# Harbor helpers: the API through a short-lived port-forward, admin credentials from OpenBao (never on a command line).
# Sourced by common.sh; don't source directly.

HARBOR_NS=harbor
HARBOR_HOST="harbor.$BASE_DOMAIN"
HB_PORT="${HB_PORT:-18443}"
HB_API="https://$HARBOR_HOST:$HB_PORT/api/v2.0"
_hb_connected=0

# registry_mirrors: "<upstream registry> <Harbor proxy project> <Harbor adapter> <upstream URL>".
# Every registry an image in this platform comes from must be listed, or its pulls bypass Harbor (S2 finding).
# Harbor has no Quay or public-ECR adapter; the generic docker-registry adapter proxies them.
# Not listed: docker.gitea.com. Its image name is a single segment (docker.gitea.com/gitea), which Harbor's token
# service can't parse ("unable to parse image from string"), so pulls fall back to upstream. Gitea is taken from
# docker.io/gitea/gitea instead (values/gitea). Avoid single-segment image names from non-Docker-Hub registries.
registry_mirrors() {
  cat <<'EOF'
docker.io           dockerhub    docker-hub       https://hub.docker.com
ghcr.io             ghcr         github-ghcr      https://ghcr.io
quay.io             quay         docker-registry  https://quay.io
registry.k8s.io     k8s          docker-registry  https://registry.k8s.io
ecr-public.aws.com  ecr-public   docker-registry  https://ecr-public.aws.com
cgr.dev             cgr          docker-registry  https://cgr.dev
EOF
}

hb_connect() {
  if ((_hb_connected)); then return 0; fi
  port_forward "$HARBOR_NS" harbor "$HB_PORT" 443
  wait_for "Harbor API on port $HB_PORT" 60 hb_api GET /health || return
  _hb_connected=1
}

hb_api() {
  local method=$1 endpoint=$2
  local payload=()
  case "$method" in
    GET|DELETE) ;;
    *) payload=(--header 'Content-Type: application/json' --data-binary @-) ;;
  esac
  curl -sS --fail-with-body --cacert "$CA_CRT" \
    --resolve "$HARBOR_HOST:$HB_PORT:127.0.0.1" --request "$method" "${payload[@]}" \
    --netrc-file <(printf 'machine %s login admin password %s\n' "$HARBOR_HOST" \
      "$(bao_kv_get platform/harbor adminPassword)") "$HB_API$endpoint"
}

hb_project_exists() {
  hb_api GET "/projects?name=$1" | jq -e --arg project "$1" 'any(.[]?; .name == $project)' >/dev/null
}

hb_registry_id() {
  hb_api GET "/registries?name=$1" | jq -r --arg registry "$1" '.[]? | select(.name == $registry) | .id'
}

# hb_proxy_project <project> <adapter> <url>: registry endpoint + public proxy-cache project, both idempotent.
hb_proxy_project() {
  local name=$1 type=$2 url=$3 id
  id="$(hb_registry_id "$name")"
  if [[ -z "$id" ]]; then
    jq -n --arg n "$name" --arg t "$type" --arg u "$url" '{name: $n, type: $t, url: $u, insecure: false}' |
      hb_api POST /registries >/dev/null
    id="$(hb_registry_id "$name")"
  fi
  hb_project_exists "$name" || jq -n --arg n "$name" --argjson id "$id" \
    '{project_name: $n, registry_id: $id, metadata: {public: "true"}}' | hb_api POST /projects >/dev/null
  echo "{\"id\":$id}" | hb_api POST /registries/ping >/dev/null && ok "proxy cache $name → $url (reachable)"
}

hb_private_project() {
  hb_project_exists "$1" || jq -n --arg n "$1" '{project_name: $n, metadata: {public: "false"}}' | hb_api POST /projects >/dev/null
  ok "project $1 (private)"
}

# hb_robot <name> <project> <OpenBao path>: system robot with pull on <project>; its secret is only shown at creation,
# so the credentials live in OpenBao and the robot is re-created if they're missing there.
hb_robot() {
  local name=$1 project=$2 path=$3 id
  id="$(hb_api GET "/robots?q=name%3D$name" | jq -r '.[0].id // empty')"
  if [[ -n "$id" && -n "$(bao_kv_get "$path" password)" ]]; then ok "robot \$$name exists"; return 0; fi
  [[ -n "$id" ]] && hb_api DELETE "/robots/$id" >/dev/null
  jq -n --arg n "$name" --arg p "$project" '{name: $n, duration: -1, level: "system", disable: false,
      permissions: [{kind: "project", namespace: $p, access: [{resource: "repository", action: "pull"},
                                                             {resource: "artifact", action: "read"}]}]}' |
    hb_api POST /robots | jq '{data: {username: .name, password: .secret}}' | bao_api POST "secret/data/$path" >/dev/null
  ok "robot \$$name created, credentials in OpenBao secret/$path"
}
