#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if cluster_exists; then
  log "Removing $CLUSTER_NAME from $ENV"
  cluster_delete
else
  ok "Cluster $CLUSTER_NAME is absent from $ENV"
fi

case "${1:-}" in
  --all)
    run rm -rf "$STATE_DIR"
    ;;
  *)
    # The cached token belongs to the deleted OpenBao instance.
    run rm -f "$STATE_DIR"/steps/* "$STATE_DIR/openbao/operator-token"
    ;;
esac

ok "Teardown finished"
