#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
#
# Compute the benchmark baseline from proven-bench JSON v1 run files and emit
# RFC 7493 (I-JSON) + RFC 8785 (JCS) canonical JSON.
#
# Usage: scripts/compute-bench-baseline.sh <run.json>... > benches/baseline.json
#
# Exit codes: 0 baseline written to stdout; 2 no baseline could be computed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || { echo "FAIL: cannot locate script directory" >&2; exit 2; }
MIN_RUNS=10

# die MESSAGE... — abort baseline generation with exit status 2.
die() {
  echo "compute-bench-baseline: $*" >&2
  echo "compute-bench-baseline: NO BASELINE WRITTEN." >&2
  exit 2
}

# run_id_of FILE — print the parent directory's name if it contains only digits;
# print nothing otherwise.
run_id_of() {
  local parent
  parent="$(basename "$(dirname "$1")")"
  if [[ "$parent" =~ ^[0-9]+$ ]]; then
    printf '%s' "$parent"
  fi
}

# validate_run FILE — require exactly one proven-bench v1 document, exiting 2 on
# missing, unparseable, or malformed input. Historical checksums are not validated.
validate_run() {
  local f="$1" errs
  [ -f "$f" ] || die "run file '$f' does not exist"
  if ! errs="$(jq -L "$SCRIPT_DIR" -sr 'include "bench-stats";
      if length != 1 then ["expected exactly one benchmark document"]
      else .[0] | bench_errors end | .[]' "$f")"; then
    die "run file '$f' is not parseable JSON"
  fi
  if [ -n "$errs" ]; then
    printf '%s\n' "$errs" | sed "s|^|  $f: |" >&2
    die "run file '$f' is not a well-formed proven-bench v1 document"
  fi
}

[ "$#" -ge 1 ] || die "usage: $0 <run.json>... (at least $MIN_RUNS)"
if [ "$#" -lt "$MIN_RUNS" ]; then
  die "BASELINE BOOTSTRAPPING: $#/$MIN_RUNS runs - the gate would be INERT; supply at least $MIN_RUNS"
fi

declare -A SEEN_PATHS=()
declare -A SEEN_RUN_IDS=()
ids_json='[]'
for f in "$@"; do
  validate_run "$f"
  canon_path="$(realpath "$f" 2>/dev/null || printf '%s' "$f")"
  if [ -n "${SEEN_PATHS[$canon_path]:-}" ]; then
    die "duplicate source run file '$f' - supply $MIN_RUNS distinct runs"
  fi
  SEEN_PATHS["$canon_path"]=1

  rid="$(run_id_of "$f")"
  if [ -n "$rid" ]; then
    if [ -n "${SEEN_RUN_IDS[$rid]:-}" ]; then
      die "duplicate source run_id '$rid' - supply $MIN_RUNS distinct runs"
    fi
    SEEN_RUN_IDS["$rid"]=1
  fi

  ids_json="$(jq -c --arg id "$rid" '. + [ if $id == "" then null else $id end ]' <<<"$ids_json")" \
    || die "could not record provenance for '$f'"
done

if ! jq -L "$SCRIPT_DIR" -s -e 'include "bench-stats";
      (map(iterations_map) | unique | length) == 1' "$@" >/dev/null; then
  die "the run files disagree on the workload set or iteration counts - they measure different experiments"
fi

RAW_JSON="$(jq -L "$SCRIPT_DIR" -cS -s --argjson ids "$ids_json" '
  include "bench-stats";
  (if length != ($ids | length) then error("expected one benchmark document per source file") else . end) as $runs
  | ($runs[0] | iterations_map) as $iters
  | ($runs | map(loo_ratios)) as $loo
  | ($runs | map(medians)) as $med
  | {
      schema_version: 1,
      kind: "proven-bench-baseline",
      bench_schema_version: 1,
      statistic: "leave-one-out ratio: a workload median divided by the geometric mean of the other workloads medians in the same run",
      method: "arithmetic mean over the source runs (taxonomy: mean of the last 10 CI runs on main)",
      note: "Manual tolerance override (taxonomy Part IV permits one with a stated reason): the checker fails at 2.0x the baseline ratio or 2.5x the baseline absolute median, not the taxonomy 1.5x, because 1.5x would have failed green runs on shared GitHub runners (max observed ratio 1.53x, absolute 1.65x). Measured numbers are in benchmarks/README.adoc and scripts/check-bench-regression.sh.",
      window: ($runs | length),
      sources: [ range(0; $runs | length) as $i
                 | { run_id: $ids[$i], commit: $runs[$i].commit } ],
      workloads: ( $iters | keys | map({
        key: .,
        value: {
          iterations: $iters[.],
          mean_median_ns: ([ $med[][.] ] | add / length),
          mean_loo_ratio: ([ $loo[][.] ] | add / length)
        } }) | from_entries )
    }
' "$@")" || die "jq failed while computing the baseline"

if command -v ijson-jcs >/dev/null 2>&1; then
  printf '%s' "$RAW_JSON" | ijson-jcs canon || die "ijson-jcs failed to canonicalize baseline"
  printf '\n'
elif command -v bun >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/ijson-jcs-cli.js" ]; then
  printf '%s' "$RAW_JSON" | bun "$SCRIPT_DIR/ijson-jcs-cli.js" canon || die "ijson-jcs-cli.js failed to canonicalize baseline"
  printf '\n'
else
  die "neither ijson-jcs nor bun is available to canonicalize baseline"
fi
