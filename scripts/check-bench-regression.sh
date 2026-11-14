#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
#
# Benchmark regression gate (ultraplan Phase 3b; ROADMAP 2a; DEBT I-1).
#
# Usage: scripts/check-bench-regression.sh <current.json> <baseline.json>
#
# Compares one proven-bench JSON v1 run against benchmarks/baseline.json and
# classifies each workload on the taxonomy's Six Sigma scale.
#
# WHY RATIOS, NOT NANOSECONDS
# ---------------------------
# CI runs on shared GitHub runners whose CPU class varies from run to run.
# Over 28 green main runs (2026-08-10 .. 2026-10-06) the same workload's
# absolute median ranged from 0.44x to 1.65x the baseline mean (a 3.8x
# spread); a gate on absolute time at the taxonomy's 50% would have failed
# green runs routinely, and a gate that fails randomly gets disabled. Much of
# that spread is common-mode — a slower machine slows every workload — so the
# primary statistic divides it out: each workload's median over the geometric
# mean of the OTHER workloads' medians in the same run (leave-one-out, see
# scripts/bench-stats.jq). Its spread over the same runs is 0.67x .. 1.51x.
# It does not vanish entirely, because runner classes do not slow every
# workload by the same factor (effectStackValid and ceremonyEndsProperly move
# together; relationTransitive and coveredCatAspect move together).
#
# THE TOLERANCES, AND HOW THEY WERE CHOSEN (manual override, stated)
# ------------------------------------------------------------------
# * LOO_FAIL = 2.0. Max observed leave-one-out ratio vs the baseline: 1.515
#   over 28 main runs (2nd highest 1.431), 1.527 over 27 branch/PR runs. The
#   taxonomy's 1.5x hard-fail would have failed green runs, so this departs
#   from it (taxonomy Part IV permits a manual override with a reason; this is
#   the reason). Margin: 2.0 / 1.527 = 1.31x. A 3x slowdown of one workload
#   is caught even on the most favourable observed runner (3 x 0.67 = 2.02).
# * ABS_FAIL = 2.5, on absolute median vs baseline mean. The ratio statistic
#   is BLIND to a uniform slowdown (every workload 3x slower leaves every ratio
#   at 1.0), so this backstop catches what ratios cannot. Max observed 1.65
#   (main) / 1.62 (branches); margin 2.5 / 1.65 = 1.52x. A uniform 3x
#   slowdown is caught; a uniform slowdown under 2.5x is NOT (stated blind
#   spot, recorded in TEST-NEEDS.adoc Gap C). Likewise a CORRELATED slowdown
#   of two of the four workloads partly hides itself: both 2.5x slower gives
#   each a ratio of 2.5 / 2.5^(1/3) = 1.84x, under LOO_FAIL.
# * EXTRA = 0.5 on the ratio: below it a workload is EXTRAORDINARY — passed,
#   but flagged for investigation (real improvement or measurement artefact).
#   Min observed 0.67.
# * There is no separate "Acceptable" (soft-fail, 20-50%) band: the measured
#   noise envelope already spans it, so a warning there would fire on green
#   runs and carry no information.
#
# Exit codes (check-toolchain-pins.sh convention):
#   0  every workload Ordinary or Extraordinary
#   1  at least one workload Unacceptable (named on stdout)
#   2  NO CHECK WAS PERFORMED: a file is missing or malformed, or the workload
#      sets / iteration counts disagree. A skip is not a pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || { echo "FAIL: cannot locate script directory" >&2; exit 2; }

LOO_FAIL=2.0
ABS_FAIL=2.5
EXTRA=0.5

# inert: report that no check was performed, and why, then exit 2.
inert() {
  echo "bench-regression: $*" >&2
  echo "bench-regression: NO CHECK WAS PERFORMED - a skip is not a pass." >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error title=Bench regression gate inert::$*"
  fi
  exit 2
}

# validate: refuse a file that is missing, unparseable, or ill-shaped. $1 is
# a label, $2 the path, $3 the bench-stats.jq error function to apply.
validate() {
  local label="$1" f="$2" fn="$3" errs
  [ -f "$f" ] || inert "$label '$f' does not exist"
  if ! errs="$(jq -L "$SCRIPT_DIR" -r "include \"bench-stats\"; ${fn}[]" "$f")"; then
    inert "$label '$f' is not parseable JSON"
  fi
  if [ -n "$errs" ]; then
    printf '%s\n' "$errs" | sed "s|^|  $label: |" >&2
    inert "$label '$f' is malformed"
  fi
}

[ "$#" -eq 2 ] || inert "usage: $0 <current.json> <baseline.json>"
CURRENT="$1"
BASELINE="$2"

validate "baseline" "$BASELINE" baseline_errors
validate "current run" "$CURRENT" bench_errors
validate "current run" "$CURRENT" checksum_errors

# A workload present on only one side is not a pass: either the bench lost a
# workload (nothing measured it) or the baseline is for a different workload
# set (nothing to compare it to). Same for a changed iteration count, which
# redefines the workload (Benchmark.idr: workloads are FROZEN).
mismatch="$(jq -L "$SCRIPT_DIR" -r --slurpfile b "$BASELINE" '
  include "bench-stats";
  ($b[0].workloads) as $base
  | iterations_map as $cur
  | ( [ $base | keys[] | select($cur[.] == null) | "MISSING from current run: \(.)" ]
    + [ $cur  | keys[] | select($base[.] == null) | "MISSING from baseline: \(.)" ]
    + [ $cur | to_entries[] | select($base[.key] != null and $base[.key].iterations != .value)
        | "iterations changed for \(.key): baseline \($base[.key].iterations), current \(.value) - cut a new baseline" ]
    )[]
' "$CURRENT")" || inert "jq failed while comparing workload sets"
if [ -n "$mismatch" ]; then
  printf '%s\n' "$mismatch" | sed 's/^/bench-regression: /'
  inert "the current run and the baseline do not measure the same workloads"
fi

# One line per workload: name, ratio-vs-baseline, absolute-vs-baseline, class.
verdicts="$(jq -L "$SCRIPT_DIR" -r --slurpfile b "$BASELINE" \
    --argjson loo_fail "$LOO_FAIL" --argjson abs_fail "$ABS_FAIL" --argjson extra "$EXTRA" '
  include "bench-stats";
  ($b[0].workloads) as $base
  | loo_ratios as $loo
  | medians as $med
  | $base | keys[]
  | . as $n
  | ($loo[$n] / $base[$n].mean_loo_ratio) as $rx
  | ($med[$n] / $base[$n].mean_median_ns) as $ax
  | [ $n,
      ($rx * 1000 | round / 1000 | tostring),
      ($ax * 1000 | round / 1000 | tostring),
      (if $rx > $loo_fail or $ax > $abs_fail then "UNACCEPTABLE"
       elif $rx < $extra then "EXTRAORDINARY"
       else "ORDINARY" end) ]
  | @tsv
' "$CURRENT")" || inert "jq failed while classifying workloads"
[ -n "$verdicts" ] || inert "classification produced no verdicts"

echo "bench-regression: $(basename "$CURRENT") vs $(basename "$BASELINE")"
echo "bench-regression: fail if ratio > ${LOO_FAIL}x baseline ratio, or absolute > ${ABS_FAIL}x baseline mean"
regressed=()
while IFS=$'\t' read -r name rx ax class; do
  printf '  %-22s ratio %6sx  absolute %6sx  %s\n' "$name" "$rx" "$ax" "$class"
  case "$class" in
    UNACCEPTABLE)
      regressed+=("$name")
      if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::error title=Benchmark regression::$name is Unacceptable: ratio ${rx}x (limit ${LOO_FAIL}x), absolute ${ax}x (limit ${ABS_FAIL}x)"
      fi ;;
    EXTRAORDINARY)
      echo "    ^ Extraordinary: real improvement or measurement artefact? Re-cut the baseline only if confirmed." ;;
  esac
done <<<"$verdicts"

if [ "${#regressed[@]}" -gt 0 ]; then
  echo "bench-regression: FAIL - Unacceptable regression in: ${regressed[*]}"
  exit 1
fi
echo "bench-regression: OK - no workload regressed beyond tolerance"
