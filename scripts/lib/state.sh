# shellcheck shell=bash
# A completed step records the dependency manifest it used.

export STATE_DIR="$ROOT/.state"
mkdir -p "$STATE_DIR"/{steps,logs}

_versions_hash() {
  local digest
  digest=$(sha256sum "$ROOT/versions.yaml" 2>/dev/null) || return
  printf '%.16s\n' "$digest"
}

step_mark_done() {
  local prefix="$STATE_DIR/steps/$1"
  rm -f "$prefix.failed"
  {
    printf 'finished=%s\n' "$(date -Is)"
    printf 'versions=%s\n' "$(_versions_hash)"
    printf 'env=%s\n' "$ENV"
  } > "$prefix.done"
}

step_mark_failed() {
  date -Is > "$STATE_DIR/steps/$1.failed"
}

step_reset() {
  rm -f "$STATE_DIR/steps/$1."{done,failed}
}

step_is_done() {
  [[ -f "$STATE_DIR/steps/$1.done" ]]
}

step_status() {
  local prefix="$STATE_DIR/steps/$1"
  local status=pending
  if step_is_done "$1"; then
    status=outdated
    if grep -Fxq "versions=$(_versions_hash)" "$prefix.done"; then
      status=done
    fi
  elif [[ -f "$prefix.failed" ]]; then
    status=failed
  fi
  printf '%s\n' "$status"
}
