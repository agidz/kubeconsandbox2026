#!/usr/bin/env bash
# STEP: preflight
# DESCRIPTION: Check host readiness and reconcile pinned command-line tools
# REQUIRES:
# PROVIDES: ./bin tools at pinned versions, a host that can run the chosen ENV
# IDEMPOTENT: yes
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

HOST_TOOLS="jq openssl git curl"

pinned_ok() {
  local entries name version
  have yq || return
  entries=$(yq -r '.tools | to_entries[] | [.key, .value.version] | join(" ")' "$VERSIONS_FILE") || return
  [[ -n "$entries" ]] || return 1
  for name in kubectl helm yq; do
    [[ -x "$ROOT/bin/$name" ]] || return 1
  done
  while read -r name version; do
    if [[ ! -x "$ROOT/bin/$name" ]] || ! grep -Fxq "$name $version" "$ROOT/bin/.versions" 2>/dev/null; then
      return 1
    fi
  done <<< "$entries"
}

check() { pinned_ok; }

apply() {
  run "$ROOT/scripts/install-tools.sh"
}

verify() {
  local t fail=0
  log "ENV=$ENV PROFILE=$PROFILE CLUSTER_NAME=$CLUSTER_NAME context=$KUBE_CONTEXT"
  [[ "$ENV_TESTED" == yes ]] || warn "ENV=$ENV is untested (plan §9)"

  for t in $HOST_TOOLS; do have "$t" || { warn "missing host tool: $t (install it with your package manager)"; fail=1; }; done
  pinned_ok || { warn "pinned tools in ./bin don't match versions.yaml: run scripts/install-tools.sh"; fail=1; }
  for t in $ENV_TOOLS; do have "$t" || { warn "ENV=$ENV needs '$t' on PATH"; fail=1; }; done
  python3 -c 'import bcrypt' 2>/dev/null || { warn "python3 with the bcrypt module is needed (Ubuntu: sudo apt install python3-bcrypt)"; fail=1; }
  ((fail == 0)) || return 1
  ok "tools: $HOST_TOOLS, python3-bcrypt, pinned $(cd "$ROOT/bin" && echo *)"
  env_preflight || return 1

  # Resources (plan §5.1). The host matters for WSL as a whole; env_preflight checks the Docker VM for kind.
  local mem_gb cpus disk_gb
  mem_gb=$(awk '/MemTotal/ { printf "%d", $2 / 1024 / 1024 }' /proc/meminfo)
  cpus=$(nproc)
  disk_gb=$(df -Pk "$ROOT" | awk 'NR == 2 { printf "%d", $4 / 1024 / 1024 }')
  ((mem_gb < 12)) && { warn "host RAM ${mem_gb} GiB < 12 GiB minimum"; return 1; }
  ((mem_gb < 16)) && warn "host RAM ${mem_gb} GiB; 16 GiB+ recommended"
  ((disk_gb < 60)) && warn "free disk ${disk_gb} GiB at $ROOT; 60 GiB+ recommended (images, Harbor, model weights)"
  ok "host: ${mem_gb} GiB RAM, ${cpus} CPUs, ${disk_gb} GiB free disk"
  # The local model (MODEL_PROVIDER=vllm) comes on top of the ~14 GiB the other layers use (docs/model-sizing.md).
  if [[ "$MODEL_PROVIDER" == vllm && "$PROFILE" =~ ^(agents|delegation|full)$ ]]; then
    local_model
    local per=$((LM_GIB + LM_KV_GIB + 3 + LM_GIB / 8)) need
    need=$((14 + VLLM_REPLICAS * per))
    if ((mem_gb < need)); then
      warn "MODEL_PROVIDER=vllm: ${VLLM_REPLICAS} × ${LM_NAME} needs ~${per} GiB each, ~${need} GiB with the rest; host has ${mem_gb} GiB. Use a smaller VLLM_MODEL, MODEL_PROVIDER=stub, or anthropic"
    else
      ok "local model fits: ${VLLM_REPLICAS} × ${LM_NAME} (~${per} GiB each) + ~14 GiB for the other layers ≤ ${mem_gb} GiB"
    fi
  fi

  # Host ports 80/443 are where kind (or ServiceLB) publishes the gateway. Only a problem before the cluster exists.
  if ! cluster_exists; then
    for p in 80 443; do
      if ss -Hltn "sport = :$p" 2>/dev/null | grep -q .; then warn "port $p is already in use on this host"; return 1; fi
    done
    ok "ports 80/443 free"
  else
    ok "cluster '$CLUSTER_NAME' already exists (port check skipped)"
  fi

  if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
    [[ "$ENV" == *gpu* ]] || log "GPU detected ($(nvidia-smi -L | head -1 | cut -c1-60)); not used by ENV=$ENV (the GPU layer is optional)"
  fi

  case "$PROFILE" in agents | delegation | full)
    case "$MODEL_PROVIDER" in
      anthropic) [[ -n "$MODEL_API_KEY" ]] || warn "MODEL_PROVIDER=anthropic and MODEL_API_KEY is empty: model calls will return 401 (set a key, or MODEL_PROVIDER=stub|vllm)" ;;
      stub) log "MODEL_PROVIDER=stub: agents answer from the scripted stub model (no key needed)" ;;
      vllm) local_model; log "MODEL_PROVIDER=vllm: $LM_HF@${LM_REV:0:12} served as \"$LM_NAME\" by vLLM on CPU (step 47-models pushes it to Harbor)" ;;
    esac ;;
  esac
  return 0
}

run_step check apply verify
