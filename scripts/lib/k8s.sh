# shellcheck shell=bash
# Always address the context selected by the provider.

kc() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}
hlm() {
  helm --kube-context "$KUBE_CONTEXT" "$@"
}
cluster_reachable() {
  kc get --raw /readyz >/dev/null 2>&1
}
ensure_ns() {
  if ! kc get namespace "$1" >/dev/null 2>&1; then
    run kubectl --context "$KUBE_CONTEXT" create namespace "$1"
  fi
}

helm_upsert() {
  local release=$1 namespace=$2 chart=$3 version=$4
  shift 4
  local command=(helm --kube-context "$KUBE_CONTEXT" upgrade --install "$release" "$chart"
    --namespace "$namespace" --version "$version" --create-namespace --wait --timeout 10m --history-max 3 "$@")
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    run "${command[@]}"
  else
    "${command[@]}" >/dev/null && ok "Helm installed $namespace/$release from $chart $version"
  fi
}

wait_rollout() {
  local namespace=$1 workload=$2 timeout=${3:-300s}
  run kubectl --context "$KUBE_CONTEXT" --namespace "$namespace" rollout status "$workload" --timeout "$timeout"
}

dns_rewrites() {
  local domain_pattern=${BASE_DOMAIN//./\\.}
  printf 'exact harbor.%s harbor.harbor.svc.cluster.local\n' "$BASE_DOMAIN"
  # Trailing-dot anchor prevents matching names expanded through search domains.
  printf 'regex ^(.*)\\.%s\\.$ sandbox-gateway.envoy-gateway-system.svc.cluster.local\n' "$domain_pattern"
}

apply_secret() {
  local namespace=$1 name=$2 type=$3
  shift 3
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    printf '%s  [dry-run] apply Secret %s/%s (%s)%s\n' "$C_DIM" "$namespace" "$name" "$type" "$C_RST"
    return
  fi
  kc -n "$namespace" create secret "$type" "$name" "$@" --dry-run=client -o yaml |
    kc apply -f - >/dev/null
}

_kcs_pf_pids=()
port_forward() {
  local namespace=$1 service=$2 listen_port=$3 service_port=$4
  local pod port target
  pod=$(kc -n "$namespace" get endpointslices -l "kubernetes.io/service-name=$service" \
    -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.targetRef.name}{"\n"}{end}' 2>/dev/null | head -1)
  port=$(kc -n "$namespace" get service "$service" -o json 2>/dev/null |
    jq -r --argjson port "$service_port" '[.spec.ports[] | select(.port == $port) | (.targetPort // .port)][0] // empty')
  if [[ -n "$pod" && -n "$port" ]]; then
    target="pod/$pod"
  else
    target="svc/$service"
    port=$service_port
  fi
  kubectl --context "$KUBE_CONTEXT" -n "$namespace" port-forward "$target" "$listen_port:$port" >/dev/null 2>&1 &
  _kcs_pf_pids+=("$!")
  trap '_kcs_pf_stop' EXIT
}

_kcs_pf_stop() {
  local process
  for process in "${_kcs_pf_pids[@]}"; do
    kill "$process" 2>/dev/null || true
  done
  _kcs_pf_pids=()
}
