#!/usr/bin/env bash
# Interactive helpers for the deployment course.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MCP_URL="https://mcp.$BASE_DOMAIN/mcp"
usage() {
  cat <<'HELP'
Usage: scripts/lab.sh COMMAND [ARGUMENTS]

  urls                            Print the sandbox service addresses and accounts
  token USER [inspector|portal|kagent]
                                  Issue an access token for an OAuth client
  claims [TOKEN]                  Decode a JWT from the argument or stdin
  mcp USER TOOL [MESSAGE]         Run a tool as the user
  delegate USER                   Exchange a token as mcp-agent
  agent-mcp USER TOOL              Run a tool for the user
  ask AGENT USER_OR_DASH TEXT      Send an A2A message
  role USER ROLE grant|revoke      Change a Keycloak role
  svid [NAMESPACE]                 Print the temporary pod's SPIRE JWT-SVID
  actors                          Show Substrate sessions
  model                           Show inference provider and model information
HELP
  exit "${1:-0}"
}

user_token() { # <user> <client>
  bao_connect >/dev/null 2>&1
  case "${2:-inspector}" in
    inspector) pkce_token "$1" mcp-inspector "https://inspector.$BASE_DOMAIN/oauth/callback" "openid mcp" ;;
    portal)    pkce_token "$1" agent-portal "https://kagent.$BASE_DOMAIN/delegation/callback" "openid delegation:client:mcp-agent" ;;
    kagent)    pkce_token "$1" kagent "https://kagent.$BASE_DOMAIN/oauth2/callback" "openid delegation:client:mcp-agent" confidential ;;
    *) die "unknown client '$2' (inspector, portal, kagent)" ;;
  esac
}

claims() {
  local jwt payload
  if [[ -n "${1:-}" ]]; then jwt=$1; else jwt=$(cat); fi
  payload=$(cut -d. -f2 <<< "$jwt" | tr '_-' '/+')
  local padding=$(( (4 - ${#payload} % 4) % 4 ))
  printf '%s%.*s' "$payload" "$padding" '===' | base64 --decode | jq .
}

# mcp_with_token <token> <tool> [message]: initialize an MCP session at Agent Router and call one tool; prints the HTTP
# status and the result (or the refusal).
mcp_with_token() {
  local tok=$1 tool=$2 msg=${3:-hello from the lab} H hdr sid out code
  H=(-s --max-time 20 --cacert "$CA_CRT" -H "Authorization: Bearer $tok" -H 'content-type: application/json'
     -H 'accept: application/json, text/event-stream' -H 'mcp-protocol-version: 2025-06-18')
  hdr="$(curl "${H[@]}" -D - -o /dev/null "$MCP_URL" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab","version":"1"}}}')"
  sid="$(grep -i '^mcp-session-id:' <<<"$hdr" | cut -d' ' -f2 | tr -d '\r')"
  [[ -n "$sid" ]] || { echo "initialize refused: $(head -1 <<<"$hdr")"; return 1; }
  H+=(-H "mcp-session-id: $sid")
  curl "${H[@]}" -o /dev/null "$MCP_URL" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  out="$(curl "${H[@]}" -w '\n%{http_code}' "$MCP_URL" -d "$(jq -nc --arg t "everything__$tool" --arg m "$msg" \
    '{jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: $t, arguments: {message: $m, a: 2, b: 3}}}')")"
  code="$(tail -1 <<<"$out")"
  echo "HTTP $code"
  sed '$d' <<<"$out" | sed -n 's/^data: //p; /^{/p' | head -c 1500; echo
}

ask() { # <agent> <user|-> <text>
  local agent=$1 user=$2 text=$3 tok=""
  [[ "$user" == - ]] || tok="$(user_token "$user" kagent)"
  port_forward kagent kagent-controller 18086 8083; sleep 2
  curl -s -m 240 "http://localhost:18086/agents/kagent/$agent" -H 'A2A-Version: 1.0' -H 'content-type: application/json' \
    ${tok:+-H "Authorization: Bearer $tok"} \
    -d "$(jq -nc --arg t "$text" '{jsonrpc: "2.0", id: 1, method: "SendMessage",
          params: {message: {messageId: ("lab-" + (now | tostring)), role: "ROLE_USER", parts: [{text: $t}]}}}')" |
    jq -r '[.result.task.artifacts[]?.parts[]?.text, .result.task.status.message.parts[]?.text, .error.message] | map(select(.)) | join("\n")'
}

svid() {
  local ns=${1:-lab-svid}
  kc create namespace "$ns" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n "$ns" delete pod svid --ignore-not-found >/dev/null
  kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: svid, namespace: $ns }
spec:
  restartPolicy: OnFailure
  containers:
    - name: fetch
      image: ghcr.io/spiffe/spire-agent:$(yq -r '.charts.spire.app' "$VERSIONS_FILE")
      command: ["/opt/spire/bin/spire-agent", "api", "fetch", "jwt", "-audience", "openbao", "-socketPath", "/spiffe-workload-api/spire-agent.sock", "-output", "json"]
      volumeMounts: [{ name: spiffe, mountPath: /spiffe-workload-api, readOnly: true }]
  volumes: [{ name: spiffe, csi: { driver: csi.spiffe.io, readOnly: true } }]
YAML
  wait_for "JWT-SVID" 180 bash -c "[[ \$(kubectl --context '$KUBE_CONTEXT' -n $ns get pod svid -o jsonpath='{.status.phase}') == Succeeded ]]" >&2
  kc -n "$ns" logs svid | jq -r '.. | .svid? // empty' | head -1
  kc -n "$ns" delete pod svid --wait=false >/dev/null 2>&1
  [[ "$ns" != lab-svid ]] || kc delete namespace "$ns" --wait=false >/dev/null 2>&1
}

cmd=${1:-help}; shift || true
case "$cmd" in
  urls)      exec "$ROOT/scripts/print-access.sh" --passwords ;;
  token)     [[ $# -ge 1 ]] || usage 2; user_token "$1" "${2:-inspector}" ;;
  claims)    claims "${1:-}" ;;
  mcp)       [[ $# -ge 2 ]] || usage 2; mcp_with_token "$(user_token "$1")" "$2" "${3:-}" ;;
  delegate)  [[ $# -ge 1 ]] || usage 2; bao_connect >/dev/null 2>&1; delegated_token "$1" ;;
  agent-mcp) [[ $# -ge 2 ]] || usage 2; bao_connect >/dev/null 2>&1; mcp_with_token "$(delegated_token "$1")" "$2" ;;
  ask)       [[ $# -ge 3 ]] || usage 2; ask "$1" "$2" "$3" ;;
  role)      [[ $# -ge 3 ]] || usage 2; bao_connect >/dev/null 2>&1
             uid="$(kc_admin GET "/users?username=$1&exact=true" | jq -r '.[0].id')"; r="$(kc_admin GET "/roles/$2")"
             case "$3" in grant) kc_admin POST "/users/$uid/role-mappings/realm" -d "[$r]" >/dev/null ;;
                           revoke) kc_admin DELETE "/users/$uid/role-mappings/realm" -d "[$r]" >/dev/null ;;
                           *) usage 2 ;; esac
             ok "$3 $2 for $1" ;;
  svid)      svid "${1:-}" ;;
  actors)    exec kubectl-ate get actors -A 2>/dev/null ;;
  model)     echo "MODEL_PROVIDER=$MODEL_PROVIDER"
             kc -n kagent get modelconfig default -o json | jq -c '.spec | {provider, model}'
             [[ "$MODEL_PROVIDER" != vllm ]] || kc -n models get deploy,inferencepool,pods ;;
  help|-h|--help) usage ;;
  *) usage 2 ;;
esac
