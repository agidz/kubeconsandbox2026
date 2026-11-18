#!/usr/bin/env bash
# STEP: sso
# DESCRIPTION: Enable Keycloak-backed login in the bootstrap services
# REQUIRES: openbao harbor argocd
# PROVIDES: Keycloak SSO for Gitea, Harbor and OpenBao; group sandbox-admins = admin in all three
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Argo CD, Gitea and Grafana get SSO from their Helm values (Git). Harbor and OpenBao keep auth settings in their own
# storage, configurable only through their APIs, so bootstrap does it once Argo CD has brought Keycloak up (L2).
ISSUER="https://keycloak.$BASE_DOMAIN/realms/sandbox"
in_profile() { [[ "$PROFILE" =~ ^(identity|agents|delegation|full)$ ]]; }
keycloak_up() { curl -sf --cacert "$CA_CRT" "$ISSUER/.well-known/openid-configuration" >/dev/null; }

# Gitea (layer 0) can't have its Keycloak source in Helm values: the chart registers it in an init container that
# fetches Keycloak's discovery document, which fails before layer 2 exists. Registered here with Gitea's CLI instead
# (stored in Gitea's database); Gitea loads OAuth sources at start, so the pod restarts once afterwards.
gitea_cli() { kc -n gitea exec -i deploy/gitea -c gitea -- "$@"; }
gitea_ok()  { gitea_cli gitea admin auth list 2>/dev/null | awk 'NR > 1 {print $2}' | grep -qx keycloak; }
gitea_sso() {
  local id verb=add-oauth idarg=""
  id="$(gitea_cli gitea admin auth list 2>/dev/null | awk 'NR > 1 && $2 == "keycloak" {print $1}')"
  [[ -n "$id" ]] && { verb=update-oauth; idarg="--id $id"; }
  # The client secret goes in on stdin, never on a command line.
  bao_kv_get platform/oidc/gitea clientSecret | gitea_cli sh -c 'read -r S; exec gitea admin auth '"$verb $idarg"' --name keycloak \
    --provider openidConnect --key gitea --secret "$S" --auto-discover-url "$1" \
    --scopes openid --scopes profile --scopes email --group-claim-name groups --admin-group sandbox-admins' _ \
    "$ISSUER/.well-known/openid-configuration" >/dev/null
  if [[ "$verb" == add-oauth ]]; then
    kc -n gitea delete pod -l app.kubernetes.io/name=gitea --wait=false >/dev/null
    wait_rollout gitea deploy/gitea 300s >/dev/null
  fi
  ok "Gitea: OIDC login via Keycloak (sandbox-admins = Gitea site admins)"
}

harbor_ok()  { [[ "$(hb_api GET /configurations | jq -r '.auth_mode.value')" == oidc_auth ]]; }
openbao_ok() { bao_api GET sys/auth | jq -e '.data["oidc/"]' >/dev/null && bao_api GET auth/oidc/role/sandbox >/dev/null 2>&1; }

check() {
  in_profile || return 0
  bao_connect && hb_connect && harbor_ok && openbao_ok && gitea_ok
}

harbor() {
  # Harbor only allows switching auth mode while no local users besides admin exist (robot accounts are fine). The local
  # admin keeps working at /account/sign-in as a break-glass login.
  jq -n --arg ep "$ISSUER" --arg s "$(bao_kv_get platform/oidc/harbor clientSecret)" '{
    auth_mode: "oidc_auth", oidc_name: "Keycloak", oidc_endpoint: $ep, oidc_client_id: "harbor", oidc_client_secret: $s,
    oidc_scope: "openid,profile,email", oidc_groups_claim: "groups", oidc_admin_group: "sandbox-admins",
    oidc_user_claim: "email", oidc_auto_onboard: true, oidc_verify_cert: true}' | hb_api PUT /configurations >/dev/null
  ok "Harbor: OIDC login via Keycloak (sandbox-admins = Harbor system admins; username = email)"
}

openbao() {
  bao_api GET sys/auth | jq -e '.data["oidc/"]' >/dev/null ||
    echo '{"type":"oidc","description":"Keycloak realm sandbox"}' | bao_api POST sys/auth/oidc >/dev/null
  jq -n --arg u "$ISSUER" --rawfile ca "$CA_CRT" --arg s "$(bao_kv_get platform/oidc/openbao clientSecret)" \
    '{oidc_discovery_url: $u, oidc_discovery_ca_pem: $ca, oidc_client_id: "openbao", oidc_client_secret: $s, default_role: "sandbox"}' |
    bao_api POST auth/oidc/config >/dev/null
  jq -n --arg ui "https://openbao.$BASE_DOMAIN/ui/vault/auth/oidc/oidc/callback" '{
    user_claim: "preferred_username", groups_claim: "groups", oidc_scopes: ["openid", "profile", "email"],
    allowed_redirect_uris: [$ui, "http://localhost:8250/oidc/callback"], token_policies: ["default"], token_ttl: "8h"}' |
    bao_api POST auth/oidc/role/sandbox >/dev/null
  # Groups from Keycloak → OpenBao policies (external identity groups bound to the oidc mount).
  jq -n '{policy: "path \"*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\", \"patch\"] }\n"}' |
    bao_api POST sys/policies/acl/sandbox-admin >/dev/null
  jq -n '{policy: "path \"secret/metadata/*\" { capabilities = [\"list\"] }\npath \"sys/mounts\" { capabilities = [\"read\"] }\n"}' |
    bao_api POST sys/policies/acl/sandbox-viewer >/dev/null
  local accessor g policy id
  accessor="$(bao_api GET sys/auth | jq -r '.data["oidc/"].accessor')"
  for g in sandbox-admins:sandbox-admin sandbox-viewers:sandbox-viewer; do
    policy="${g#*:}"; g="${g%%:*}"
    id="$(jq -n --arg n "$g" --arg p "$policy" '{name: $n, type: "external", policies: [$p]}' | bao_api POST identity/group | jq -r '.data.id // empty')"
    [[ -n "$id" ]] || id="$(bao_api GET "identity/group/name/$g" | jq -r .data.id)"
    bao_api GET "identity/group/id/$id" | jq -e '.data.alias.name // empty' >/dev/null ||
      jq -n --arg n "$g" --arg a "$accessor" --arg c "$id" '{name: $n, mount_accessor: $a, canonical_id: $c}' |
        bao_api POST identity/group-alias >/dev/null
  done
  ok "OpenBao: OIDC login via Keycloak (sandbox-admins → full admin, sandbox-viewers → list secret names)"
}

apply() {
  if ! in_profile; then
    log "PROFILE=$PROFILE skips identity integration"
    return
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    log 'dry-run: would provision Keycloak settings in the bootstrap services'
    return
  fi
  wait_for 'Keycloak discovery for the sandbox realm' 900 keycloak_up || return
  bao_connect
  hb_connect
  gitea_sso
  harbor
  openbao
}

verify() {
  if ! in_profile; then
    ok "Skipped for PROFILE=$PROFILE"
    return
  fi
  bao_connect && hb_connect || return
  if ! gitea_ok; then warn 'Missing Keycloak source in Gitea'; return 1; fi
  if ! harbor_ok; then warn 'Harbor is not using OIDC'; return 1; fi
  if ! openbao_ok; then warn 'Missing the sandbox OIDC role in OpenBao'; return 1; fi
  ok 'Gitea, Harbor, and OpenBao use the Keycloak realm'
}

run_step check apply verify
