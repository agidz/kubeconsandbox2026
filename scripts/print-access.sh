#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

show_passwords=0
if [[ "${1:-}" == --passwords ]]; then show_passwords=1; fi
bao_connect >/dev/null 2>&1 || die 'Cannot connect to OpenBao'

credential() {
  if ((show_passwords)); then
    bao_kv_get "$1" "$2"
  else
    printf '%s' '(pass --passwords to display)'
  fi
}
row() { printf '  %-20s %-42s %s\n' "$@"; }

printf '%sKeycloak accounts for the sandbox realm%s\n' "$C_BLD" "$C_RST"
row admin "$(credential platform/sso-users/admin password)" 'Platform operator'
row alice "$(credential platform/sso-users/alice password)" 'Demo administrator'
row bob "$(credential platform/sso-users/bob password)" 'Demo viewer'

printf '\n%sService URLs and login methods%s\n' "$C_BLD" "$C_RST"
row 'Argo CD' "https://argocd.$BASE_DOMAIN" "Keycloak or admin / $(credential platform/argocd adminPassword)"
row Gitea "https://git.$BASE_DOMAIN" "Keycloak or $ADMIN / $(credential platform/gitea adminPassword)"
row Harbor "https://harbor.$BASE_DOMAIN" "Keycloak or admin at /account/sign-in / $(credential platform/harbor adminPassword)"
row Grafana "https://grafana.$BASE_DOMAIN" "Keycloak or admin / $(credential platform/grafana adminPassword)"
if ((show_passwords)); then operator=$(bao_token); else operator='(pass --passwords to display)'; fi
row OpenBao "https://openbao.$BASE_DOMAIN" "OIDC role sandbox, CLI operator token (15 min): $operator"
row Jaeger "https://jaeger.$BASE_DOMAIN" 'Gateway SSO'
row Prometheus "https://prometheus.$BASE_DOMAIN" 'Gateway SSO'
row kagent "https://kagent.$BASE_DOMAIN" 'Gateway SSO with delegation consent'
row 'MCP Inspector' "https://inspector.$BASE_DOMAIN" 'sandbox-admins via gateway SSO, everything preconfigured'
row 'MCP (Agent Router)' "https://mcp.$BASE_DOMAIN/mcp" 'mcp-inspector OAuth client with PKCE. Bob can call echo and get-sum.'
row Keycloak "https://keycloak.$BASE_DOMAIN/admin/sandbox/console" 'Realm admin. Master account is in keycloak-initial-admin.'
printf '\nImport the CA for browser access. Use scripts/ca-env.sh for shell trust.\n'
