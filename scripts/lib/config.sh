# shellcheck shell=bash
export PATH="$ROOT/bin:$PATH"

# Parse assignments without evaluating shell code. Preexisting variables win.
if [[ -f "$ROOT/config.env" ]]; then
  while IFS= read -r config_line || [[ -n "$config_line" ]]; do
    config_line=${config_line%%#*}
    if [[ ! "$config_line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then continue; fi
    config_key=${BASH_REMATCH[1]}
    if [[ -v $config_key ]]; then continue; fi
    config_value=${BASH_REMATCH[2]}
    config_value=${config_value%"${config_value##*[![:space:]]}"}
    config_value=${config_value#\"}
    config_value=${config_value%\"}
    config_value=${config_value#\'}
    config_value=${config_value%\'}
    export "$config_key=$config_value"
  done < "$ROOT/config.env"
  unset config_line config_key config_value
fi

export ENV="${ENV:-wsl-kind}" PROFILE="${PROFILE:-delegation}" CLUSTER_NAME="${CLUSTER_NAME:-kubeconsandbox}"
export REPO_URL="${REPO_URL:-}" REPO_REVISION="${REPO_REVISION:-main}" BASE_DOMAIN="${BASE_DOMAIN:-localtest.me}"
export MODEL_PROVIDER="${MODEL_PROVIDER:-vllm}" MODEL_NAME="${MODEL_NAME:-claude-sonnet-5-5}" MODEL_API_KEY="${MODEL_API_KEY:-}"
export VLLM_MODEL="${VLLM_MODEL:-}" VLLM_MODEL_REVISION="${VLLM_MODEL_REVISION:-}"
export VLLM_REPLICAS="${VLLM_REPLICAS:-1}" VLLM_MAX_TOKENS="${VLLM_MAX_TOKENS:-8192}"
export DRY_RUN="${DRY_RUN:-0}" VERBOSE="${VERBOSE:-0}" FORCE="${FORCE:-0}"

case "$PROFILE" in
  bootstrap|platform|identity|agents|delegation|full) ;;
  *) die "Unknown profile '$PROFILE'. Choose bootstrap, platform, identity, agents, delegation, or full." ;;
esac

export ENV_DIR="$ROOT/envs/$ENV"
[[ -f "$ENV_DIR/env.sh" ]] || die "No provider script at $ENV_DIR/env.sh"
source "$ENV_DIR/env.sh"
export VERSIONS_FILE="$ROOT/versions.yaml"

ver() {
  local path=$1 pin
  have yq || die 'Install the pinned tools with scripts/install-tools.sh to use yq.'
  pin=$(yq -r "$path // \"\"" "$VERSIONS_FILE") || return
  [[ -n "$pin" ]] || die "No dependency pin at $path in versions.yaml"
  printf '%s\n' "$pin"
}
