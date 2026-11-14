# SPDX-License-Identifier: MPL-2.0
#
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
#
# Shared statistics for the benchmark regression gate.
#
# ONE definition, included (`jq -L scripts 'include "bench-stats"; ...'`) by
# both scripts/compute-bench-baseline.sh and scripts/check-bench-regression.sh,
# so the baseline and the check cannot drift into computing different
# statistics. Inputs are proven-bench JSON v1 documents as written by
# `proven-bench --json` (benchmarks/Benchmark.idr, `runJSON`).

# bench_errors: the list of shape errors in a proven-bench v1 run document.
# An empty list means the document is usable. Shape is checked, not merely
# presence: `log` of a zero or negative median is silently -inf/nan in jq, so
# a median that is not a positive number must be refused here.
def bench_errors:
  if type != "object" then ["not a JSON object"]
  else
    [ (if .schema_version != 1
         then "schema_version is \(.schema_version | tojson), expected 1" else empty end),
      (if .suite != "proven-bench"
         then "suite is \(.suite | tojson), expected \"proven-bench\"" else empty end),
      (if (.results | type) != "array" or (.results | length) < 3
         then "results must be an array of at least 3 workloads (each ratio needs >= 2 others)"
         else empty end)
    ]
    + (if (.results | type) == "array" then
         [ .results[]
           | if type != "object" then "a result is not a JSON object"
             elif (.name | type) != "string" or .name == "" then "a result has no name"
             elif (.median_ns | type) != "number" or .median_ns <= 0
               then "\(.name): median_ns \(.median_ns | tojson) is not a positive number"
             elif (.iterations | type) != "number" or .iterations <= 0
               then "\(.name): iterations \(.iterations | tojson) is not a positive number"
             else empty end ]
         + ([ .results[] | .name? | select(type == "string") ]
            | group_by(.) | map(select(length > 1) | "duplicate workload name \(.[0] | tojson)"))
       else [] end)
  end;

# checksum_errors: one error per workload whose checksum is not true. Applied
# to the CURRENT run only. It is deliberately not part of bench_errors, which
# also vets baseline inputs: before 2026-10-06 (#85) the checksum was an XOR
# parity that read False on every run whatever the predicates did, so the
# historical artifacts a baseline is cut from carry a checksum that means
# nothing. Since #85 the bench asserts it and exits non-zero itself; this is
# the second line of defence for a JSON that reached the gate anyway.
def checksum_errors:
  [ .results[]
    | select(.checksum != true)
    | "\(.name): checksum is \(.checksum | tojson) - the workload is broken, its timing measures nothing" ];

# medians: {workload name: median_ns} for a valid run document.
def medians: .results | map({key: .name, value: .median_ns}) | from_entries;

# iterations_map: {workload name: iterations} for a valid run document.
def iterations_map: .results | map({key: .name, value: .iterations}) | from_entries;

# loo_ratios: {workload name: leave-one-out ratio} for a valid run document.
# Each workload's median divided by the GEOMETRIC mean of the medians of every
# OTHER workload in the same run. Leaving the workload itself out of its own
# denominator means a regression in workload W raises only W's ratio (and
# lowers the others'), so a slowdown can only ever be blamed on the workload
# that slowed down.
def loo_ratios:
  medians as $m
  | ($m | keys) as $ks
  | reduce $ks[] as $k ({};
      .[$k] = $m[$k] / ([ $ks[] | select(. != $k) | $m[.] | log ] | add / length | exp));

# baseline_errors: the list of shape errors in a baseline document written by
# scripts/compute-bench-baseline.sh. An empty list means it is usable.
def baseline_errors:
  if type != "object" then ["not a JSON object"]
  else
    [ (if .kind != "proven-bench-baseline"
         then "kind is \(.kind | tojson), expected \"proven-bench-baseline\"" else empty end),
      (if .schema_version != 1
         then "schema_version is \(.schema_version | tojson), expected 1" else empty end),
      (if (.workloads | type) != "object" or (.workloads | length) < 3
         then "workloads must be an object holding at least 3 workloads" else empty end)
    ]
    + (if (.workloads | type) == "object" then
         [ .workloads | to_entries[]
           | .key as $n | .value
           | if type != "object" then "\($n): entry is not a JSON object"
             elif (.mean_median_ns | type) != "number" or .mean_median_ns <= 0
               then "\($n): mean_median_ns \(.mean_median_ns | tojson) is not a positive number"
             elif (.mean_loo_ratio | type) != "number" or .mean_loo_ratio <= 0
               then "\($n): mean_loo_ratio \(.mean_loo_ratio | tojson) is not a positive number"
             elif (.iterations | type) != "number" or .iterations <= 0
               then "\($n): iterations \(.iterations | tojson) is not a positive number"
             else empty end ]
       else [] end)
  end;
