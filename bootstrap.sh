#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'HELP'
Usage: ./bootstrap.sh [options]

  --list              List the steps and their current status
  --only STEPS        Run the named steps
  --from STEP         Begin at STEP
  --to STEP           End after STEP
  --skip STEPS        Omit the named steps
  --force STEPS       Apply these steps even when their checks pass
  --dry-run           Preview the selected steps
  --env ENV           Choose a cluster provider
  --profile PROFILE   Choose how much of the platform to deploy
  --verbose           Trace shell commands within each step
  -h, --help          Show this help

Identify a step by name or two-digit number. STEPS is a comma-separated list.
See config.env.example for settings and .state/logs for step output.
HELP
}

declare -A options=()
show_list=0
while (($#)); do
  option=$1
  shift
  case "$option" in
    -h|--help) usage; exit 0 ;;
    --list) show_list=1 ;;
    --dry-run) export DRY_RUN=1 ;;
    --verbose) export VERBOSE=1 ;;
    --only|--from|--to|--skip|--force|--env|--profile)
      if [[ -z "${1:-}" || "$1" == --* ]]; then
        printf 'Missing value for %s\n' "$option" >&2
        exit 2
      fi
      options[$option]=$1
      shift
      ;;
    *) printf 'Unknown option: %s\n' "$option" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ -v 'options[--env]' ]]; then export ENV="${options[--env]}"; fi
if [[ -v 'options[--profile]' ]]; then export PROFILE="${options[--profile]}"; fi

source "$ROOT/scripts/lib/common.sh"

shopt -s nullglob
files=("$ROOT"/scripts/steps/[0-9][0-9]-*.sh)
shopt -u nullglob
(("${#files[@]}")) || die 'No bootstrap steps found'

declare -a names=() numbers=() descriptions=()
declare -A index_by_ref=()
for index in "${!files[@]}"; do
  file=${files[index]}
  filename=${file##*/}
  number=${filename%%-*}
  name=$(sed -n '/^# STEP: */{s///;p;q;}' "$file")
  [[ -n "$name" ]] || die "No step name in $filename"
  descriptions[index]=$(sed -n '/^# DESCRIPTION: */{s///;p;q;}' "$file")
  numbers[index]=$number
  names[index]=$name
  index_by_ref[$name]=$index
  index_by_ref[$number]=$index
done

if ((show_list)); then
  printf '%s%-4s %-14s %-9s %s%s\n' "$C_BLD" NUM STEP STATUS DESCRIPTION "$C_RST"
  for index in "${!files[@]}"; do
    printf '%-4s %-14s %-9s %s\n' "${numbers[index]}" "${names[index]}" \
      "$(step_status "${names[index]}")" "${descriptions[index]}"
  done
  exit 0
fi

declare -A include=() omit=() reapply=()
start=0
end=$(("${#files[@]}" - 1))
for option in --only --skip --force --from --to; do
  value=${options[$option]:-}
  [[ -n "$value" ]] || continue
  case "$option" in
    --from|--to) references=("$value") ;;
    *) IFS=, read -ra references <<< "$value" ;;
  esac
  for ref in "${references[@]}"; do
    [[ -n "$ref" && -n "${index_by_ref[$ref]+set}" ]] ||
      die "Unknown step '$ref'. See ./bootstrap.sh --list."
    index=${index_by_ref[$ref]}
    case "$option" in
      --only) include[$index]=1 ;;
      --skip) omit[$index]=1 ;;
      --force) reapply[$index]=1 ;;
      --from) start=$index ;;
      --to) end=$index ;;
    esac
  done
done

selected=()
for ((index = start; index <= end; index++)); do
  if [[ -v 'options[--only]' && ! -v 'include[$index]' ]]; then continue; fi
  if [[ -v 'omit[$index]' ]]; then continue; fi
  selected+=("$index")
done
(("${#selected[@]}")) || die 'No steps matched the requested filters'

mode=
if [[ "$DRY_RUN" == 1 ]]; then mode=' (dry-run)'; fi
log "Bootstrap for ENV=$ENV PROFILE=$PROFILE$mode"
declare -a elapsed=()
for position in "${!selected[@]}"; do
  index=${selected[position]}
  name=${names[index]}
  logfile="$STATE_DIR/logs/${numbers[index]}-$name.log"
  printf '\n%s[%d/%d] %s: %s%s\n' "$C_BLD" "$((position + 1))" "${#selected[@]}" \
    "$name" "${descriptions[index]}" "$C_RST"
  started=$SECONDS
  if FORCE=${reapply[$index]:-0} bash "${files[index]}" 2>&1 | tee "$logfile"; then
    elapsed[index]=$((SECONDS - started))
  else
    statuses=("${PIPESTATUS[@]}")
    result=${statuses[0]}
    if ((result == 0)); then result=${statuses[1]}; fi
    printf '\n%sStep %s exited with status %d. Log: %s%s\n' \
      "$C_RED" "$name" "$result" "${logfile#"$ROOT"/}" "$C_RST" >&2
    if [[ -f "$logfile" ]]; then tail -n 20 "$logfile" >&2; fi
    printf 'Resume with ./bootstrap.sh --from %s\n' "$name" >&2
    exit "$result"
  fi
done

printf '\n%s%-14s %-7s %s%s\n' "$C_BLD" STEP RESULT TIME "$C_RST"
for index in "${selected[@]}"; do
  printf '%-14s %-7s %ss\n' "${names[index]}" ok "${elapsed[index]}"
done
