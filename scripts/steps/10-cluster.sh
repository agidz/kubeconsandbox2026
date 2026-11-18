#!/usr/bin/env bash
# STEP: cluster
# DESCRIPTION: Provision the selected cluster provider and verify Kubernetes and DNS
# REQUIRES: preflight
# PROVIDES: A Ready cluster with the certificates APIs and sandbox DNS rewrites
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

dns_ok() {
  local corefile mode name target
  corefile=$(kc -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null) || return
  while read -r mode name target; do
    if ! grep -Fq "name $mode $name " <<< "$corefile"; then return 1; fi
  done < <(dns_rewrites)
}

check() {
  cluster_exists && cluster_reachable && dns_ok
}

apply() {
  if ! cluster_exists; then
    log "Provisioning $CLUSTER_NAME through $ENV"
    cluster_create
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    log 'dry-run: would configure CoreDNS'
  else
    wait_for 'Kubernetes API available' 120 cluster_reachable || return
    cluster_dns_apply
  fi
}

verify() {
  wait_for 'Kubernetes API available' 120 cluster_reachable || return
  wait_for 'Nodes Ready' 180 kc wait node --all --for=condition=Ready --timeout=5s || return

  local version expected resources resource missing=0 issuer
  version=$(kc version -o json | jq -r .serverVersion.gitVersion) || return
  expected=$(ver .cluster.kubernetes)
  ok "$KUBE_CONTEXT runs Kubernetes $version"
  if [[ "$version" != "$expected"* ]]; then warn "Expected Kubernetes $expected from versions.yaml"; fi

  resources=$(kc api-resources --api-group=certificates.k8s.io -o name) || return
  for resource in podcertificaterequests clustertrustbundles; do
    if grep -Fxq "$resource.certificates.k8s.io" <<< "$resources"; then
      ok "Kubernetes serves $resource"
    else
      warn "Substrate requires $resource.certificates.k8s.io"
      missing=1
    fi
  done
  if ((missing)); then return 1; fi
  if ! dns_ok; then warn 'CoreDNS rewrites are missing'; return 1; fi
  ok 'CoreDNS serves the sandbox names'

  issuer=$(kc get --raw /.well-known/openid-configuration | jq -r .issuer) || return
  if [[ "$issuer" == https://kubernetes.default.svc.cluster.local ]]; then
    ok "Service account issuer: $issuer"
  else
    warn "An environment overlay must configure ate-api-authentication for $issuer"
  fi
}

run_step check apply verify
