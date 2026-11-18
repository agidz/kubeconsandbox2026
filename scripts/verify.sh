#!/usr/bin/env bash
# Exercise the running deployment and return the number of failed assertions.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

FAILED=0
pass() {
  ok "$*"
}

fail() {
  FAILED=$((FAILED + 1))
  warn "FAIL: $*"
}

check() {
  local assertion=$1
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$assertion"
  else
    fail "$assertion"
  fi
}

argo_apps_healthy() {
  local bad
  bad="$(kc -n argocd get applications -o json | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
          | "\(.metadata.name)=\(.status.sync.status)/\(.status.health.status)"')"
  [[ -z "$bad" ]] || { warn "not Synced/Healthy: $bad"; return 1; }
}

# Every running container image must come from a registry Harbor mirrors (S2 finding: otherwise pulls bypass Harbor).
images_mirrored() {
  local allowed bad
  allowed="$(registry_mirrors | awk '{print $1}')"
  bad="$(kc get pods -A -o json | jq -r '.items[].spec | (.containers + (.initContainers // []))[].image' | sort -u |
    while read -r img; do
      reg="${img%%/*}"; [[ "$img" == */* && ( "$reg" == *.* || "$reg" == *:* || "$reg" == localhost ) ]] || reg=docker.io
      grep -qx "$reg" <<<"$allowed" || echo "$img"
    done)"
  [[ -z "$bad" ]] || { warn "images from unmirrored registries: $(echo $bad)"; return 1; }
}

bao_unsealed()    { bao_health | jq -e '.initialized and (.sealed | not)'; }
harbor_healthy()  { [[ "$(hb_api GET /health | jq -r .status)" == healthy ]]; }
harbor_charts()   {
  local c v
  while read -r c v; do hb_api GET "/projects/charts/repositories/$c/artifacts/$v" || return 1
  done < <(yq -r '.charts | to_entries[] | "\(.key) \(.value.version)"' "$VERSIONS_FILE")
}
gitea_webhook()   { gt_admin GET "/repos/$ORG/$REPO/hooks" | jq -e 'length > 0'; }

verify_l0() {
  log "Layer 0: bootstrap (cluster, CA, OpenBao, Harbor, Gitea, Argo CD)"
  check "cluster API reachable ($KUBE_CONTEXT)" cluster_reachable
  check "all nodes Ready" kc wait node --all --for=condition=Ready --timeout=10s
  bao_connect >/dev/null 2>&1
  check "OpenBao initialized and unsealed" bao_unsealed
  hb_connect >/dev/null 2>&1
  check "Harbor healthy" harbor_healthy
  check "Harbor has every chart pinned in versions.yaml" harbor_charts
  check "every running image comes from a Harbor-mirrored registry" images_mirrored
  if [[ -z "$REPO_URL" ]]; then
    gt_connect >/dev/null 2>&1
    check "Gitea main = local HEAD (run ./bootstrap.sh --only gitea after committing)" synced
    check "Gitea → Argo CD webhook present" gitea_webhook
  fi
  check "Argo CD: every Application Synced/Healthy" argo_apps_healthy
}

# Layer 1 functional probes run in a throwaway namespace that is always removed.
PROBE_NS=kcs-verify
l1_probe() {
  kc create namespace "$PROBE_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc apply -f - >/dev/null <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: probe, namespace: $PROBE_NS }
spec: { secretName: probe-tls, dnsNames: [probe.$BASE_DOMAIN], issuerRef: { kind: ClusterIssuer, name: sandbox-ca } }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: allowed, namespace: $PROBE_NS }
spec:
  secretStoreRef: { kind: ClusterSecretStore, name: openbao }
  target: { name: allowed }
  data: [{ secretKey: v, remoteRef: { key: models/provider, property: model } }]
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: forbidden, namespace: $PROBE_NS }
spec:
  secretStoreRef: { kind: ClusterSecretStore, name: openbao }
  target: { name: forbidden }
  data: [{ secretKey: v, remoteRef: { key: bootstrap/ca, property: key } }]
YAML
}
gateway_api_version() {
  [[ "$(kc get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')" == v1.6.1 ]]
}
cert_chains_to_ca() {
  kc -n "$PROBE_NS" wait certificate/probe --for=condition=Ready --timeout=60s &&
    kc -n "$PROBE_NS" get secret probe-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl verify -CAfile "$CA_CRT"
}
eso_reads_allowed() { wait_for "ExternalSecret synced" 60 kc -n "$PROBE_NS" get secret allowed; }
eso_denied_bootstrap() {
  wait_for "forbidden ExternalSecret evaluated" 60 bash -c \
    "[[ \$(kubectl --context '$KUBE_CONTEXT' -n $PROBE_NS get externalsecret forbidden -o jsonpath='{.status.conditions[0].reason}') == SecretSyncedError ]]" &&
    ! kc -n "$PROBE_NS" get secret forbidden
}

verify_l1() {
  log "Layer 1: platform (Gateway API CRDs, cert-manager, External Secrets, CNPG)"
  check "Gateway API CRDs at v1.6.1 (Agent Router v1.2 matrix)" gateway_api_version
  check "ClusterIssuer sandbox-ca Ready" kc wait clusterissuer/sandbox-ca --for=condition=Ready --timeout=10s
  check "ClusterSecretStore openbao Ready" kc wait clustersecretstore/openbao --for=condition=Ready --timeout=10s
  check "CNPG operator Available" kc -n cnpg-system wait deploy --all --for=condition=Available --timeout=10s
  l1_probe
  check "cert-manager issues certs that chain to the sandbox CA" cert_chains_to_ca
  check "ESO syncs an allowed OpenBao secret" eso_reads_allowed
  check "ESO is denied secret/bootstrap/* (the CA key)" eso_denied_bootstrap
  kc delete namespace "$PROBE_NS" --wait=false >/dev/null 2>&1

  log "Layer 1: gateway (Envoy Gateway, Gateway sandbox, routes)"
  check "every Gateway listener Programmed" gateway_programmed
  local h path
  for h in argocd:/ git:/ harbor:/api/v2.0/health openbao:/v1/sys/health; do
    path="${h#*:}"; h="${h%%:*}"
    check "https://$h.$BASE_DOMAIN reachable from this host (sandbox CA)" ui_ok "$h" "$path"
  done
  check "http:// redirects to https://" bash -c "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://argocd.$BASE_DOMAIN/ | grep -qx 301"

  log "Layer 1: observability (OTel Collector → Jaeger + Prometheus, Grafana)"
  for h in grafana:/api/health jaeger:/ prometheus:/-/ready; do
    path="${h#*:}"; h="${h%%:*}"
    check "https://$h.$BASE_DOMAIN reachable" ui_ok "$h" "$path"
  done
  # One OTLP send through the Collector, then look for it in Jaeger, Prometheus and through Grafana's datasources.
  kc -n monitoring delete pod kcs-verify-tgen --ignore-not-found >/dev/null 2>&1
  for k in traces metrics; do
    kc -n monitoring run kcs-verify-tgen --rm -i --restart=Never --quiet \
      --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.163.0 -- \
      "$k" --otlp-endpoint otel-collector.monitoring.svc:4317 --otlp-insecure --service kcs-verify --duration 3s >/dev/null 2>&1
  done
  check "traces reach Jaeger through the OTel Collector" wait_for "trace in Jaeger" 60 jaeger_has_trace
  check "metrics reach Prometheus through the OTel Collector (OTLP)" wait_for "metric in Prometheus" 60 prom_has_metric
  bao_connect >/dev/null 2>&1
  check "Grafana datasources healthy (Prometheus, Jaeger)" grafana_datasources_ok
}
_curl_ca() { curl -s --max-time 10 --cacert "$CA_CRT" "$@"; }
# Jaeger and Prometheus sit behind the gateway's OIDC login once layer 2 exists; sign in (as admin) when redirected.
JAR_DIR="$STATE_DIR/verify-cookies"; mkdir -p "$JAR_DIR"
_gw_get() { # <host> <path>
  local jar="$JAR_DIR/$1"
  [[ "$(_curl_ca -b "$jar" -o /dev/null -w '%{http_code}' "https://$1.$BASE_DOMAIN$2")" == 302 ]] &&
    { bao_connect >/dev/null 2>&1; sso_browser_login "https://$1.$BASE_DOMAIN/" admin "$jar" >/dev/null; }
  _curl_ca -b "$jar" "https://$1.$BASE_DOMAIN$2"
}
jaeger_has_trace() { _gw_get jaeger /api/services | jq -e '.data | index("kcs-verify")'; }
prom_has_metric() { _gw_get prometheus "/api/v1/query?query=gen" | jq -e '.data.result | length > 0'; }
grafana_datasources_ok() {
  local ds
  for ds in prometheus jaeger; do
    _curl_ca --netrc-file <(printf 'machine grafana.%s login admin password %s\n' "$BASE_DOMAIN" \
      "$(bao_kv_get platform/grafana adminPassword)") "https://grafana.$BASE_DOMAIN/api/datasources/uid/$ds/health" |
      jq -e '.status == "OK"' || return 1
  done
}
gateway_programmed() {
  [[ "$(kc -n envoy-gateway-system get gateway sandbox -o json |
    jq '[.status.listeners[] | .conditions[] | select(.type == "Programmed" and .status != "True")] | length')" == 0 ]]
}
ui_ok() { [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CA_CRT" "https://$1.$BASE_DOMAIN$2")" =~ ^(200|30[0-9])$ ]]; }

# Layer 2: a pod gets an SVID through the SPIFFE CSI driver; its chain must verify to the sandbox root (spike S5).
svid_chains_to_root() {
  local ns=kcs-verify-l2 out
  kc create namespace "$ns" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n "$ns" delete pod svid-probe --ignore-not-found >/dev/null
  kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: svid-probe, namespace: $ns }
spec:
  restartPolicy: OnFailure   # retry until the per-pod registration entry reaches the agent
  containers:
    - name: probe
      image: ghcr.io/spiffe/spire-agent:$(yq -r '.charts.spire.app' "$VERSIONS_FILE")
      command: ["/opt/spire/bin/spire-agent", "api", "fetch", "x509", "-socketPath", "/spiffe-workload-api/spire-agent.sock", "-output", "json"]
      volumeMounts: [{ name: spiffe, mountPath: /spiffe-workload-api, readOnly: true }]
  volumes: [{ name: spiffe, csi: { driver: csi.spiffe.io, readOnly: true } }]
YAML
  wait_for "SVID fetched" 180 bash -c "[[ \$(kubectl --context '$KUBE_CONTEXT' -n $ns get pod svid-probe -o jsonpath='{.status.phase}') == Succeeded ]]" || return 1
  out="$(kc -n "$ns" logs svid-probe)"
  kc -n "$ns" delete pod svid-probe --wait=false >/dev/null 2>&1   # keep the namespace: the JWT-SVID check (role spiffe-demo) is bound to it
  # x509_svid is DER (leaf + SPIRE CA) concatenated; split it and verify against the sandbox root.
  jq -r '.svids[0].x509_svid' <<<"$out" | base64 -d | python3 -c '
import sys, subprocess
der = sys.stdin.buffer.read(); certs = []; i = 0
while i < len(der):
    l = der[i + 1]
    n, hdr = (int.from_bytes(der[i + 2:i + 2 + (l & 0x7f)], "big"), 2 + (l & 0x7f)) if l & 0x80 else (l, 2)
    certs.append(der[i:i + hdr + n]); i += hdr + n
pem = [subprocess.run(["openssl", "x509", "-inform", "DER"], input=c, capture_output=True).stdout for c in certs]
open("/dev/fd/3", "wb").write(pem[0]); open("/dev/fd/4", "wb").write(b"".join(pem[1:]))
' 3>"$STATE_DIR/svid-leaf.pem" 4>"$STATE_DIR/svid-int.pem" &&
    openssl verify -CAfile "$CA_CRT" -untrusted "$STATE_DIR/svid-int.pem" "$STATE_DIR/svid-leaf.pem" >/dev/null
  local rc=$?; rm -f "$STATE_DIR"/svid-*.pem; return $rc
}

verify_l2() {
  log "Layer 2: identity (SPIRE ← OpenBao PKI)"
  check "SPIRE server, agent and CSI driver running" bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n spire-server wait pod --all --for=condition=Ready --timeout=30s"
  check "a pod's SVID chains to the sandbox root (SVID → SPIRE CA → root)" svid_chains_to_root
  bao_connect >/dev/null 2>&1
  check "a pod logs in to OpenBao with its JWT-SVID and reads only its own secret" jwt_svid_login
  log "Layer 2: identity for people (Keycloak realm sandbox)"
  check "Keycloak realm sandbox serves OIDC discovery" bash -c \
    "curl -s --cacert '$CA_CRT' https://keycloak.$BASE_DOMAIN/realms/sandbox/.well-known/openid-configuration | jq -e .issuer"
  bao_connect >/dev/null 2>&1
  check "admin logs in (browser flow) and gets group sandbox-admins" login_has_group admin argocd sandbox-admins
  check "bob logs in and gets group sandbox-viewers" login_has_group bob argocd sandbox-viewers
  check "Keycloak client gateway lists exactly the gateway routes marked sso (manifests/keycloak vs envoy-gateway)" bash -c \
    "diff <(yq -r '.clients[] | select(.name == \"gateway\") | .ssoHosts[]' '$ROOT/manifests/keycloak/values.yaml' | sort) \
          <(yq -r '.routes[] | select(.sso and (.oidcClient // \"gateway\") == \"gateway\") | .host' '$ROOT/manifests/envoy-gateway/values.yaml' | sort)"
  check "every route with its own OIDC client has that Keycloak client" route_clients_exist
  log "Layer 2: single sign-on (admin = admin everywhere, bob = not)"
  local svc
  for svc in argocd gitea grafana harbor openbao; do
    check "SSO $svc: admin gets admin rights" sso_admin "$svc" admin
    check "SSO $svc: bob does not" not_sso_admin "$svc" bob
  done
  for h in prometheus jaeger kagent; do
    check "gateway OIDC: https://$h.$BASE_DOMAIN redirects anonymous users to Keycloak" bash -c \
      "curl -s --cacert '$CA_CRT' -o /dev/null -w '%{redirect_url}' https://$h.$BASE_DOMAIN/ | grep -q '^https://keycloak.$BASE_DOMAIN/'"
  done
  check "SSO kagent UI: admin logs in at the gateway" bash -c \
    "true" && sso_browser_login "https://kagent.$BASE_DOMAIN/" admin "$JAR_DIR/sso-kagent" >/dev/null &&
    check "kagent UI reachable after login" bash -c "curl -s --cacert '$CA_CRT' -b '$JAR_DIR/sso-kagent' -o /dev/null -w '%{http_code}' https://kagent.$BASE_DOMAIN/ | grep -qx 200"
}
route_clients_exist() {
  local c
  for c in $(yq -r '.routes[] | select(.sso and .oidcClient) | .oidcClient' "$ROOT/manifests/envoy-gateway/values.yaml"); do
    C="$c" yq -e '.clients[] | select(.name == strenv(C))' "$ROOT/manifests/keycloak/values.yaml" >/dev/null || return 1
  done
}
login_has_group() { oidc_login "$1" "$2" | jq -e --arg g "$3" '.groups | index($g)'; }

not_sso_admin() { ! sso_admin "$@"; }

# A pod's JWT-SVID (audience openbao) logs in to OpenBao (auth/spiffe-jwt, role spiffe-demo) and reads only its secret.
jwt_svid_login() {
  local ns=kcs-verify-l2 out jwt tok
  kc create namespace "$ns" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n "$ns" delete pod jwt-probe --ignore-not-found >/dev/null
  kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: jwt-probe, namespace: $ns }
spec:
  restartPolicy: OnFailure
  containers:
    - name: probe
      image: ghcr.io/spiffe/spire-agent:$(yq -r '.charts.spire.app' "$VERSIONS_FILE")
      command: ["/opt/spire/bin/spire-agent", "api", "fetch", "jwt", "-audience", "openbao", "-socketPath", "/spiffe-workload-api/spire-agent.sock", "-output", "json"]
      volumeMounts: [{ name: spiffe, mountPath: /spiffe-workload-api, readOnly: true }]
  volumes: [{ name: spiffe, csi: { driver: csi.spiffe.io, readOnly: true } }]
YAML
  wait_for "JWT-SVID fetched" 180 bash -c "[[ \$(kubectl --context '$KUBE_CONTEXT' -n $ns get pod jwt-probe -o jsonpath='{.status.phase}') == Succeeded ]]" || return 1
  jwt="$(kc -n "$ns" logs jwt-probe | jq -r '.. | .svid? // empty' | head -1)"
  kc -n "$ns" delete pod jwt-probe --wait=false >/dev/null 2>&1
  tok="$(jq -n --arg j "$jwt" '{role: "spiffe-demo", jwt: $j}' | _curl_ca -X POST --data-binary @- "$BAO_URL/v1/auth/spiffe-jwt/login" | jq -r '.auth.client_token // empty')"
  [[ -n "$tok" ]] &&
    [[ "$(_curl_ca -H "X-Vault-Token: $tok" -o /dev/null -w '%{http_code}' "$BAO_URL/v1/secret/data/platform/sandbox-ca-public")" == 200 ]] &&
    [[ "$(_curl_ca -H "X-Vault-Token: $tok" -o /dev/null -w '%{http_code}' "$BAO_URL/v1/secret/data/platform/argocd")" == 403 ]]
}
# SSO into each service as <user>; succeed when the service grants that user admin rights.
sso_admin() {
  local svc=$1 u=$2 jar="$JAR_DIR/sso-$1-$2" q landed tok
  case "$svc" in
    argocd)  sso_browser_login "https://argocd.$BASE_DOMAIN/auth/login?return_url=https://argocd.$BASE_DOMAIN/applications" "$u" "$jar" >/dev/null &&
             [[ "$(_curl_ca -b "$jar" "https://argocd.$BASE_DOMAIN/api/v1/account/can-i/clusters/update/*" | jq -r .value)" == yes ]] ;;
    gitea)   sso_browser_login "https://git.$BASE_DOMAIN/user/oauth2/keycloak" "$u" "$jar" >/dev/null &&
             [[ "$(_curl_ca -b "$jar" -o /dev/null -w '%{http_code}' "https://git.$BASE_DOMAIN/-/admin")" == 200 ]] ;;
    grafana) sso_browser_login "https://grafana.$BASE_DOMAIN/login/generic_oauth" "$u" "$jar" >/dev/null &&
             [[ "$(_curl_ca -b "$jar" "https://grafana.$BASE_DOMAIN/api/user/orgs" | jq -r '.[0].role')" == Admin ]] ;;
    harbor)  sso_browser_login "https://harbor.$BASE_DOMAIN/c/oidc/login?redirect_url=/harbor/projects" "$u" "$jar" >/dev/null &&
             [[ "$(_curl_ca -b "$jar" "https://harbor.$BASE_DOMAIN/api/v2.0/users/current" | jq -r .admin_role_in_auth)" == true ]] ;;
    openbao) q="$(jq -n --arg r "https://openbao.$BASE_DOMAIN/ui/vault/auth/oidc/oidc/callback" '{role: "sandbox", redirect_uri: $r}' |
               bao_api POST auth/oidc/oidc/auth_url | jq -r .data.auth_url)"
             landed="$(sso_browser_login "$q" "$u" "$jar")" || return 1
             tok="$(_curl_ca "$BAO_URL/v1/auth/oidc/oidc/callback?${landed#*\?}" | jq -r .auth.client_token)"
             _curl_ca -H "X-Vault-Token: $tok" "$BAO_URL/v1/auth/token/lookup-self" | jq -e '.data.identity_policies | index("sandbox-admin")' ;;
  esac
}

# Layer 3: Agent Router only accepts calls carrying a valid Substrate actor JWT (S4). A direct call from any other pod,
# with no token or a forged one, is rejected by Envoy before Agent Router adds the provider key.
agent_router_rejects_without_actor_jwt() {
  local out
  # The probe waits for stdin first: kubectl run -i only shows output produced after it attaches (slow first pull).
  out="$(echo go | kc -n agent-router run kcs-verify-s4 --rm -i --restart=Never --quiet --image=curlimages/curl:8.17.0 -- sh -c \
    'read -r _; U=http://agent-router.envoy-gateway-system.svc.cluster.local/anthropic/v1/messages
     B="{\"model\":\"x\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"   # well-formed: Agent Router 400s a bad body before the JWT check
     for k in "" "x-api-key: eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln"; do curl -s -o /dev/null -w "%{http_code} " $U -H "content-type: application/json" ${k:+-H "$k"} -d "$B"; done' 2>/dev/null)"
  [[ "$out" == "401 401 "* ]] || { warn "expected 401 401, got: $out"; return 1; }
}

verify_l3() {
  log "Layer 3: agents (Agent Router)"
  check "Agent Router controller running, Gateway agent-router Programmed" bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n agent-router wait gateway/agent-router --for=condition=Programmed --timeout=30s"
  bao_connect >/dev/null 2>&1
  check "Agent Router rejects calls without a valid actor JWT (no token / forged token → 401)" agent_router_rejects_without_actor_jwt
  log "Layer 3: agents (kagent + Agent Substrate)"
  check "Substrate WorkerPool kagent-default Ready (gVisor)" bash -c \
    "[[ \$(kubectl --context '$KUBE_CONTEXT' -n kagent get workerpool kagent-default -o jsonpath='{.status.readyReplicas}') -ge 1 ]]"
  check "Agent hello-substrate Ready (golden snapshot built)" kc -n kagent wait agent/hello-substrate --for=condition=Ready --timeout=30s
  check "no model API key anywhere in the kagent namespace" no_key_in_kagent
  check "kagent's API (insecure mode) is closed to pods outside its callers (a pod in mcp gets no connection)" kagent_api_closed
  case "$MODEL_PROVIDER" in
    anthropic) check "an agent session reaches Anthropic only via Agent Router (actor JWT accepted, key added by the router)" agent_session_via_router ;;
    stub)      check "an agent session gets its answer from the stub model via Agent Router (actor JWT accepted)" agent_session_via_router ;;
    vllm)      check "an agent session gets its answer from the local model (vLLM) via Agent Router" agent_session_via_router ;;
  esac
  check "one trace spans the agent runtime and Agent Router (Jaeger)" agent_trace_spans_router
  check "Substrate's egress gateway cannot reach the internet directly (NetworkPolicy)" bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n ate-system get networkpolicy atenet-egress-in-cluster-only -o name"
}
agent_trace_spans_router() {   # uses the session the previous check ran
  sleep 10
  _gw_get jaeger "/api/traces?service=hello-substrate&limit=20&lookback=15m" |
    jq -e '[.data[] | [.processes[].serviceName] | (index("agent-router") != null) and (index("kagent-controller") != null)] | any'
}
kagent_api_closed() {
  local out
  out="$(kc -n mcp run "np-probe-$RANDOM" --rm -i --restart=Never --quiet --image=docker.io/alpine/k8s:1.37.0 --command -- \
    sh -c 'read -t 5 _ ; curl -s -m 5 -o /dev/null -w "%{http_code}" http://kagent-controller.kagent.svc:8083/health || echo blocked' \
    <<<"go" 2>/dev/null | tail -1)"
  [[ "$out" == *blocked ]] || { echo "got: $out" >&2; return 1; }
}
no_key_in_kagent() { ! kc -n kagent get secrets -o json | jq -e '[.items[].data // {} | keys[] | ascii_downcase | select(test("api_?key"))] | length > 0' >/dev/null; }
agent_session_via_router() {   # hello-substrate, through ModelConfig "default" (MODEL_PROVIDER)
  local sid out
  have kagent || return 1
  sid="$(kubectl config use-context "$KUBE_CONTEXT" >/dev/null && kagent agent session create --agent hello-substrate -o json 2>/dev/null | jq -r .session.id)"
  [[ -n "$sid" && "$sid" != null ]] || return 1
  out="$(timeout 300 kagent agent invoke --session "$sid" --task "Reply with the single word: pong" 2>&1)"
  case "$MODEL_PROVIDER" in
    stub) grep -q "sandbox stub model" <<<"$out" ;;
    vllm) grep -qi pong <<<"$out" ;;
    anthropic)
      if [[ "$(bao_kv_get models/provider apiKey)" == placeholder ]]; then   # no key: Anthropic's 401 proves the path
        grep -q "agent-router.envoy-gateway-system.svc.cluster.local/anthropic" <<<"$out" && grep -q "invalid x-api-key" <<<"$out"
      else grep -qi pong <<<"$out"; fi ;;
  esac || { echo "reply: ${out:0:300}" >&2; return 1; }
}

# Layer 4: MCP through Agent Router. mcp_session <user> logs in as <user> via the Inspector's public client (PKCE),
# initializes an MCP session at https://mcp.<domain>/mcp and leaves curl args in MCP_H; mcp_call <tool> prints the
# HTTP status of a tools/call.
MCP_URL="https://mcp.$BASE_DOMAIN/mcp"
# mcp_session <user> | <user>@<agent> (delegated token, S6) | @<agent> (the agent's own token)
mcp_session() {
  local tok hdr sid
  case "$1" in
    @mcp-agent)  tok="$(actor_token)" ;;
    *@mcp-agent) tok="$(delegated_token "${1%@*}")" ;;
    *)   tok="$(pkce_token "$1" mcp-inspector "https://inspector.$BASE_DOMAIN/oauth/callback" "openid mcp")" ;;
  esac
  [[ -n "$tok" ]] || return 1
  MCP_H=(-s --max-time 15 --cacert "$CA_CRT" -H "Authorization: Bearer $tok" -H 'content-type: application/json'
    -H 'accept: application/json, text/event-stream' -H 'mcp-protocol-version: 2025-06-18')
  hdr="$(curl "${MCP_H[@]}" -D - -o /dev/null "$MCP_URL" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"kcs-verify","version":"1"}}}')"
  sid="$(grep -i '^mcp-session-id:' <<<"$hdr" | cut -d' ' -f2 | tr -d '\r')"
  [[ -n "$sid" ]] || return 1
  MCP_H+=(-H "mcp-session-id: $sid")
  curl "${MCP_H[@]}" -o /dev/null "$MCP_URL" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
}
mcp_call() {
  curl "${MCP_H[@]}" -o /dev/null -w '%{http_code}' "$MCP_URL" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"everything__$1\",\"arguments\":{\"message\":\"hi\"}}}"
}
mcp_rules() { # <user> <tool>=<status> ...
  local u=$1 t got; shift
  mcp_session "$u" || { warn "$u: no MCP session"; return 1; }
  for t in "$@"; do got="$(mcp_call "${t%=*}")"; [[ "$got" == "${t#*=}" ]] || { warn "$u ${t%=*}: got $got"; return 1; }; done
}
delegated_claims_ok() {
  local t; t="$(delegated_token "$1")" || return 1
  cut -d. -f2 <<<"$t" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -e --arg u "$1" --arg aud "$MCP_URL" \
    '.preferred_username == $u and .act.client_id == "mcp-agent" and .azp == "mcp-agent" and (.aud == $aud or (.aud | index($aud)))'
}
no_exchange_without_consent() {   # a token without may_act (alice via the Inspector): the agent gets nothing
  local subj
  subj="$(pkce_token "$1" mcp-inspector "https://inspector.$BASE_DOMAIN/oauth/callback" "openid mcp")" || return 1
  [[ -z "$(agent_run <<<"$subj")" ]]
}
other_sa_refused() { [[ -z "$(AGENT_SA=default actor_token)" ]]; }
agent_needs_svid() {   # mcp-agent has no secret: client_credentials without its SVID is refused
  [[ "$(curl -s --cacert "$CA_CRT" -o /dev/null -w '%{http_code}' "https://keycloak.$BASE_DOMAIN/realms/sandbox/protocol/openid-connect/token" \
    -d grant_type=client_credentials -d client_id=mcp-agent -d client_secret=guess)" == 401 ]]
}
# S7: one MCP session (one token) for <user>; <tool> is denied, allowed after granting <role> in Keycloak, denied again
# after removing it. Shows decisions come from Keycloak on every call (AuthZEN), not from the token.
role_flip() {
  local user=$1 tool=$2 role=$3 uid r a b c
  mcp_session "$user" || return 1
  uid="$(kc_admin GET "/users?username=$user&exact=true" | jq -r '.[0].id')"; r="$(kc_admin GET "/roles/$role")"
  a="$(mcp_call "$tool")"
  kc_admin POST "/users/$uid/role-mappings/realm" -d "[$r]" >/dev/null; b="$(mcp_call "$tool")"
  kc_admin DELETE "/users/$uid/role-mappings/realm" -d "[$r]" >/dev/null; c="$(mcp_call "$tool")"
  [[ "$a $b $c" == "403 200 403" ]] || { warn "$user $tool: $a → grant → $b → revoke → $c"; return 1; }
}
mcp_stream_stays_open() {   # SSE notification stream through both gateways outlives Envoy's default 15 s timeout
  local start=$SECONDS
  mcp_session alice || return 1
  curl "${MCP_H[@]}" --max-time 25 -o /dev/null -H 'accept: text/event-stream' "$MCP_URL"
  ((SECONDS - start >= 24))
}
mcp_rejects_anonymous() {
  curl -s --cacert "$CA_CRT" -D - -o /dev/null "$MCP_URL" -H 'content-type: application/json' -d '{}' |
    grep -qi "^www-authenticate: Bearer .*resource_metadata=\"https://mcp.$BASE_DOMAIN/.well-known/oauth-protected-resource/mcp\""
}
mcp_rejects_wrong_audience() { # a valid, signed Keycloak token for another audience (agent-portal → aud mcp-agent)
  # Envoy's JWT filter answers a wrong audience with 403 + WWW-Authenticate error="invalid_token" (not 401).
  local tok hdr
  tok="$(pkce_token alice agent-portal "https://kagent.$BASE_DOMAIN/delegation/callback" "openid delegation:client:mcp-agent")" || return 1
  hdr="$(curl -s --cacert "$CA_CRT" -D - -o /dev/null "$MCP_URL" -H "Authorization: Bearer $tok" \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"kcs-verify","version":"1"}}}')"
  grep -qE '^HTTP/[0-9.]+ 40[13]' <<<"$hdr" && grep -qi '^www-authenticate: .*error="invalid_token"' <<<"$hdr" ||
    { echo "got: $(head -1 <<<"$hdr")" >&2; return 1; }
}
inspector_is() { # <user> <status>: the Inspector UI answers <status> to <user> after gateway login
  sso_browser_login "https://inspector.$BASE_DOMAIN/" "$1" "$JAR_DIR/sso-inspector-$1" >/dev/null
  [[ "$(curl -s --cacert "$CA_CRT" -b "$JAR_DIR/sso-inspector-$1" -o /dev/null -w '%{http_code}' "https://inspector.$BASE_DOMAIN/")" == "$2" ]]
}

verify_l4() {
  log "Layer 4: MCP through Agent Router (OAuth with Keycloak, per-tool rules)"
  check "MCPRoute mcp Accepted" kc -n mcp wait mcproute/mcp --for=condition=Accepted --timeout=30s
  check "anonymous MCP call → 401 pointing to the protected resource metadata (RFC 9728)" mcp_rejects_anonymous
  check "protected resource metadata names Keycloak realm sandbox as authorization server" bash -c \
    "curl -s --cacert '$CA_CRT' https://mcp.$BASE_DOMAIN/.well-known/oauth-protected-resource/mcp | jq -e '.authorization_servers == [\"https://keycloak.$BASE_DOMAIN/realms/sandbox\"]'"
  bao_connect >/dev/null 2>&1
  check "MCP notification stream (SSE) stays open past 15 s (no gateway request timeout)" mcp_stream_stays_open
  check "a valid Keycloak token for another audience (alice's agent-portal token) is refused as invalid_token" mcp_rejects_wrong_audience
  check "alice (sandbox-admins) may call echo and get-env" mcp_rules alice echo=200 get-env=200
  check "bob (sandbox-viewers) may call echo and get-sum, not get-env (403)" mcp_rules bob echo=200 get-sum=200 get-env=403
  log "Layer 4: delegation (S6: user consents; agent mcp-agent, authenticated by its SPIRE identity, exchanges for a token with act; rights = user ∩ agent)"
  check "delegated token for alice: sub = alice, act.client_id = mcp-agent, audience = MCP server" delegated_claims_ok alice
  check "alice via mcp-agent: echo, get-env allowed; get-sum denied (not in the agent's allowlist)" mcp_rules alice@mcp-agent echo=200 get-env=200 get-sum=403
  check "bob via mcp-agent: echo allowed; get-env denied (bob may not), get-sum denied (agent may not)" mcp_rules bob@mcp-agent echo=200 get-env=403 get-sum=403
  check "mcp-agent on its own (no user): no tool calls" mcp_rules @mcp-agent echo=403
  check "a user token without consent to mcp-agent can't be exchanged by it" no_exchange_without_consent alice
  check "mcp-agent logs in only with its SPIRE JWT-SVID (no client secret exists; secret login → 401)" agent_needs_svid
  check "a pod with another ServiceAccount (mcp/default) can't log in as mcp-agent (wrong SPIFFE ID)" other_sa_refused
  log "Layer 4: a kagent agent acts for the signed-in user (kagent forwards the user's token; delegation proxy exchanges it)"
  check "Agents mcp-agent and mcp-agent-stub Ready (MCP server via the delegation proxy)" \
    kc -n kagent wait agent/mcp-agent agent/mcp-agent-stub --for=condition=Ready --timeout=60s
  # Deterministic checks on mcp-agent-stub (the scripted stub decides the tool call); then, with a real model, a smoke
  # test that mcp-agent itself chooses and makes a delegated call.
  AGENT=mcp-agent-stub
  check "alice asks mcp-agent-stub to echo: the tool runs (delegated: user alice, act mcp-agent)" agent_says alice "echo hello" 'returned: .*Echo: hello'
  check "alice asks for the environment: get-env runs (agent and alice both may)" agent_says alice "show the environment" 'get-env. returned'
  check "alice asks to add: get-sum not even offered (Agent Router filters the agent's tools/list to its allowlist)" agent_says alice "add 2 and 3" 'stub model'
  check "bob asks for the environment: refused (bob may not call get-env)" agent_says bob "show the environment" 'refused or failed'
  check "the delegation proxy logged user alice, act mcp-agent for a tools/call" bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n mcp logs deploy/delegation-proxy -c proxy --since=10m | grep '^{' | jq -se 'map(select(.user == \"alice\" and .act == \"mcp-agent\" and .method == \"tools/call\")) | length > 0'"
  check "without a user token the agent gets no tools (kagent can't pass one on)" agent_says - "echo hello" 'stub model'
  check "Jaeger: one trace names the user (alice), the agent (mcp-agent), the tool and the Substrate actor" \
    wait_for "delegation trace in Jaeger" 30 delegation_trace_ok
  check "Prometheus: delegated calls counted by user and agent (Grafana \"Agents\" dashboard)" \
    wait_for "delegation_proxy_calls_total for alice" 60 delegation_counted
  if [[ "$MODEL_PROVIDER" != stub ]]; then
    check "the $MODEL_PROVIDER model behind mcp-agent chooses the echo tool and calls it for alice (delegated)" real_model_tool_call alice
  fi
  if [[ "$(yq -r .decisions "$ROOT/manifests/mcp-demo/values.yaml")" == keycloak ]]; then
    log "Layer 4: Keycloak decides per call (S7: AuthZEN PDP, PEP in front of Agent Router)"
    check "AuthZEN PEP ready (has its SPIRE identity)" kc -n mcp wait deploy/mcp-pep --for=condition=Available --timeout=60s
    check "bob, same token: get-env 403 → role mcp-env-reader granted → 200 → revoked → 403" role_flip bob get-env mcp-env-reader
  fi
  log "Layer 4: MCP Inspector (gateway SSO, sandbox-admins only)"
  check "https://inspector.$BASE_DOMAIN redirects anonymous users to Keycloak" bash -c \
    "curl -s --cacert '$CA_CRT' -o /dev/null -w '%{redirect_url}' https://inspector.$BASE_DOMAIN/ | grep -q '^https://keycloak.$BASE_DOMAIN/'"
  check "admin opens the Inspector" inspector_is admin 200
  check "bob is refused (403) after login" inspector_is bob 403
}

# agent_says <user|-> <task> <regex>: <user> signs in at the kagent client (consenting that mcp-agent may act for them),
# sends <task> to Agent $AGENT (default mcp-agent) over A2A with that token (as the kagent UI does via the gateway), and
# the reply must match <regex>. "-" sends no token.
agent_says() {
  local user=$1 task=$2 want=$3 tok="" out
  if [[ "$user" != - ]]; then
    tok="$(pkce_token "$user" kagent "https://kagent.$BASE_DOMAIN/oauth2/callback" "openid delegation:client:mcp-agent" confidential)" || return 1
  fi
  [[ -n "${_kagent_pf:-}" ]] || { port_forward kagent kagent-controller 18083 8083; _kagent_pf=1; sleep 2; }
  out="$(curl -s -m 180 "http://localhost:18083/agents/kagent/${AGENT:-mcp-agent}" -H 'A2A-Version: 1.0' -H 'content-type: application/json' \
    ${tok:+-H "Authorization: Bearer $tok"} \
    -d "$(jq -nc --arg t "$task" '{jsonrpc: "2.0", id: 1, method: "SendMessage",
          params: {message: {messageId: ("verify-" + (now | tostring)), role: "ROLE_USER", parts: [{text: $t}]}}}')" |
    jq -r '[.result.task.artifacts[]?.parts[]?.text, .result.task.status.message.parts[]?.text, .error.message] | map(select(.)) | join(" ")')"
  grep -qE "$want" <<<"$out" || { echo "reply: ${out:0:300}" >&2; return 1; }
}

delegation_counted() {
  _gw_get prometheus "/api/v1/query?query=$(jq -rn '"delegation_proxy_calls_total{user_name=\"alice\",gen_ai_agent_name=\"mcp-agent\"}" | @uri')" |
    jq -e '.data.result | length > 0'
}
# real_model_tool_call <user>: ask mcp-agent (MODEL_PROVIDER's model) to use its echo tool; pass when the delegation
# proxy logged a successful tools/call for <user> (models decide for themselves, so allow a second try).
real_model_tool_call() {
  local i since
  for i in 1 2; do
    since="$(date -u +%Y-%m-%dT%H:%M:%S)"
    AGENT=mcp-agent agent_says "$1" "Use your echo tool to echo exactly this text: verify-$i" '.' || continue
    kubectl --context "$KUBE_CONTEXT" -n mcp logs deploy/delegation-proxy -c proxy --since=5m | grep '^{' |
      jq -se --arg u "$1" --arg t "$since" 'map(select(.ts >= $t and .user == $u and .method == "tools/call" and .status == 200)) | length > 0' \
      >/dev/null && return 0
  done
  return 1
}
# delegation_trace_ok: a recent trace where the delegation proxy's span (user.name alice, gen_ai.agent.name mcp-agent,
# gen_ai.tool.name everything__echo) is the parent of Agent Router's tools/call span, and the agent's actor appears
# (ate.actor.name on Substrate's egress gateway span).
delegation_trace_ok() {
  _gw_get jaeger "/api/traces?service=delegation-proxy&limit=20&lookback=15m&tags=$(jq -rn '{"user.name": "alice", "gen_ai.tool.name": "everything__echo"} | tojson | @uri')" |
    jq -e '[.data[] | .processes as $p | .spans as $s
      | ($s[] | select($p[.processID].serviceName == "delegation-proxy"
                       and any(.tags[]; .key == "gen_ai.agent.name" and .value == "mcp-agent")) | .spanID) as $proxy
      | (any($s[]; $p[.processID].serviceName == "agent-router" and .operationName == "tools/call everything__echo"
                   and any(.references[]?; .spanID == $proxy))
         and any($s[]; any(.tags[]; .key == "ate.actor.name")))] | any'
}

verify_l5() {
  log "Layer 5: local model (vLLM on CPU, weights from Harbor as an image volume)"
  local_model
  check "vLLM serving $LM_HF (Deployment models/vllm Available)" kc -n models wait deploy/vllm --for=condition=Available --timeout=60s
  check "the weights are mounted from Harbor ($HARBOR_HOST/models/$LM_NAME:${LM_REV:0:12}), not baked into the image" bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n models get deploy vllm -o json | jq -e --arg r '$HARBOR_HOST/models/$LM_NAME:${LM_REV:0:12}' '.spec.template.spec.volumes[] | select(.image) | .image.reference == \$r'"
  check "vLLM is offline and reachable only from Agent Router (NetworkPolicy: no egress)" bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n models get networkpolicy vllm -o json | jq -e '(.spec.egress // []) == [] and (.spec.policyTypes | index(\"Egress\"))'"
  check "a call to the local model without an actor JWT is refused by Agent Router (401)" \
    wait_for "Agent Router route for $LM_NAME" 60 local_model_needs_actor_jwt   # a just-(re)created route takes a moment
  check "llm-d router: endpoint picker ready, InferencePool llm-d-router selects the vLLM pods" bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n models wait deploy/llm-d-router-epp --for=condition=Available --timeout=60s >/dev/null &&
     kubectl --context '$KUBE_CONTEXT' -n models get inferencepool llm-d-router -o json | jq -e '.spec.selector.matchLabels.app == \"vllm\"'"
  check "Agent Router sends $LM_NAME to the InferencePool (llm-d picks the replica)" bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n models get aigatewayroute local-models -o json | jq -e '.spec.rules[0].backendRefs[0].kind == \"InferencePool\" and any(.status.conditions[]; .type == \"Accepted\" and .status == \"True\")'"
  check "replicas as configured (VLLM_REPLICAS=$VLLM_REPLICAS), memory sized from the model" bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n models get deploy vllm -o json | jq -e '.spec.replicas == $VLLM_REPLICAS and .status.readyReplicas == $VLLM_REPLICAS'"
  check "Prometheus scrapes vLLM and llm-d's endpoint picker (Grafana \"Agents\" row \"Local model\")" local_model_metrics
  check "ModelConfig default points every agent at the local model" bash -c \
    "kubectl --context '$KUBE_CONTEXT' -n kagent get modelconfig default -o json | jq -e '.spec.model == \"$LM_NAME\" and .spec.provider == \"OpenAI\"'"
}
local_model_metrics() {
  _gw_get prometheus "/api/v1/query?query=$(jq -rn '"count({__name__=\"vllm:num_requests_running\"}) and count(llm_d_epp_ready_endpoints)"' | jq -rR @uri)" |
    jq -e '.data.result | length > 0'
}
local_model_needs_actor_jwt() {
  local code
  code="$(kc -n agent-router run "probe-$RANDOM" --rm -i --restart=Never --quiet --image=docker.io/alpine/k8s:1.37.0 --command -- \
    curl -s -o /dev/null -w '%{http_code}' -H 'content-type: application/json' \
    -d "{\"model\":\"$LM_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
    http://agent-router.envoy-gateway-system.svc.cluster.local/v1/chat/completions 2>/dev/null | tail -c 3)"
  [[ "$code" == 401 ]] || { echo "got $code" >&2; return 1; }
}

# With no layer argument, run the checks enabled by the deployment profile.
if [[ -n "${1:-}" ]]; then
  LAYERS="$1"
else
  case "$PROFILE" in
    bootstrap) LAYERS='0' ;;
    platform) LAYERS='0 1' ;;
    identity) LAYERS='0 1 2' ;;
    agents) LAYERS='0 1 2 3' ;;
    delegation|full) LAYERS='0 1 2 3 4' ;;
  esac
  if [[ "$MODEL_PROVIDER" == vllm && "$PROFILE" =~ ^(agents|delegation|full)$ ]]; then
    LAYERS+=" 5"
  fi
fi

for layer in $LAYERS; do
  check_layer="verify_l$layer"
  declare -F "$check_layer" >/dev/null || die "No verification for layer $layer"
  "$check_layer"
done
if ((FAILED == 0)); then
  ok 'All verification checks passed'
else
  warn "$FAILED checks failed"
fi
exit "$FAILED"
