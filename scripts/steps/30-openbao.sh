#!/usr/bin/env bash
# STEP: openbao
# DESCRIPTION: Install and initialize OpenBao, provision auth roles, and seed credentials
# REQUIRES: cluster ca
# PROVIDES: https://openbao.openbao.svc:8200, KV v2 at secret/, auth/kubernetes, secret/platform/* admin passwords
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Why OpenBao first (ADR-015, plan §7.1): every later secret (Harbor/Gitea/Argo admin passwords, robot tokens, the model
# key) is generated straight into OpenBao and read from there, so nothing secret lives in Git or in bootstrap scripts.
CHART_REPO="$(ver .charts.openbao.repo)"; CHART_VERSION="$(ver .charts.openbao.version)"
VALUES="$ROOT/values/openbao/values.yaml"
SANS="DNS:openbao.openbao.svc,DNS:openbao.openbao.svc.cluster.local,DNS:openbao.$BASE_DOMAIN,DNS:localhost,IP:127.0.0.1"
SEED_PATHS="platform/harbor platform/gitea platform/argocd platform/grafana platform/sandbox-ca-public models/provider bootstrap/ca"

# Confidential Keycloak clients (manifests/keycloak/values.yaml) without a SPIFFE identity: each gets a generated secret.
oidc_clients() { yq -r '.clients[] | select(.spiffeId == null) | .name' "$ROOT/manifests/keycloak/values.yaml"; }
release_ok() { [[ "$(hlm -n "$BAO_NS" list -f '^openbao$' -o json 2>/dev/null | jq -r '.[0].chart // ""')" == "openbao-$CHART_VERSION" ]]; }
unsealed()   { bao_health | jq -e '.initialized and (.sealed | not)' >/dev/null 2>&1; }
config_ok()  {
  bao_api GET auth/kubernetes/role/external-secrets >/dev/null 2>&1 && bao_api GET auth/kubernetes/role/spire-server >/dev/null 2>&1 &&
  bao_exists secret/data/platform/sso-users/admin && for c in $(oidc_clients); do bao_exists "secret/data/platform/oidc/$c" || return 1; done &&
  bao_api GET sys/mounts | jq -e '.data["secret/"].options.version == "2"' >/dev/null &&
    bao_api GET sys/auth | jq -e '.data["kubernetes/"]' >/dev/null &&
    for p in $SEED_PATHS; do bao_exists "secret/data/$p" || return 1; done
}

check() { release_ok && [[ -s "$BAO_STATE/init.json" ]] && bao_connect && unsealed && config_ok && root_retired; }

install() {
  ensure_ns "$BAO_NS"
  ca_issue openbao 825 "$SANS"
  apply_secret "$BAO_NS" openbao-tls generic --from-file=tls.crt="$CA_DIR/issued/openbao.crt" \
    --from-file=tls.key="$CA_DIR/issued/openbao.key" --from-file=ca.crt="$CA_CRT"
  # Static unseal key: generated once, kept in .state/openbao (to recover the data) and in a Secret (to auto-unseal).
  mkdir -p "$BAO_STATE" && chmod 700 "$BAO_STATE"
  [[ -s "$BAO_STATE/unseal.key" ]] || run openssl rand -out "$BAO_STATE/unseal.key" 32
  [[ -s "$BAO_STATE/unseal.key" ]] && chmod 600 "$BAO_STATE/unseal.key"
  apply_secret "$BAO_NS" openbao-unseal generic --from-file=key="$BAO_STATE/unseal.key"
  # No --wait: the pod only turns Ready once initialized and unsealed, which happens below.
  helm_upsert openbao "$BAO_NS" openbao "$CHART_VERSION" --repo "$CHART_REPO" -f "$VALUES" --wait=false
}

openbao_running() {
  [[ "$(kc -n "$BAO_NS" get pod openbao-0 -o jsonpath='{.status.phase}')" == Running ]]
}

initialize() {
  wait_for 'OpenBao pod running' 300 openbao_running
  bao_connect

  local init="$BAO_STATE/init.json" initialized archive pending
  initialized=$(bao_health | jq -r '.initialized | booleans') || return
  if [[ "$initialized" == true ]]; then
    [[ -s "$init" ]] || die "The cluster is initialized but $init is unavailable. Restore the local recovery material or recreate OpenBao."
  elif [[ "$initialized" == false ]]; then
    log 'Initializing OpenBao with one recovery share'
    if [[ -s "$init" ]]; then
      archive=$(mktemp "$BAO_STATE/init.previous.XXXXXX") || return
      cat "$init" > "$archive" || return
      log "Saved the previous cluster's recovery file at $archive"
    fi
    pending=$(mktemp "$BAO_STATE/init.pending.XXXXXX") || return
    printf '%s\n' '{"recovery_shares":1,"recovery_threshold":1}' |
      bao_api POST sys/init > "$pending" || die "OpenBao initialization failed. Check $pending for the response before retrying."
    rm -f "$BAO_STATE/operator-token"
    mv -f "$pending" "$init" || die "Could not install the new recovery file. It is saved at $pending."
  else
    die 'OpenBao health did not report initialization status'
  fi
  wait_for 'OpenBao unsealed' 60 unsealed
}

configure() {
  bao_api GET sys/mounts | jq -e '.data["secret/"]' >/dev/null ||
    echo '{"type":"kv","options":{"version":"2"},"description":"kubeconsandbox secrets"}' | bao_api POST sys/mounts/secret >/dev/null
  bao_api GET sys/auth | jq -e '.data["kubernetes/"]' >/dev/null ||
    echo '{"type":"kubernetes"}' | bao_api POST sys/auth/kubernetes >/dev/null
  # In-cluster: OpenBao validates ServiceAccount tokens with its own SA (chart authDelegator ClusterRoleBinding).
  echo '{"kubernetes_host":"https://kubernetes.default.svc"}' | bao_api POST auth/kubernetes/config >/dev/null
  ok "KV v2 at secret/, auth/kubernetes enabled"
  # Consumers (ADR-015): each authenticates with its own ServiceAccount and gets only what it needs.
  # L1 External Secrets Operator: read KV, but never the bootstrap material (CA key).
  jq -n '{policy: "path \"secret/data/*\" { capabilities = [\"read\"] }\npath \"secret/metadata/*\" { capabilities = [\"read\", \"list\"] }\npath \"secret/data/bootstrap/*\" { capabilities = [\"deny\"] }\npath \"secret/metadata/bootstrap/*\" { capabilities = [\"deny\"] }\n"}' |
    bao_api POST sys/policies/acl/external-secrets >/dev/null
  echo '{"bound_service_account_names":["external-secrets"],"bound_service_account_namespaces":["external-secrets"],"token_policies":["external-secrets"],"token_ttl":"1h"}' |
    bao_api POST auth/kubernetes/role/external-secrets >/dev/null
  ok "OpenBao role external-secrets (SA external-secrets/external-secrets; no access to secret/bootstrap/*)"

  # The sandbox root's PUBLIC cert, readable through ESO, so any namespace can trust OpenBao and *.localtest.me.
  jq -n --rawfile c "$CA_CRT" '{"ca.crt": $c}' | bao_kv_put_if_absent platform/sandbox-ca-public

  # L2 SPIRE (spike S5): OpenBao PKI holds the sandbox root and signs SPIRE's CA directly. The root has pathlen:1, so a
  # separate OpenBao intermediate (root → OpenBao int → SPIRE CA → SVID) would exceed it; the root key is already in
  # OpenBao KV (plan §3.3), so importing it into PKI adds no exposure. Chain: sandbox root → SPIRE CA → SVIDs.
  bao_api GET sys/mounts | jq -e '.data["pki/"]' >/dev/null ||
    echo '{"type":"pki","config":{"max_lease_ttl":"87600h"},"description":"sandbox root CA (signs SPIRE intermediates)"}' |
      bao_api POST sys/mounts/pki >/dev/null
  if ! bao_api GET pki/cert/ca >/dev/null 2>&1 || [[ -z "$(bao_api GET pki/cert/ca | jq -r '.data.certificate // empty')" ]]; then
    jq -n --rawfile c "$CA_CRT" --rawfile k "$CA_KEY" '{pem_bundle: ($k + $c)}' | bao_api POST pki/config/ca >/dev/null
  fi
  jq -n '{policy: "path \"pki/root/sign-intermediate\" { capabilities = [\"update\"] }\n"}' |
    bao_api POST sys/policies/acl/spire-server >/dev/null
  echo '{"bound_service_account_names":["spire-server"],"bound_service_account_namespaces":["spire-server"],"audience":"vault","token_policies":["spire-server"],"token_ttl":"1h"}' |
    bao_api POST auth/kubernetes/role/spire-server >/dev/null
  ok "OpenBao PKI pki/ = sandbox root; role spire-server may only sign intermediates"

  # L2 SSO (Keycloak realm "sandbox"): people's initial passwords and one OIDC client secret per service. Generated once;
  # ESO hands them to Keycloak's realm import (placeholders) and to each service. "admin" is the operator's account
  # for every UI (group sandbox-admins); alice/bob are the plan's demo personas (admin / read-only).
  local u c
  for u in admin alice bob; do
    jq -n --arg p "$(gen_password)" '{password: $p}' | bao_kv_put_if_absent "platform/sso-users/$u"
  done
  for c in $(oidc_clients); do
    jq -n --arg s "$(openssl rand -hex 24)" '{clientSecret: $s}' | bao_kv_put_if_absent "platform/oidc/$c"
  done
  # Master-realm client the Keycloak realm Job uses instead of the operator's admin (manifests/keycloak).
  jq -n --arg s "$(openssl rand -hex 24)" '{clientSecret: $s}' | bao_kv_put_if_absent platform/keycloak/realm-config

  local p
  for p in harbor gitea argocd grafana; do
    jq -n --arg p "$(gen_password)" '{adminPassword: $p}' | bao_kv_put_if_absent "platform/$p"
  done
  if [[ -n "$MODEL_API_KEY" ]]; then # an explicit key always wins (rotation = set it and re-run with --force openbao)
    jq -n --arg k "$MODEL_API_KEY" --arg pr "$MODEL_PROVIDER" --arg n "$MODEL_NAME" \
      '{data: {provider: $pr, model: $n, apiKey: $k}}' | bao_api POST secret/data/models/provider >/dev/null
    ok "secret/models/provider set from MODEL_API_KEY"
  else
    jq -n --arg pr "$MODEL_PROVIDER" --arg n "$MODEL_NAME" '{provider: $pr, model: $n, apiKey: "placeholder"}' |
      bao_kv_put_if_absent models/provider
  fi
  # Backup of the root CA, so the sandbox can be rebuilt with the same trust anchor (plan §3.3).
  jq -n --rawfile c "$CA_CRT" --rawfile k "$CA_KEY" '{crt: $c, key: $k}' | bao_kv_put_if_absent bootstrap/ca

  # Operator access without a standing root token: bootstrap, verify and print-access log in as ServiceAccount
  # openbao/sandbox-operator (scripts/lib/openbao.sh). Same powers as before, but short-lived and attributable.
  kc -n "$BAO_NS" create serviceaccount "$BAO_OPERATOR_SA" --dry-run=client -o yaml | kc apply -f - >/dev/null
  jq -n '{policy: "path \"*\" { capabilities = [\"create\", \"read\", \"update\", \"patch\", \"delete\", \"list\", \"sudo\"] }\n"}' |
    bao_api POST sys/policies/acl/sandbox-operator >/dev/null
  jq -n --arg sa "$BAO_OPERATOR_SA" --arg ns "$BAO_NS" --arg aud "$BAO_OPERATOR_AUD" \
    '{bound_service_account_names: [$sa], bound_service_account_namespaces: [$ns], audience: $aud,
      token_policies: ["sandbox-operator"], token_ttl: "15m", token_max_ttl: "30m"}' |
    bao_api POST "auth/kubernetes/role/$BAO_OPERATOR_SA" >/dev/null
  ok "OpenBao role sandbox-operator (SA $BAO_NS/$BAO_OPERATOR_SA, 15 min tokens) for bootstrap and verify"
  retire_root
}


apply() {
  install
  [[ "$DRY_RUN" == 1 ]] && { log "dry-run: would initialize, unseal and configure OpenBao"; return 0; }
  initialize
  configure
}

verify() {
  bao_connect
  unsealed || { warn "OpenBao is sealed or not initialized"; return 1; }
  ok "OpenBao $(bao_health | jq -r .version) initialized and unsealed (static seal)"
  config_ok || { warn "OpenBao base config or seeded secrets missing"; return 1; }
  ok "seeded: $(echo $SEED_PATHS | sed 's#[^ ]*#secret/&#g')"
  wait_for "openbao-0 Ready" 120 kc -n "$BAO_NS" wait pod openbao-0 --for=condition=Ready --timeout=5s || return 1
  root_retired && ok "no standing root token; bootstrap uses role sandbox-operator" || warn "root token still in init.json"
  warn "PoC: the recovery key is in $BAO_STATE/init.json (git-ignored). Keep it safe; don't share it."
}

run_step check apply verify
