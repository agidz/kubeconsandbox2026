# shellcheck shell=bash
# OpenBao helpers: talk to the HTTP API through a short-lived port-forward (no extra CLI to pin). Request bodies are
# sent on stdin, so secret values never appear on a command line.
# Credentials: no standing root token. Step 30 uses the root token from initialization once, creates the
# "sandbox-operator" Kubernetes-auth role, then revokes it. Afterwards every call logs in with a 10-minute token of
# ServiceAccount openbao/sandbox-operator (minted with your kubeconfig, i.e. cluster-admin) and caches the resulting
# OpenBao token (15 min) in .state/openbao/operator-token. Recovery: docs/operating.md (generate-root, recovery key).
# Sourced by common.sh; don't source directly.

BAO_NS=openbao
BAO_STATE="$STATE_DIR/openbao"
BAO_PORT="${BAO_PORT:-18200}"
BAO_URL="https://127.0.0.1:$BAO_PORT"
_bao_connected=0

bao_connect() {
  if ((_bao_connected)); then return 0; fi
  port_forward "$BAO_NS" openbao "$BAO_PORT" 8200
  wait_for "OpenBao API on port $BAO_PORT" 30 curl -s --cacert "$CA_CRT" \
    "$BAO_URL/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null || return
  _bao_connected=1
}

BAO_OPERATOR_SA=sandbox-operator
BAO_OPERATOR_AUD=openbao-operator

bao_token() {
  local cache="$BAO_STATE/operator-token"
  local now root cached kubernetes_token response new_cache
  now=$(date +%s)
  if [[ -s "$BAO_STATE/init.json" ]]; then
    root=$(jq -r '.root_token // empty' "$BAO_STATE/init.json") || return
    if [[ -n "$root" ]]; then printf '%s\n' "$root"; return; fi
  fi
  if [[ -s "$cache" ]] &&
    cached=$(jq -er --argjson threshold "$((now + 60))" 'select(.exp > $threshold) | .token | strings' "$cache" 2>/dev/null); then
    printf '%s\n' "$cached"
    return
  fi
  kubernetes_token=$(kc -n "$BAO_NS" create token "$BAO_OPERATOR_SA" --audience "$BAO_OPERATOR_AUD" --duration 10m) || return
  response=$(jq -n --arg jwt "$kubernetes_token" --arg role "$BAO_OPERATOR_SA" '{ $role, $jwt }' |
    curl -sS --fail-with-body --cacert "$CA_CRT" -H 'Content-Type: application/json' --data-binary @- \
      "$BAO_URL/v1/auth/kubernetes/login") || return
  new_cache=$(mktemp "$cache.XXXXXX") || return
  if jq -ce --argjson now "$now" '.auth | {token: .client_token, exp: ($now + .lease_duration)}' <<< "$response" > "$new_cache"; then
    mv -f "$new_cache" "$cache" || return
    jq -r .token "$cache"
  else
    rm -f "$new_cache"
    return 1
  fi
}

bao_api() {
  local method=$1 endpoint=$2 token
  local options=(-sS --fail-with-body --cacert "$CA_CRT" --request "$method")
  # Initialization is unauthenticated, even when local state is from another cluster.
  if [[ "$endpoint" != sys/init && -s "$BAO_STATE/init.json" ]]; then
    token=$(bao_token) || return
    options+=(-H "X-Vault-Token: $token")
  fi
  case "$method" in
    GET|LIST) ;;
    *) options+=(-H 'Content-Type: application/json' --data-binary @-) ;;
  esac
  curl "${options[@]}" "$BAO_URL/v1/$endpoint"
}

bao_health() { curl -s --cacert "$CA_CRT" "$BAO_URL/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200"; }

# bao_exists <path>: 0 if a GET on the path succeeds (e.g. secret/data/platform/harbor).
bao_exists() { bao_api GET "$1" >/dev/null 2>&1; }

# bao_kv_put_if_absent <kv-v2 path under secret/>  (JSON object on stdin): writes only when the secret doesn't exist yet,
# so generated passwords stay stable across re-runs.
#   jq -n --arg p "$(gen_password)" '{adminPassword: $p}' | bao_kv_put_if_absent platform/harbor
bao_kv_put_if_absent() {
  local path=$1
  bao_exists "secret/data/$path" && { ok "secret/$path exists, kept"; return 0; }
  [[ "$DRY_RUN" == 1 ]] && { run bao_api POST "secret/data/$path" "(generated)"; return 0; }
  jq -c '{data: .}' | bao_api POST "secret/data/$path" >/dev/null && ok "secret/$path created"
}

gen_password() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

# bao_kv_get <path under secret/> <field>: print one field of a KV v2 secret (empty if missing). Output ends with a
# newline (jq -r); wrap it as <(printf %s "$(bao_kv_get ...)") when it becomes a file or Secret value.
bao_kv_get() { bao_api GET "secret/data/$1" 2>/dev/null | jq -r --arg f "$2" '.data.data[$f] // empty'; }

# retire_root: once the operator role works, revoke the initialization root token and drop it from init.json (the
# recovery key stays there; a root token can be regenerated with it, docs/operating.md).
retire_root() {
  local root; root="$(jq -r '.root_token // empty' "$BAO_STATE/init.json")"
  [[ -n "$root" ]] || { ok "no standing root token (retired)"; return 0; }
  local tmp; tmp="$(mktemp "$BAO_STATE/init.XXXX")"
  jq 'del(.root_token)' "$BAO_STATE/init.json" >"$tmp" && chmod 600 "$tmp"
  local saved="$BAO_STATE/init.json"; mv "$saved" "$saved.with-root"; mv "$tmp" "$saved"
  if bao_api GET auth/token/lookup-self >/dev/null; then   # now via the operator role
    curl -sS --fail-with-body --cacert "$CA_CRT" -X POST -H "X-Vault-Token: $root" "$BAO_URL/v1/auth/token/revoke-self" >/dev/null
    rm -f "$saved.with-root"
    ok "root token revoked and removed from $BAO_STATE/init.json (operator role works)"
  else
    mv "$saved.with-root" "$saved"; warn "operator login failed; kept the root token"; return 1
  fi
}
root_retired() { [[ -z "$(jq -r '.root_token // empty' "$BAO_STATE/init.json")" ]]; }
