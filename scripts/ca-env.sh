#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
certificate="$root/.state/ca/sandbox-root-ca.crt"
bundle="$root/.state/ca/bundle.pem"
bundle_vars=(SSL_CERT_FILE CURL_CA_BUNDLE GIT_SSL_CAINFO REQUESTS_CA_BUNDLE)

if [[ "${1:-}" == --unset ]]; then
  printf 'unset %s NODE_EXTRA_CA_CERTS\n' "${bundle_vars[*]}"
  exit 0
fi

if [[ ! -s "$certificate" ]]; then
  printf '%s\n' "echo 'Run ./bootstrap.sh --only ca to create the sandbox CA' >&2"
  exit 1
fi

system_bundle=
for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  if [[ -s "$candidate" ]]; then
    system_bundle=$candidate
    break
  fi
done
if [[ -z "$system_bundle" ]]; then
  printf '%s\n' "echo 'System CA bundle unavailable' >&2"
  exit 1
fi

if [[ ! -s "$bundle" || "$system_bundle" -nt "$bundle" || "$certificate" -nt "$bundle" ]]; then
  temporary=$(mktemp "$bundle.XXXXXX")
  trap 'rm -f -- "$temporary"' EXIT
  cat "$system_bundle" "$certificate" > "$temporary"
  mv -f -- "$temporary" "$bundle"
fi

for name in "${bundle_vars[@]}"; do
  printf 'export %s=%q\n' "$name" "$bundle"
done
printf 'export NODE_EXTRA_CA_CERTS=%q\n' "$certificate"
printf '%s\n' "echo 'Sandbox CA loaded. To clear it, evaluate the output of scripts/ca-env.sh --unset.' >&2"
