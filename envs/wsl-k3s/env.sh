# shellcheck shell=bash
# Reserved for k3s. The implemented provider contract lives in wsl-kind/env.sh.
KUBE_CONTEXT=$CLUSTER_NAME
ENV_TOOLS=curl
ENV_TESTED=no
HARBOR_CLUSTER_IP=10.43.200.10
export KUBE_CONTEXT ENV_TOOLS ENV_TESTED HARBOR_CLUSTER_IP

env_preflight() {
  die "The k3s provider for ENV=$ENV is unavailable. Use ENV=wsl-kind."
}

cluster_exists() { return 1; }
node_mirrors_ok() { return 1; }

cluster_create() { env_preflight; }
cluster_delete() { env_preflight; }
cluster_dns_apply() { env_preflight; }
node_mirrors_apply() { env_preflight; }
