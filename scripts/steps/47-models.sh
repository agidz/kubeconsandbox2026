#!/usr/bin/env bash
# STEP: models
# DESCRIPTION: Verify the selected vLLM weights and publish them as an OCI artifact
# REQUIRES: harbor
# PROVIDES: The model artifact in Harbor for vLLM image volumes
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

registry="$HARBOR_HOST:$HB_PORT"

check() {
  if [[ "$MODEL_PROVIDER" != vllm ]]; then return 0; fi
  bao_connect && hb_connect || return
  local_model
  hb_api GET "/projects/models/repositories/$LM_NAME/artifacts/${LM_REV:0:12}" >/dev/null 2>&1
}

apply() {
  if [[ "$MODEL_PROVIDER" != vllm ]]; then return 0; fi
  bao_connect
  hb_connect
  local_model
  local tag=${LM_REV:0:12} cache="$STATE_DIR/models/$LM_NAME"
  local staging artifact="models/$LM_NAME:$tag"
  if hb_api GET "/projects/models/repositories/$LM_NAME/artifacts/$tag" >/dev/null 2>&1; then
    return 0
  fi
  log "Preparing $LM_HF@$tag with cache $cache"
  if [[ "$DRY_RUN" == 1 ]]; then return 0; fi

  staging=$(mktemp -d)
  trap "rm -rf -- $(printf '%q' "$staging"); _kcs_pf_stop" EXIT
  printf '%s' "$(bao_kv_get platform/harbor adminPassword)" |
    oras login "$registry" -u admin --password-stdin --ca-file "$CA_CRT" --registry-config "$staging/auth.json" >/dev/null
  python3 -I "$ROOT/scripts/lib/model_oci.py" "$LM_HF" "$LM_REV" "$cache" "$tag"
  oras cp --from-oci-layout "$cache/layout:$tag" "$registry/$artifact" \
    --to-ca-file "$CA_CRT" --to-registry-config "$staging/auth.json" >/dev/null
  rm -rf "$cache/layout"
  ok "Published $artifact"
}

verify() {
  if [[ "$MODEL_PROVIDER" != vllm ]]; then
    ok "Skipped for MODEL_PROVIDER=$MODEL_PROVIDER"
  elif check; then
    ok "Harbor has models/$LM_NAME:${LM_REV:0:12}"
  else
    warn 'The selected model is unavailable in Harbor'
    return 1
  fi
}

run_step check apply verify
