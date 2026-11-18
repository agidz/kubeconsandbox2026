#!/usr/bin/env bash
# STEP: mirror-charts
# DESCRIPTION: Publish the pinned chart releases to Harbor
# REQUIRES: harbor
# PROVIDES: OCI charts under the Harbor charts project
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REGISTRY="$HARBOR_HOST:$HB_PORT"

charts() {
  yq -r '.charts | to_entries[] | [.key, .value.version, .value.repo] | join(" ")' "$VERSIONS_FILE"
}

missing() {
  local entries name version upstream
  entries=$(charts) || return
  while read -r name version upstream; do
    [[ -n "$name" ]] || continue
    if ! hb_api GET "/projects/charts/repositories/$name/artifacts/$version" >/dev/null 2>&1; then
      printf '%s %s %s\n' "$name" "$version" "$upstream"
    fi
  done <<< "$entries"
}

check() {
  local absent
  bao_connect && hb_connect || return
  absent=$(missing) || return
  [[ -z "$absent" ]]
}

apply() {
  bao_connect
  hb_connect
  local staging name version upstream absent
  absent=$(missing)
  if [[ -z "$absent" ]]; then
    ok 'Harbor already has every pinned chart'
    return
  fi
  staging=$(mktemp -d)
  export HELM_REGISTRY_CONFIG="$staging/registry.json"
  trap "rm -rf -- $(printf '%q' "$staging"); _kcs_pf_stop" EXIT
  if [[ "$DRY_RUN" != 1 ]]; then
    printf '%s' "$(bao_kv_get platform/harbor adminPassword)" |
      helm registry login "$REGISTRY" -u admin --password-stdin --ca-file "$CA_CRT" >/dev/null
  fi

  while read -r name version upstream; do
    if [[ "$upstream" == oci://* ]]; then
      run helm pull "$upstream/$name" --version "$version" --destination "$staging"
    else
      run helm pull "$name" --repo "$upstream" --version "$version" --destination "$staging"
    fi
    run helm push "$staging/$name-$version.tgz" "oci://$REGISTRY/charts" --ca-file "$CA_CRT"
    if [[ "$DRY_RUN" != 1 ]]; then ok "Published $name $version"; fi
  done <<< "$absent"
}

verify() {
  local absent
  bao_connect && hb_connect || return
  absent=$(missing) || return
  if [[ -n "$absent" ]]; then
    warn "Harbor is missing: $(awk '{printf "%s:%s ", $1, $2}' <<< "$absent")"
    return 1
  fi
  ok "Harbor has $(charts | awk '{printf "%s:%s ", $1, $2}')"
}

run_step check apply verify
