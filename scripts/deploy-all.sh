#!/usr/bin/env bash
#
# Plan or deploy all Nomad jobs in the jobs/ tree.
#
# Usage:
#   scripts/deploy-all.sh [plan|run] [-n NODE] [-m]
#
#   plan        Preview changes for every job (default; makes no changes).
#   run         Submit every job. Unchanged jobs are a no-op.
#
# Options:
#   -n, --node NODE   Only act on jobs under jobs/NODE/ (e.g. epyc, h4dos).
#   -m, --monitor     For 'run', wait for each deployment instead of -detach.
#   -h, --help        Show this help.
#
# Requires NOMAD_ADDR and NOMAD_TOKEN to be set (see docs/operations.md).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

action="plan"
node=""
monitor=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    plan|run) action="$1"; shift ;;
    -n|--node) node="${2:?--node requires a value}"; shift 2 ;;
    -m|--monitor) monitor=true; shift ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${NOMAD_ADDR:-}" || -z "${NOMAD_TOKEN:-}" ]]; then
  echo "ERROR: NOMAD_ADDR and NOMAD_TOKEN must be set (see docs/operations.md)." >&2
  exit 1
fi

glob="jobs/*/*.nomad.hcl"
[[ -n "$node" ]] && glob="jobs/${node}/*.nomad.hcl"

shopt -s nullglob
files=( $glob )
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No job files matched: $glob" >&2
  exit 1
fi

run_args=()
[[ "$action" == "run" && "$monitor" == false ]] && run_args=(-detach)

failed=()
changed=()

for f in "${files[@]}"; do
  echo "==> ${action} ${f}"
  if [[ "$action" == "plan" ]]; then
    # nomad job plan: 0 = no changes, 1 = changes present, >1 = error.
    set +e
    nomad job plan "$f"
    code=$?
    set -e
    case "$code" in
      0) ;;
      1) changed+=("$f") ;;
      *) failed+=("$f") ;;
    esac
  else
    if ! nomad job run "${run_args[@]}" "$f"; then
      failed+=("$f")
    fi
  fi
done

echo
echo "----- summary -----"
echo "processed: ${#files[@]} job(s)"
if [[ "$action" == "plan" ]]; then
  echo "with pending changes: ${#changed[@]}"
  for f in "${changed[@]:-}"; do [[ -n "$f" ]] && echo "  ~ $f"; done
fi
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED: ${#failed[@]}"
  for f in "${failed[@]}"; do echo "  ! $f"; done
  exit 1
fi
echo "ok"
