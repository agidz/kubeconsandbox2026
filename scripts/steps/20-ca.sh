#!/usr/bin/env bash
# STEP: ca
# DESCRIPTION: Provision the root certificate authority and install its cluster and node trust
# REQUIRES: cluster
# PROVIDES: Node registry trust and the cert-manager root CA Secret
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NODE_CA="$STATE_DIR/node/certs.d/sandbox-ca.crt"

node_ok() {
  cmp -s "$CA_CRT" "$NODE_CA"
}

secret_ok() {
  local installed local_certificate
  installed=$(kc -n cert-manager get secret sandbox-root-ca -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d) || return
  local_certificate=$(cat "$CA_CRT" 2>/dev/null) || return
  [[ "$installed" == "$local_certificate" ]]
}

check() {
  ca_exists && node_ok && secret_ok
}

apply() {
  if ca_exists; then
    ok "Reusing $CA_CRT"
  else
    log 'Generating the sandbox root CA'
    ca_create
    if [[ "$DRY_RUN" == 1 ]]; then
      log 'dry-run: would establish node trust and create the cert-manager Secret'
      return
    fi
  fi
  run mkdir -p "${NODE_CA%/*}"
  run install -m 0644 "$CA_CRT" "$NODE_CA"
  ensure_ns cert-manager
  apply_secret cert-manager sandbox-root-ca tls --cert="$CA_CRT" --key="$CA_KEY"
}

verify() {
  if ! ca_exists; then
    warn "The root CA is missing or expires within 30 days: $CA_CRT"
    return 1
  fi
  ok "Root CA $(openssl x509 -in "$CA_CRT" -noout -enddate)"
  if ! node_ok; then warn "Node trust differs from $CA_CRT"; return 1; fi
  if ! secret_ok; then warn 'The cert-manager CA Secret is missing or stale'; return 1; fi
  ok 'Node and cert-manager trust the sandbox root'
}

run_step check apply verify
