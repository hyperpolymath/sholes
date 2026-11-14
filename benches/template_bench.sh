#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Template Benchmarks (proven-tests-and-benches JSON v1 compatible)
#
# Usage:
#   benches/template_bench.sh [--json | --csv] [REPO_ROOT]
#   benches/template_bench.sh [REPO_ROOT] [human | json | csv]
#
# Exit contract (proven-tests-and-benches 3-outcome convention):
#   0 = all workloads succeeded (checksum == true for every workload)
#   1 = one or more benchmarked workloads failed (a broken workload is never timed as clean)
#   2 = setup error (missing repo root or required benchmark script)
set -euo pipefail

OUTPUT_FORMAT="human"
REPO_ROOT="."

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) OUTPUT_FORMAT="json"; shift ;;
    --csv) OUTPUT_FORMAT="csv"; shift ;;
    human|json|csv) OUTPUT_FORMAT="$1"; shift ;;
    *) REPO_ROOT="$1"; shift ;;
  esac
done

[ -d "$REPO_ROOT" ] || { echo "template_bench: repo root '$REPO_ROOT' does not exist" >&2; exit 2; }
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

for req in \
  "$REPO_ROOT/scripts/check-root-shape.sh" \
  "$REPO_ROOT/scripts/check-ijson-jcs.sh" \
  "$REPO_ROOT/scripts/check-required-contexts.sh" \
  "$REPO_ROOT/scripts/check-escape-hatches.sh"
do
  [ -f "$req" ] || { echo "template_bench: required workload script missing: $req" >&2; exit 2; }
done

# Print a message only in human output mode.
log_human() {
  if [ "$OUTPUT_FORMAT" = "human" ]; then
    printf '%s\n' "$*"
  fi
}

# median_of <n1> <n2> ... -> integer median on stdout
# Requires at least one integer sample; for even counts, truncate the average
# of the two middle samples toward zero.
median_of() {
  local sorted count mid
  mapfile -t sorted < <(printf '%s\n' "$@" | sort -n)
  count="${#sorted[@]}"
  mid=$(( count / 2 ))
  if [ $(( count % 2 )) -eq 1 ]; then
    printf '%s' "${sorted[$mid]}"
  else
    printf '%s' $(( (sorted[mid - 1] + sorted[mid]) / 2 ))
  fi
}

declare -A MEDIAN_NS
declare -A ITERS
declare -A CHECKSUM
WORKLOADS=(escape_hatches ijson_jcs required_contexts root_shape)
ANY_FAILED=0

# run_workload NAME ITERATIONS COMMAND... — run one warm-up and ITERATIONS timed
# samples, recording median nanoseconds, iterations, and checksum by NAME.
# Any failed invocation sets ANY_FAILED and a false checksum; sampling continues.
run_workload() {
  local name="$1" iterations="$2"
  shift 2
  local samples=() ok="true" i start end elapsed

  # Warm-up run
  if ! "$@" >/dev/null 2>&1; then
    ok="false"
    ANY_FAILED=1
  fi

  for i in $(seq 1 "$iterations"); do
    start="$(date +%s%N)"
    if ! "$@" >/dev/null 2>&1; then
      ok="false"
      ANY_FAILED=1
    fi
    end="$(date +%s%N)"
    elapsed=$(( end - start ))
    [ "$elapsed" -gt 0 ] || elapsed=1
    samples+=("$elapsed")
    log_human "  [$name] sample $i/$iterations: $(( elapsed / 1000000 )) ms"
  done

  MEDIAN_NS["$name"]="$(median_of "${samples[@]}")"
  ITERS["$name"]="$iterations"
  CHECKSUM["$name"]="$ok"
}

log_human "Template Benchmarks (proven-bench v1)"
log_human "====================================="

run_workload escape_hatches 5 bash "$REPO_ROOT/scripts/check-escape-hatches.sh" \
  "$REPO_ROOT/src" "$REPO_ROOT/verification" "$REPO_ROOT/.machine_readable/coaptation"
# Clear any caller-supplied IJSON_JCS binary override so the benchmark always
# measures the same deterministic JS RFC 7493/8785 workload calibrated in
# benches/baseline.json (production gates still honour IJSON_JCS on PATH).
run_workload ijson_jcs 5 env -u IJSON_JCS IJSON_JCS_FORCE_JS=1 bash "$REPO_ROOT/scripts/check-ijson-jcs.sh" --enforce "$REPO_ROOT"
run_workload required_contexts 5 bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$REPO_ROOT"
run_workload root_shape 5 bash "$REPO_ROOT/scripts/check-root-shape.sh" "$REPO_ROOT"

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"

if [ "$OUTPUT_FORMAT" = "json" ]; then
  # Emit strict RFC 7493 / RFC 8785 (JCS) JSON v1 document for proven-bench tools.
  printf '{"commit":"%s","results":[' "$COMMIT_SHA"
  first=1
  for w in "${WORKLOADS[@]}"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"checksum":%s,"iterations":%d,"median_ns":%d,"name":"%s"}' \
      "${CHECKSUM[$w]}" "${ITERS[$w]}" "${MEDIAN_NS[$w]}" "$w"
  done
  printf '],"schema_version":1,"suite":"proven-bench"}\n'
elif [ "$OUTPUT_FORMAT" = "csv" ]; then
  printf 'workload,iterations,median_ns,checksum\n'
  for w in "${WORKLOADS[@]}"; do
    printf '%s,%d,%d,%s\n' "$w" "${ITERS[$w]}" "${MEDIAN_NS[$w]}" "${CHECKSUM[$w]}"
  done
else
  log_human ""
  for w in "${WORKLOADS[@]}"; do
    printf '  %-20s %8d ms (median of %d, checksum=%s)\n' \
      "$w" "$(( MEDIAN_NS[$w] / 1000000 ))" "${ITERS[$w]}" "${CHECKSUM[$w]}"
  done
fi

[ "$ANY_FAILED" -eq 0 ] || exit 1
exit 0
