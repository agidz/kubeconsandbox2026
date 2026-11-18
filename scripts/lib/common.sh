# shellcheck shell=bash
if [[ -n "${_KCS_COMMON_LOADED:-}" ]]; then return 0; fi
_KCS_COMMON_LOADED=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export ROOT

C_RED='' C_GRN='' C_YEL='' C_BLU='' C_DIM='' C_BLD='' C_RST=''
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_BLU=$'\e[34m'
  C_DIM=$'\e[2m' C_BLD=$'\e[1m' C_RST=$'\e[0m'
fi

log() {
  printf '%s[%(%H:%M:%S)T]%s %s\n' "$C_BLU" -1 "$C_RST" "$*"
}
ok() {
  printf '%s  ✓ %s%s\n' "$C_GRN" "$*" "$C_RST"
}
warn() {
  printf '%s  ! %s%s\n' "$C_YEL" "$*" "$C_RST" >&2
}
die() {
  printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RST" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

run() {
  if [[ "${DRY_RUN:-0}" != 1 ]]; then
    "$@"
  else
    printf '%s  [dry-run] %s%s\n' "$C_DIM" "$*" "$C_RST"
  fi
}

retry() {
  local remaining=$1 delay=$2
  shift 2
  while ((remaining > 0)); do
    if "$@"; then return 0; fi
    remaining=$((remaining - 1))
    if ((remaining > 0)); then sleep "$delay"; fi
  done
  return 1
}

wait_for() {
  local description=$1 timeout=$2 began=$SECONDS
  shift 2
  while ! "$@" >/dev/null 2>&1; do
    if ((SECONDS - began >= timeout)); then
      warn "Timed out after ${timeout}s waiting for $description"
      return 1
    fi
    sleep 3
  done
  ok "$description ($((SECONDS - began))s)"
}

step_field() {
  sed -n "/^# $1: */{s///;p;q;}" "$STEP_FILE"
}

run_step() {
  local check=$1 apply=$2 verify=$3 dependency
  for dependency in $(step_field REQUIRES); do
    if step_is_done "$dependency"; then continue; fi
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
      warn "dry-run: assuming '$dependency' completes"
    else
      die "$STEP_NAME requires '$dependency'. Run ./bootstrap.sh --only $dependency"
    fi
  done

  if [[ "${VERBOSE:-0}" == 1 ]]; then set -x; fi
  if [[ "${FORCE:-0}" != 1 ]] && "$check"; then
    ok "$STEP_NAME is already applied"
  else
    "$apply"
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    log 'dry-run: verification and marker updates skipped'
    return 0
  fi
  if ! "$verify"; then
    step_mark_failed "$STEP_NAME"
    die "$STEP_NAME verification failed"
  fi
  step_mark_done "$STEP_NAME"
  ok "$STEP_NAME done"
}

caller=${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}
caller_path="$(cd "$(dirname "$caller")" && pwd)/${caller##*/}"
case "$caller_path" in
  "$ROOT"/scripts/steps/*)
    STEP_FILE=$caller_path
    STEP_NAME=$(step_field STEP)
    export STEP_FILE STEP_NAME
    ;;
esac
unset caller caller_path

source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/state.sh"
source "$ROOT/scripts/lib/ca.sh"
source "$ROOT/scripts/lib/k8s.sh"
source "$ROOT/scripts/lib/openbao.sh"
source "$ROOT/scripts/lib/harbor.sh"
source "$ROOT/scripts/lib/gitea.sh"
source "$ROOT/scripts/lib/sso.sh"
source "$ROOT/scripts/lib/models.sh"
source "$ROOT/scripts/lib/argo.sh"
