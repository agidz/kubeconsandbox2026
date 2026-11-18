# shellcheck shell=bash
ARGO_GIT_URL=${REPO_URL:-http://gitea-http.gitea.svc:3000/sandbox/kubeconsandbox.git}

root_values() {
  local remote=false model_details='{}'
  if [[ -n "$REPO_URL" ]]; then remote=true; fi
  if [[ "$MODEL_PROVIDER" == vllm ]]; then
    local_model
    model_details=$(jq -n \
      --arg name "$LM_NAME" --arg hf "$LM_HF" --arg revision "$LM_REV" \
      --arg replicas "$VLLM_REPLICAS" --arg weightsGiB "$LM_GIB" \
      --arg kvCacheGiB "$LM_KV_GIB" --arg maxTokens "$VLLM_MAX_TOKENS" \
      '{ $name, $hf, $revision, replicas: ($replicas|tonumber),
         weightsGiB: ($weightsGiB|tonumber), kvCacheGiB: ($kvCacheGiB|tonumber),
         maxTokens: ($maxTokens|tonumber) }') || return
  fi
  jq -n --arg env "$ENV" --arg profile "$PROFILE" \
    --arg repoURL "$ARGO_GIT_URL" --arg repoRevision "$REPO_REVISION" \
    --arg baseDomain "$BASE_DOMAIN" --arg modelName "$MODEL_NAME" \
    --arg modelProvider "$MODEL_PROVIDER" --argjson localModel "$model_details" \
    --arg chartRegistry "$HARBOR_HOST/charts" --argjson remoteRepo "$remote" \
    --rawfile sandboxCA "$CA_CRT" \
    '{ $env, $profile, $repoURL, $repoRevision, $baseDomain, $modelName,
       $modelProvider, $localModel, $chartRegistry, $remoteRepo, $sandboxCA }' |
    yq -P
}

rendered_app_values() {
  local application=$1 output=$2 values
  values=$(root_values) || return
  helm template root "$ROOT/argocd/root" --values "$VERSIONS_FILE" --values <(printf '%s\n' "$values") |
    APPLICATION="$application" yq 'select(.kind == "Application" and .metadata.name == strenv(APPLICATION)) | .spec.sources[0].helm.valuesObject // {}' > "$output"
}
