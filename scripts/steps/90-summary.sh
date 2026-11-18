#!/usr/bin/env bash
# STEP: summary
# DESCRIPTION: Show completion markers, cluster access, and certificate trust commands
# REQUIRES:
# PROVIDES: Deployment information
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

check() { return 1; }
verify() { return 0; }

apply() {
  local file name timestamp endpoint host
  printf '\n%s%-14s %-9s %s%s\n' "$C_BLD" STEP STATUS FINISHED "$C_RST"
  for file in "$ROOT"/scripts/steps/[0-9][0-9]-*.sh; do
    name=$(sed -n '/^# STEP: */{s///;p;q;}' "$file")
    if [[ "$name" == summary ]]; then continue; fi
    timestamp=
    if [[ -f "$STATE_DIR/steps/$name.done" ]]; then
      timestamp=$(sed -n 's/^finished=//p' "$STATE_DIR/steps/$name.done")
    fi
    printf '%-14s %-9s %s\n' "$name" "$(step_status "$name")" "$timestamp"
  done

  printf '\n'
  if cluster_reachable; then
    endpoint=$(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    log "$CLUSTER_NAME is reachable as $KUBE_CONTEXT at $endpoint"
    printf '  kubectl --context %q get nodes\n' "$KUBE_CONTEXT"
  else
    warn "Kubernetes context $KUBE_CONTEXT is unavailable"
  fi

  if kc -n envoy-gateway-system get gateway sandbox >/dev/null 2>&1; then
    printf '\nSign-in details are available from scripts/print-access.sh --passwords\n'
    for host in argocd git harbor openbao grafana jaeger prometheus keycloak kagent; do
      printf '  https://%s.%s\n' "$host" "$BASE_DOMAIN"
    done
  fi

  if [[ ! -s "$CA_CRT" ]]; then return 0; fi
  local linux_ca=/usr/local/share/ca-certificates/kubeconsandbox-root-ca.crt
  printf '\nCertificate trust for *.%s\n' "$BASE_DOMAIN"
  if cmp -s "$CA_CRT" "$linux_ca"; then
    printf '%s\n' '  Linux already trusts this CA.'
  else
    printf '%s\n' '  For this shell: eval "$(scripts/ca-env.sh)"' \
      '  Clear shell trust: eval "$(scripts/ca-env.sh --unset)"'
    printf '  Install on Linux: sudo install -m 0644 %q %q && sudo update-ca-certificates\n' "$CA_CRT" "$linux_ca"
  fi
  if grep -qi microsoft /proc/version && have wslpath; then
    printf "  Import in Windows PowerShell: Import-Certificate -FilePath '%s' -CertStoreLocation Cert:\\CurrentUser\\Root\n" \
      "$(wslpath -w "$CA_CRT")"
  fi
}

run_step check apply verify
