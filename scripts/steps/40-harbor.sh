#!/usr/bin/env bash
# STEP: harbor
# DESCRIPTION: Provision the registry, its pull credentials, and node-level mirrors
# REQUIRES: cluster ca openbao
# PROVIDES: https://harbor.${BASE_DOMAIN} (in cluster), proxy caches, projects charts/models, robot creds in OpenBao
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Why Harbor (plan C5, ADR-012): every chart and image comes through one registry we control. Argo CD pulls charts from
# Harbor's `charts` project; the node pulls images through Harbor's proxy caches, falling back to upstream if needed.
CHART_REPO="$(ver .charts.harbor.repo)"; CHART_VERSION="$(ver .charts.harbor.version)"
VALUES="$ROOT/values/harbor/values.yaml"
SANS="DNS:$HARBOR_HOST,DNS:harbor.harbor.svc,DNS:harbor.harbor.svc.cluster.local,IP:$HARBOR_CLUSTER_IP"
ROBOT_PATH=platform/harbor-robots/argocd
MODELS_ROBOT_PATH=platform/harbor-robots/models

release_ok() {
  local chart
  chart=$(hlm -n "$HARBOR_NS" list --filter '^harbor$' -o json 2>/dev/null |
    jq -r '.[0].chart // ""') || return
  [[ "$chart" == "harbor-$CHART_VERSION" ]]
}

config_ok() {
  local upstream project adapter endpoint
  while read -r upstream project adapter endpoint; do
    hb_project_exists "$project" || return
  done < <(registry_mirrors)
  hb_project_exists charts && hb_project_exists models || return
  local credential
  for credential in "$ROBOT_PATH" "$MODELS_ROBOT_PATH"; do
    [[ -n "$(bao_kv_get "$credential" password)" ]] || return 1
  done
}

check() {
  release_ok && node_mirrors_ok && bao_connect || return
  bao_exists secret/data/platform/harbor-internal && hb_connect && config_ok
}

# Harbor's component-to-component secrets: generated once into OpenBao, then written as the Secrets the values name.
internal_secrets() {
  local tmp; tmp="$(mktemp -d)"
  if ! bao_exists secret/data/platform/harbor-internal; then
    # Harbor's token service only reads PKCS#1 ("BEGIN RSA PRIVATE KEY"); OpenSSL 3 writes PKCS#8 by default.
    openssl genrsa -traditional -out "$tmp/token.key" 4096 2>/dev/null
    openssl req -x509 -new -key "$tmp/token.key" -days 3650 -subj "/CN=harbor-token-service" -out "$tmp/token.crt" 2>/dev/null
    local rp; rp="$(openssl rand -hex 16)"
    jq -n --arg core "$(openssl rand -hex 8)" --arg csrf "$(openssl rand -hex 16)" --arg js "$(openssl rand -hex 8)" \
      --arg reg "$(openssl rand -hex 8)" --arg rp "$rp" \
      --arg htp "harbor_registry_user:$(printf %s "$rp" | python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt(10)).decode(), end="")')" \
      --rawfile tk "$tmp/token.key" --rawfile tc "$tmp/token.crt" \
      '{coreSecret: $core, csrfKey: $csrf, jobserviceSecret: $js, registryHttpSecret: $reg,
        registryPassword: $rp, registryHtpasswd: $htp, tokenKey: $tk, tokenCert: $tc}' |
      bao_kv_put_if_absent platform/harbor-internal
  fi
  rm -rf "$tmp"
  local f; f() { printf %s "$(bao_kv_get platform/harbor-internal "$1")"; }
  apply_secret "$HARBOR_NS" harbor-core-internal generic --from-file=secret=<(f coreSecret) --from-file=CSRF_KEY=<(f csrfKey)
  apply_secret "$HARBOR_NS" harbor-core-token generic --from-file=tls.key=<(f tokenKey) --from-file=tls.crt=<(f tokenCert)
  apply_secret "$HARBOR_NS" harbor-jobservice-internal generic --from-file=JOBSERVICE_SECRET=<(f jobserviceSecret)
  apply_secret "$HARBOR_NS" harbor-registry-internal generic --from-file=REGISTRY_HTTP_SECRET=<(f registryHttpSecret)
  apply_secret "$HARBOR_NS" harbor-registry-credentials generic --from-file=REGISTRY_PASSWD=<(f registryPassword) \
    --from-file=REGISTRY_HTPASSWD=<(f registryHtpasswd)
}

install() {
  ensure_ns "$HARBOR_NS"
  bao_connect
  # Harbor's encryption key for stored registry credentials (exactly 16 chars), generated once into OpenBao.
  jq -n --arg k "$(openssl rand -hex 8)" '{secretKey: $k}' | bao_kv_put_if_absent platform/harbor-core
  # Tier 3 (ADR-015): the chart only reads a Secret. Values flow OpenBao → Secret through pipes, never argv.
  apply_secret "$HARBOR_NS" harbor-secrets generic \
    --from-file=HARBOR_ADMIN_PASSWORD=<(printf %s "$(bao_kv_get platform/harbor adminPassword)") \
    --from-file=secretKey=<(printf %s "$(bao_kv_get platform/harbor-core secretKey)")
  internal_secrets
  ca_issue harbor 825 "$SANS"
  apply_secret "$HARBOR_NS" harbor-tls generic --from-file=tls.crt="$CA_DIR/issued/harbor.crt" \
    --from-file=tls.key="$CA_DIR/issued/harbor.key" --from-file=ca.crt="$CA_CRT"
  log "installing Harbor chart $CHART_VERSION (first install pulls ~1.5 GB of images; a few minutes)"
  helm_upsert harbor "$HARBOR_NS" harbor "$CHART_VERSION" --repo "$CHART_REPO" -f "$VALUES" \
    -f "$ENV_DIR/values/harbor.yaml" --set externalURL="https://$HARBOR_HOST"
}

configure() {
  hb_connect
  local reg project adapter url
  while read -r reg project adapter url; do hb_proxy_project "$project" "$adapter" "$url"; done < <(registry_mirrors)
  hb_private_project charts   # mirrored Helm charts (45-mirror-charts), pulled by Argo CD
  hb_private_project models   # model weights as OCI artifacts (L5)
  hb_robot argocd-pull charts "$ROBOT_PATH"
  hb_robot models-pull models "$MODELS_ROBOT_PATH"   # vLLM's image volume (L5): pull secret via ESO
  # Last, so the node only switches to Harbor once Harbor is configured (until then it pulls upstream).
  node_mirrors_apply
}

apply() {
  install
  [[ "$DRY_RUN" == 1 ]] && { log "dry-run: would configure Harbor projects, robot and node mirrors"; return 0; }
  configure
}

verify() {
  bao_connect && hb_connect || return 1
  ok "Harbor $(hb_api GET /systeminfo | jq -r .harbor_version) at https://$HARBOR_HOST (ClusterIP $HARBOR_CLUSTER_IP)"
  [[ "$(hb_api GET /health | jq -r .status)" == healthy ]] || { warn "Harbor reports unhealthy components"; return 1; }
  config_ok || { warn "Harbor projects or robot credentials missing"; return 1; }
  ok "projects: $(hb_api GET '/projects?page_size=50' | jq -r '[.[].name] | sort | join(" ")')"
  node_mirrors_ok || { warn "node mirror config missing"; return 1; }
  ok "node pulls go through Harbor for: $(registry_mirrors | awk '{print $1}' | tr '\n' ' ')"
}

run_step check apply verify
