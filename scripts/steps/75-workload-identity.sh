#!/usr/bin/env bash
# STEP: workload-identity
# DESCRIPTION: Configure OpenBao login using SPIRE JWT workload identities
# REQUIRES: openbao argocd
# PROVIDES: SPIRE discovery trust and the read-only spiffe-demo role
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

issuer="https://oidc-discovery.$BASE_DOMAIN"
mount=spiffe-jwt
subject=spiffe://sandbox.local/ns/kcs-verify-l2/sa/default

in_profile() {
  case "$PROFILE" in
    identity|agents|delegation|full) return 0 ;;
    *) return 1 ;;
  esac
}

discovery_up() {
  curl -sf --cacert "$CA_CRT" "$issuer/.well-known/openid-configuration" |
    jq -e --arg issuer "$issuer" '.issuer == $issuer' >/dev/null
}

check() {
  if ! in_profile; then return 0; fi
  bao_connect || return
  bao_api GET "auth/$mount/config" 2>/dev/null |
    jq -e --arg issuer "$issuer" '.data.oidc_discovery_url == $issuer' >/dev/null || return
  bao_api GET "auth/$mount/role/spiffe-demo" >/dev/null 2>&1
}

apply() {
  if ! in_profile; then return 0; fi
  if [[ "$DRY_RUN" == 1 ]]; then
    log "dry-run: would configure auth/$mount for $issuer"
    return
  fi
  wait_for "SPIRE discovery at $issuer" 900 discovery_up || return
  bao_connect

  if ! bao_api GET sys/auth | jq -e --arg path "$mount/" '.data[$path]' >/dev/null; then
    printf '%s\n' '{"type":"jwt","description":"SPIRE JWT-SVIDs (trust domain sandbox.local)"}' |
      bao_api POST "sys/auth/$mount" >/dev/null
  fi
  jq -n --arg issuer "$issuer" --rawfile root "$CA_CRT" \
    '{oidc_discovery_url: $issuer, bound_issuer: $issuer, oidc_discovery_ca_pem: $root}' |
    bao_api POST "auth/$mount/config" >/dev/null
  jq -n '{policy: "path \"secret/data/platform/sandbox-ca-public\" { capabilities = [\"read\"] }\n"}' |
    bao_api POST sys/policies/acl/spiffe-demo >/dev/null
  jq -n --arg subject "$subject" \
    '{role_type:"jwt", user_claim:"sub", bound_subject:$subject, bound_audiences:["openbao"],
      token_policies:["spiffe-demo"], token_ttl:"10m"}' |
    bao_api POST "auth/$mount/role/spiffe-demo" >/dev/null
}

verify() {
  if ! in_profile; then
    ok "Skipped for PROFILE=$PROFILE"
  elif check; then
    ok "OpenBao trusts $issuer and has the spiffe-demo role"
  else
    warn "OpenBao auth/$mount configuration is incomplete"
    return 1
  fi
}

run_step check apply verify
