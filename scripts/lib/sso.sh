# shellcheck shell=bash
# SSO helpers (Keycloak realm "sandbox"). Sourced by common.sh; do not source directly.

# oidc_login <user> <client>: browser-style auth-code login against realm sandbox; prints the ID token's claims.
oidc_login() {
  local user=$1 client=$2 host jar redirect auth action loc code
  host="$(jq -r --arg c "$client" '.clients[] | select(.name == $c) | .host' <(yq -o=json "$ROOT/manifests/keycloak/values.yaml"))"
  redirect="https://$host.$BASE_DOMAIN$(yq -r ".clients[] | select(.name == \"$client\") | .redirects[0]" "$ROOT/manifests/keycloak/values.yaml")"
  jar="$(mktemp)"; local C=(-s --cacert "$CA_CRT" -c "$jar" -b "$jar")
  auth="https://keycloak.$BASE_DOMAIN/realms/sandbox/protocol/openid-connect"
  action="$(curl "${C[@]}" "$auth/auth?client_id=$client&response_type=code&scope=openid&redirect_uri=$(jq -rn --arg u "$redirect" '$u|@uri')" |
    grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//; s/"$//; s/&amp;/\&/g')"
  loc="$(curl "${C[@]}" -o /dev/null -w '%{redirect_url}' --data-urlencode "username=$user" \
    --data-urlencode "password=$(bao_kv_get "platform/sso-users/$user" password)" "$action")"
  code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$loc")"
  [[ -n "$code" ]] || { echo "no code (redirect: ${loc:0:120})" >&2; rm -f "$jar"; return 1; }
  curl "${C[@]}" -u "$client:$(bao_kv_get "platform/oidc/$client" clientSecret)" -d grant_type=authorization_code \
    -d "code=$code" --data-urlencode "redirect_uri=$redirect" "$auth/token" |
    jq -r .id_token | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -c '{iss, preferred_username, groups, aud}'
  rm -f "$jar"
}

# sso_browser_login <start-url> <user> <cookie-jar>: follow an app's "log in with SSO" redirect to Keycloak, submit the
# login form, and follow the callback back to the app. The app's session cookies end up in <cookie-jar>.
sso_browser_login() (
  local destination=$1 account=$2 jar=$3 html action password effective consent_code
  html=$(mktemp) || return
  trap 'rm -f "$html"' EXIT
  local request=(curl -sSL --cacert "$CA_CRT" --cookie-jar "$jar" --cookie "$jar")
  : > "$jar"
  "${request[@]}" --output "$html" "$destination" || return
  action=$(grep -oE 'action="[^"]+"' "$html" | head -1 | sed 's/action="//; s/"$//; s/&amp;/\&/g')
  if [[ "$action" != *login-actions* ]]; then
    printf 'Expected Keycloak login after %s\n' "$destination" >&2
    return 1
  fi
  password=$(bao_kv_get "platform/sso-users/$account" password) || return
  effective=$("${request[@]}" --output "$html" --write-out '%{url_effective}' \
    --data-urlencode "username=$account" --data-urlencode "password=$password" "$action") || return
  if grep -q 'name="accept"' "$html"; then
    action=$(grep -oE 'action="[^"]+"' "$html" | head -1 | sed 's/action="//; s/"$//; s/&amp;/\&/g')
    if [[ "$action" == /* ]]; then action="https://keycloak.$BASE_DOMAIN$action"; fi
    consent_code=$(grep -oE 'name="code" value="[^"]*"' "$html" | sed 's/.*value="//; s/"$//')
    effective=$("${request[@]}" --output /dev/null --write-out '%{url_effective}' \
      --data-urlencode "code=$consent_code" --data-urlencode accept=Yes "$action") || return
  fi
  printf '%s\n' "$effective"
)

# pkce_token <user> <client> <redirect uri> [scope] [confidential]: browser-style auth-code + PKCE (S256) login as
# <user> for a public client (e.g. mcp-inspector), or a confidential one when the 5th argument is set (secret from
# OpenBao platform/oidc/<client>); prints the access token.
pkce_token() {
  local user=$1 client=$2 redirect=$3 scope=${4:-openid} jar verifier challenge auth action loc code cauth=()
  [[ -n "${5:-}" ]] && cauth=(-u "$client:$(bao_kv_get "platform/oidc/$client" clientSecret)")
  jar="$(mktemp)"; local C=(-s --cacert "$CA_CRT" -c "$jar" -b "$jar")
  verifier="$(openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-64)"
  challenge="$(printf %s "$verifier" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')"
  auth="https://keycloak.$BASE_DOMAIN/realms/sandbox/protocol/openid-connect"
  action="$(curl "${C[@]}" "$auth/auth?client_id=$client&response_type=code&scope=$(jq -rn --arg s "$scope" '$s|@uri')&code_challenge=$challenge&code_challenge_method=S256&redirect_uri=$(jq -rn --arg u "$redirect" '$u|@uri')" |
    grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//; s/"$//; s/&amp;/\&/g')"
  local page; page="$(mktemp)"
  loc="$(curl "${C[@]}" -o "$page" -w '%{redirect_url}' --data-urlencode "username=$user" \
    --data-urlencode "password=$(bao_kv_get "platform/sso-users/$user" password)" "$action")"
  [[ "$loc" == "https://keycloak.$BASE_DOMAIN/"*"/login-actions/"* ]] && { curl "${C[@]}" -o "$page" "$loc"; loc=""; }
  if [[ -z "$loc" ]] && grep -q 'name="accept"' "$page"; then   # consent screen (clients with consent required): accept
    action="$(grep -oE 'action="[^"]+"' "$page" | head -1 | sed 's/action="//; s/"$//; s/&amp;/\&/g')"
    [[ "$action" == /* ]] && action="https://keycloak.$BASE_DOMAIN$action"   # the consent form posts to a relative URL
    loc="$(curl "${C[@]}" -o /dev/null -w '%{redirect_url}' \
      --data-urlencode "code=$(grep -oE 'name="code" value="[^"]*"' "$page" | sed 's/.*value="//; s/"$//')" \
      --data-urlencode "accept=Yes" "$action")"
  fi
  code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$loc")"
  rm -f "$jar" "$page"
  [[ -n "$code" ]] || { echo "no code (redirect: ${loc:0:120})" >&2; return 1; }
  curl -s --cacert "$CA_CRT" "${cauth[@]}" -d grant_type=authorization_code -d "client_id=$client" -d "code=$code" \
    -d "code_verifier=$verifier" --data-urlencode "redirect_uri=$redirect" "$auth/token" | jq -er .access_token
}

# agent_run [--self]: run the demo agent's delegate.sh (manifests/mcp-demo) in a one-off pod as ServiceAccount
# mcp/mcp-agent (AGENT_SA overrides it, for negative tests). The pod proves who it is with its SPIRE JWT-SVID (spiffe-helper init container); no secret involved.
agent_run() {
  local o
  o="$(jq -nc --arg args "$*" --arg sa "${AGENT_SA:-mcp-agent}" '{spec: {serviceAccountName: $sa, automountServiceAccountToken: false,
    initContainers: [{name: "svid", image: "ghcr.io/spiffe/spiffe-helper:0.12.3", args: ["-config", "/conf/helper.conf"],
      volumeMounts: [{name: "spiffe", mountPath: "/spiffe-workload-api", readOnly: true}, {name: "svid", mountPath: "/svid"},
                     {name: "conf", mountPath: "/conf"}]}],
    containers: [{name: "agent", image: "docker.io/alpine/k8s:1.37.0", stdin: true, stdinOnce: true,
      command: ["/bin/bash", "-c", "bash /tools/delegate.sh \($args)"],
      volumeMounts: [{name: "svid", mountPath: "/svid"}, {name: "tools", mountPath: "/tools"}, {name: "ca", mountPath: "/etc/sandbox-ca"}]}],
    volumes: [{name: "spiffe", csi: {driver: "csi.spiffe.io", readOnly: true}}, {name: "svid", emptyDir: {}},
              {name: "conf", configMap: {name: "mcp-agent-spiffe-helper"}}, {name: "tools", configMap: {name: "mcp-agent-tools"}},
              {name: "ca", secret: {secretName: "sandbox-ca"}}]}}')"
  kc -n mcp run "mcp-agent-$RANDOM" --rm -i --restart=Never --quiet --image=unused --overrides="$o" 2>/dev/null | grep -E '^ey' | tail -1
}

# delegated_token <user>: RFC 8693 delegation (Keycloak preview, spike S6). <user> logs in at the public client
# agent-portal and consents to scope delegation:client:mcp-agent (→ may_act in their token); the agent, in the cluster
# with its SPIRE identity, exchanges it. Prints the delegated access token (sub = user, act = mcp-agent).
delegated_token() {
  pkce_token "$1" agent-portal "https://kagent.$BASE_DOMAIN/delegation/callback" "openid delegation:client:mcp-agent" | agent_run
}
# actor_token: the agent's own token (client_credentials, authenticated with its JWT-SVID).
actor_token() { echo - | agent_run --self; }   # delegate.sh waits for stdin before it starts

# kc_admin <METHOD> <path under /admin/realms/sandbox> [curl args]: Keycloak admin API as the SSO admin (realm-admin).
kc_admin() {
  local m=$1 p=$2 t; shift 2
  t="$(curl -sf --cacert "$CA_CRT" "https://keycloak.$BASE_DOMAIN/realms/sandbox/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=admin \
    --data-urlencode "password=$(bao_kv_get platform/sso-users/admin password)" | jq -r .access_token)"
  curl -sf --cacert "$CA_CRT" -X "$m" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' "$@" \
    "https://keycloak.$BASE_DOMAIN/admin/realms/sandbox$p"
}
