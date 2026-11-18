# shellcheck shell=bash
case "$MODEL_PROVIDER" in
  stub|anthropic|vllm) ;;
  *) die "Unknown model provider '$MODEL_PROVIDER'. Choose stub, anthropic, or vllm." ;;
esac
for model_setting in VLLM_REPLICAS VLLM_MAX_TOKENS; do
  [[ "${!model_setting}" =~ ^[1-9][0-9]*$ ]] || die "$model_setting must be a positive integer"
done
unset model_setting

local_model() {
  if [[ -n "${LM_REV:-}" ]]; then return 0; fi
  local default_repo repo revision record weights_record kv_record estimate
  default_repo=$(ver .models.vllmDefault.hf) || return
  repo=${VLLM_MODEL:-$default_repo}
  repo=${repo#https://huggingface.co/}
  repo=${repo%/}
  revision=$VLLM_MODEL_REVISION
  if [[ "$repo" == */tree/* ]]; then
    revision=${revision:-${repo#*/tree/}}
    repo=${repo%%/tree/*}
  fi
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die 'VLLM_MODEL must be a Hugging Face model ID or model URL'
  LM_HF=$repo
  LM_NAME=${repo##*/}
  LM_NAME=${LM_NAME,,}

  record="$STATE_DIR/models/$LM_NAME/revision"
  if [[ -z "$revision" && "$repo" == "$default_repo" ]]; then
    revision=$(ver .models.vllmDefault.revision) || return
  elif [[ -z "$revision" && -s "$record" ]]; then
    revision=$(cat "$record") || return
  fi
  if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    revision=$(curl -fsSL "https://huggingface.co/api/models/$repo/revision/${revision:-main}" |
      jq -er '.sha | strings') || die "Cannot resolve $repo at ${VLLM_MODEL_REVISION:-main}"
  fi
  mkdir -p "${record%/*}" || return
  printf '%s\n' "$revision" > "$record" || return

  weights_record="${record%/*}/size-$revision"
  if [[ ! -s "$weights_record" ]]; then
    estimate=$(curl -fsSL "https://huggingface.co/api/models/$repo/tree/$revision" |
      jq '[.[] | select(.path | test("\\.(safetensors|bin)$")) | .size] | add / 1073741824 | ceil') ||
      die "Cannot estimate the weight size of $repo@$revision"
    printf '%s\n' "$estimate" > "$weights_record" || return
  fi
  LM_GIB=$(cat "$weights_record") || return

  kv_record="${record%/*}/kv-$revision-$VLLM_MAX_TOKENS"
  if [[ ! -s "$kv_record" ]]; then
    estimate=$(curl -fsSL "https://huggingface.co/$repo/resolve/$revision/config.json" |
      jq --argjson tokens "$VLLM_MAX_TOKENS" '
        (.text_config // .) as $model
        | ($model.head_dim // ($model.hidden_size / $model.num_attention_heads)) as $head
        | ($model.num_key_value_heads // $model.num_attention_heads) as $heads
        | [1, ($model.num_hidden_layers * $heads * $head * 4 * $tokens * 1.25 / 1073741824 | ceil)] | max
      ') || die "Cannot estimate KV cache for $repo@$revision"
    printf '%s\n' "$estimate" > "$kv_record" || return
  fi
  LM_KV_GIB=$(cat "$kv_record") || return
  LM_REV=$revision
}
