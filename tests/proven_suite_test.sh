#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing + Setup-error test suite for the proven-tests-and-benches
# toolchain wired in scripts/:
#   - scripts/check-escape-hatches.sh
#   - scripts/compute-bench-baseline.sh
#   - scripts/check-bench-regression.sh
#   - scripts/emit-aggregate-inputs.sh
#
# Every negative fixture is generated ephemerally in $WORK (mktemp -d) so no
# static escape-hatch token ever resides in a tracked .idr file.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

assert_rc() { # assert_rc <wanted-rc> <label> <cmd...>
  local want="$1" label="$2" got=0
  shift 2
  "$@" >"$WORK/out" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1))
    echo "  PASS: $label"
  else
    fail=$((fail + 1))
    echo "  FAIL: $label (wanted exit $want, got $got)"
    sed 's/^/        /' "$WORK/out"
  fi
}

assert_grep() { # assert_grep <pattern> <label>
  if grep -qE -- "$1" "$WORK/out"; then
    pass=$((pass + 1))
    echo "  PASS: $2"
  else
    fail=$((fail + 1))
    echo "  FAIL: $2 (missing pattern: $1)"
    sed 's/^/        /' "$WORK/out"
  fi
}

echo "=== 1. check-escape-hatches.sh: Silence, Firing, Setup (0 / 1 / 2) ==="
mkdir -p "$WORK/clean" "$WORK/empty"
cat > "$WORK/clean/Sound.idr" <<'IDR'
module Sound

%default total

public export
reflNat : (n : Nat) -> n = n
reflNat _ = Refl
IDR

assert_rc 0 "Silence: total Idris2 module passes" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/clean"

assert_rc 2 "Setup (exit 2): missing directory is never a pass" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/no-such-dir"

assert_rc 2 "Setup (exit 2): directory with 0 .idr files is never a pass" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/empty"

# Build banned tokens dynamically so scanners never confuse test generators with source
BM="believe""_me"
AT="assert""_total"

mkdir -p "$WORK/m_bm"
printf 'module Bad\n\n%%default total\n\nbad : a -> b\nbad x = %s x\n' "$BM" > "$WORK/m_bm/Bad.idr"
assert_rc 1 "Firing: believe-me escape hatch exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_bm"

mkdir -p "$WORK/m_at"
printf 'module Bad\n\n%%default total\n\nbad : Nat -> Nat\nbad n = %s (bad n)\n' "$AT" > "$WORK/m_at/Bad.idr"
assert_rc 1 "Firing: assert-total escape hatch exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_at"

mkdir -p "$WORK/m_hole"
printf 'module Bad\n\n%%default total\n\nbad : Nat\nbad = ?unproven_hole\n' > "$WORK/m_hole/Bad.idr"
assert_rc 1 "Firing: ?hole syntax exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_hole"

mkdir -p "$WORK/m_partial"
printf 'module Bad\n\n%%default total\n\npartial\nloop : Nat -> Nat\nloop n = loop n\n' > "$WORK/m_partial/Bad.idr"
assert_rc 1 "Firing: partial declaration exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_partial"

mkdir -p "$WORK/m_cov"
printf 'module Bad\n\n%%default total\n\ncovering\nunlisted : IO ()\nunlisted = pure ()\n' > "$WORK/m_cov/Bad.idr"
assert_rc 1 "Firing: unallowlisted covering declaration exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_cov"

mkdir -p "$WORK/m_nototal"
printf 'module Bad\n\nidNat : Nat -> Nat\nidNat x = x\n' > "$WORK/m_nototal/Bad.idr"
assert_rc 1 "Firing: missing '%default total' exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_nototal"
assert_grep "missing '%default total'" "Firing: names missing '%default total'"

mkdir -p "$WORK/m_latetotal"
printf 'module Bad\n\nidNat : Nat -> Nat\nidNat x = x\n\n%%default total\n' > "$WORK/m_latetotal/Bad.idr"
assert_rc 1 "Firing: '%default total' placed after declaration exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_latetotal"
assert_grep "appears after a declaration" "Firing: names misplaced '%default total'"

mkdir -p "$WORK/m_strhide"
printf 'module Bad\n\n%%default total\n\nsneaky : a -> (String, b)\nsneaky x = ("--", %s x)\n' "$BM" > "$WORK/m_strhide/Bad.idr"
assert_rc 1 "Firing: escape hatch after quoted \"--\" string literal exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_strhide"

mkdir -p "$WORK/m_importcomment"
cat > "$WORK/m_importcomment/Bad.idr" <<'IDR'
module Bad
import Data.Vect {-
%default total
-}
idNat : Nat -> Nat
idNat x = x
IDR
assert_rc 1 "Firing: directive in block comment after import does not count" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_importcomment"
assert_grep "missing '%default total'" "Firing: commented directive is missing"

mkdir -p "$WORK/m_blockcomment"
cat > "$WORK/m_blockcomment/Sound.idr" <<'IDR'
module Sound
import Data.Vect {- outer
{- nested -}
partial
believe_me
-} %default total
idNat : Nat -> Nat
idNat x = x
IDR
assert_rc 0 "Silence: nested comments removed and code after closing marker retained" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_blockcomment"
printf 'bad : Nat\nbad = ?hole\n' >> "$WORK/m_blockcomment/Sound.idr"
assert_rc 1 "Firing: active hole after block comment still detected" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_blockcomment"
assert_grep 'Sound.idr:10:bad = ' "Firing: comment stripping preserves line numbers"

echo "=== 2. compute-bench-baseline.sh & check-bench-regression.sh ==="
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$WORK/runs"
  for idx in $(seq 1 10); do
    mkdir -p "$WORK/runs/100${idx}"
    cat > "$WORK/runs/100${idx}/run.json" <<JSON
{"commit":"deadbeef","results":[{"checksum":true,"iterations":5,"median_ns":10000000,"name":"alpha"},{"checksum":true,"iterations":5,"median_ns":20000000,"name":"beta"},{"checksum":true,"iterations":5,"median_ns":40000000,"name":"gamma"}],"schema_version":1,"suite":"proven-bench"}
JSON
  done

  # Keep the generator's dependencies available while hiding both serializers.
  mkdir -p "$WORK/no-serializer-bin"
  for tool in bash dirname basename jq realpath sed; do
    ln -s "$(command -v "$tool")" "$WORK/no-serializer-bin/$tool"
  done
  baseline_without_serializer() {
    PATH="$WORK/no-serializer-bin" bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" \
      "$WORK"/runs/100*/run.json > "$WORK/no-serializer-baseline.json"
  }
  assert_rc 2 "Setup (exit 2): missing JCS serializer refused" baseline_without_serializer
  assert_grep "neither ijson-jcs nor bun" "Setup: names missing JCS serializer"
  assert_rc 0 "Setup: missing serializer writes no baseline" test ! -s "$WORK/no-serializer-baseline.json"

  assert_rc 2 "Setup (exit 2): fewer than 10 runs refused (BASELINE BOOTSTRAPPING)" \
    bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" "$WORK/runs/1001/run.json" "$WORK/runs/1002/run.json"
  assert_grep "BASELINE BOOTSTRAPPING" "Setup: names BASELINE BOOTSTRAPPING"

  assert_rc 2 "Setup (exit 2): repeated duplicate run file refused" \
    bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" \
      "$WORK/runs/1001/run.json" "$WORK/runs/1001/run.json" "$WORK/runs/1002/run.json" \
      "$WORK/runs/1003/run.json" "$WORK/runs/1004/run.json" "$WORK/runs/1005/run.json" \
      "$WORK/runs/1006/run.json" "$WORK/runs/1007/run.json" "$WORK/runs/1008/run.json" \
      "$WORK/runs/1009/run.json"
  assert_grep "duplicate source run" "Setup: names duplicate source run"

  cp "$WORK/runs/1001/run.json" "$WORK/valid-run.json"
  for shape in empty whitespace multiple; do
    case "$shape" in
      empty) : > "$WORK/runs/1001/run.json" ;;
      whitespace) printf ' \n\t\n' > "$WORK/runs/1001/run.json" ;;
      multiple) cat "$WORK/valid-run.json" "$WORK/valid-run.json" > "$WORK/runs/1001/run.json" ;;
    esac
    rejected_baseline() {
      bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" "$WORK"/runs/100*/run.json > "$WORK/rejected-baseline.json"
    }
    assert_rc 2 "Setup: $shape benchmark source refused" rejected_baseline
    assert_grep 'expected exactly one benchmark document' "Setup: names $shape source cardinality"
    assert_rc 0 "Setup: $shape source writes no baseline" test ! -s "$WORK/rejected-baseline.json"
  done
  cp "$WORK/valid-run.json" "$WORK/runs/1001/run.json"

  bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" "$WORK"/runs/100*/run.json > "$WORK/baseline.json"
  assert_rc 0 "Silence: baseline retains one provenance entry per run" \
    jq -e '.window == 10 and (.sources | length == 10) and all(.sources[]; .run_id != null)' "$WORK/baseline.json"
  assert_rc 0 "Silence: generated baseline is canonical I-JSON + JCS" \
    bash "$REPO_ROOT/scripts/check-ijson-jcs.sh" --enforce "$WORK/baseline.json"

  assert_rc 0 "Silence: ordinary run within tolerance passes" \
    bash "$REPO_ROOT/scripts/check-bench-regression.sh" "$WORK/runs/1001/run.json" "$WORK/baseline.json"

  # 4x slowdown in gamma only: leave-one-out blames ONLY gamma
  cat > "$WORK/regressed.json" <<'JSON'
{"commit":"deadbeef","results":[{"checksum":true,"iterations":5,"median_ns":10000000,"name":"alpha"},{"checksum":true,"iterations":5,"median_ns":20000000,"name":"beta"},{"checksum":true,"iterations":5,"median_ns":160000000,"name":"gamma"}],"schema_version":1,"suite":"proven-bench"}
JSON
  assert_rc 1 "Firing: 4x slowdown in single workload exits 1" \
    bash "$REPO_ROOT/scripts/check-bench-regression.sh" "$WORK/regressed.json" "$WORK/baseline.json"
  assert_grep "Unacceptable regression in: gamma$" "Firing: leave-one-out blames only the regressed workload"

  # Broken workload (checksum: false) must refuse with exit 2, never pass
  cat > "$WORK/broken.json" <<'JSON'
{"commit":"deadbeef","results":[{"checksum":false,"iterations":5,"median_ns":1000,"name":"alpha"},{"checksum":true,"iterations":5,"median_ns":20000000,"name":"beta"},{"checksum":true,"iterations":5,"median_ns":40000000,"name":"gamma"}],"schema_version":1,"suite":"proven-bench"}
JSON
  assert_rc 2 "Setup/Inert (exit 2): checksum=false workload refused" \
    bash "$REPO_ROOT/scripts/check-bench-regression.sh" "$WORK/broken.json" "$WORK/baseline.json"
else
  echo "  NOTE: jq not installed locally; jq-backed bench tests run in CI"
fi

echo "=== 3. emit-aggregate-inputs.sh: Silence, Firing, Setup (0 / 1 / 2) ==="
assert_rc 2 "Setup (exit 2): missing report exits 2" \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/missing-report.json"

cat > "$WORK/report.json" <<JSON
{"entries":[{"name":"t","proof_ladder":[{"proof_file":"$WORK/clean/Sound.idr"}],"provenance":"Actually-Proven"}],"schema_version":1}
JSON

cat > "$WORK/mock-pa-ok" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output=$2; shift; fi
  shift
done
[ -n "$output" ]
# A repeated output path would overwrite another proof report.
[ ! -e "$output" ]
case "${MOCK_VERDICT:-closed}" in
  missing) exit 0 ;;
  malformed) printf '{broken\n' > "$output" ;;
  empty) printf '{"aggregated_proofs":[]}\n' > "$output" ;;
  mixed) printf '{"aggregated_proofs":[{"verdict":"closed"},{"verdict":"holes"}]}\n' > "$output" ;;
  *) printf '{"aggregated_proofs":[{"verdict":"%s"}]}\n' "${MOCK_VERDICT:-closed}" > "$output" ;;
esac
SH
cat > "$WORK/mock-pa-holes" <<'SH'
#!/usr/bin/env bash
echo "verdict: Holes" >&2
exit 1
SH
chmod +x "$WORK/mock-pa-ok" "$WORK/mock-pa-holes"

assert_rc 0 "Silence: Closed proof-ladder verdict exits 0" \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/report.json" "$WORK/mock-pa-ok"

assert_rc 1 "Firing: Holes proof-ladder verdict exits 1" \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/report.json" "$WORK/mock-pa-holes"

for verdict in holes refuted indeterminate mixed missing malformed empty; do
  assert_rc 1 "Firing: successful aggregate with $verdict report exits 1" \
    env MOCK_VERDICT="$verdict" bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/report.json" "$WORK/mock-pa-ok"
done

# Same basename in different directories must still receive separate outputs.
jq --arg f "$WORK/other/Sound.idr" '.entries[0].proof_ladder += [{proof_file: $f}]' \
  "$WORK/report.json" > "$WORK/multi-report.json"
assert_rc 0 "Silence: each proof receives a unique report output" \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/multi-report.json" "$WORK/mock-pa-ok"

assert_rc 2 "Setup (exit 2): missing panic-attack binary on Actually-Proven report exits 2" \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/report.json" "$WORK/no-such-panic-attack"

printf '{broken json\n' > "$WORK/malformed-report.json"
assert_rc 2 "Setup (exit 2): malformed JSON report exits 2" \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/malformed-report.json" "$WORK/mock-pa-ok"

echo "=== 4. Proof scanner comments, scopes, and remaining escape hatches ==="
mkdir -p "$WORK/comments/nested dir"
printf 'module Clean\n-- %s ?comment\n||| %s\nimport Data.Nat\n%%hide Prelude.id\n%%default total\nidNat : Nat -> Nat\nidNat x = x -- %s\n' \
  "$BM" "$AT" "$BM" > "$WORK/comments/nested dir/Clean.idr"
assert_rc 0 'comments and doc comments are ignored, including nested paths with spaces' \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/comments"
assert_rc 2 'a missing second scope invalidates an otherwise clean corpus' \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/clean" "$WORK/missing-scope"
for token in 'assert_smaller' '%partial' '%default partial' '%default covering' 'unsafePerformIO' 'idris_crash' \
  'public export partial' 'private covering'; do
  printf 'module Bad\n%%default total\n%s\n' "$token" > "$WORK/clean/Bad.idr"
  assert_rc 1 "remaining banned form is rejected: $token" \
    bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/clean"
done
rm "$WORK/clean/Bad.idr"
assert_rc 1 'a bad module cannot be hidden by a clean second scope' \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_bm" "$WORK/clean"
assert_grep 'Bad.idr:6:' 'scanner preserves original source line numbers'

echo "=== 5. Benchmark statistics, identity, and threshold boundaries ==="
if command -v jq >/dev/null 2>&1; then
  assert_rc 0 'LOO ratios use the geometric mean of OTHER workloads' \
    jq -n -e -L "$REPO_ROOT/scripts" 'include "bench-stats";
      {results:[{name:"a",median_ns:1},{name:"b",median_ns:4},{name:"c",median_ns:16}]}
      | loo_ratios | (.a - 0.125 | fabs) < 1e-10 and (.b - 1 | fabs) < 1e-10 and (.c - 8 | fabs) < 1e-10'
  assert_rc 0 'baseline records all ten sources and expected arithmetic means' \
    jq -e '.window == 10 and (.sources | length) == 10
      and all(.sources[]; .commit == "deadbeef" and (.run_id | test("^[0-9]+$")))
      and .workloads.alpha.mean_median_ns == 10000000
      and (.workloads.alpha.mean_loo_ratio - 0.3535533905932738 | fabs) < 1e-10' "$WORK/baseline.json"

  # Equal medians make tolerance expectations independent of the implementation.
  printf '%s\n' '{"kind":"proven-bench-baseline","schema_version":1,"workloads":{"alpha":{"iterations":5,"mean_loo_ratio":1,"mean_median_ns":100},"beta":{"iterations":5,"mean_loo_ratio":1,"mean_median_ns":100},"gamma":{"iterations":5,"mean_loo_ratio":1,"mean_median_ns":100}}}' > "$WORK/equal-baseline.json"
  jq '.results |= map(.median_ns = 100)' "$WORK/runs/1001/run.json" > "$WORK/equal-run.json"
  regression_case() { # <exit> <jq transformation> <label> <diagnostic>
    local want="$1" transform="$2" label="$3" diagnostic="$4"
    jq "$transform" "$WORK/equal-run.json" > "$WORK/current.json"
    assert_rc "$want" "$label" bash "$REPO_ROOT/scripts/check-bench-regression.sh" \
      "$WORK/current.json" "$WORK/equal-baseline.json"
    assert_grep "$diagnostic" "$label: diagnostic"
  }
  regression_case 0 '.results |= reverse' 'workload order does not change identity' 'OK - no workload regressed'
  regression_case 0 '.results |= map(.median_ns = 250)' 'uniform slowdown exactly at 2.5x passes' 'OK - no workload regressed'
  regression_case 1 '.results |= map(.median_ns = 251)' 'absolute backstop catches uniform slowdown over 2.5x' 'Unacceptable regression in: alpha beta gamma'
  regression_case 0 '.results[0].median_ns = 200' 'relative slowdown exactly at 2x passes' 'OK - no workload regressed'
  regression_case 1 '.results[0].median_ns = 201' 'relative slowdown above 2x fails even below absolute limit' 'Unacceptable regression in: alpha$'
  regression_case 0 '.results[0].median_ns = 40' 'extraordinary improvement passes and is flagged' 'EXTRAORDINARY'
  regression_case 2 '.results[0].iterations = 6' 'changed iterations require a new baseline' 'iterations changed for alpha'
  regression_case 2 '.results[0].name = "delta"' 'renamed workload is not comparable' 'MISSING from baseline: delta'
  regression_case 2 '.results[0].name = "beta"' 'duplicate workload names are refused' 'duplicate workload name'
  regression_case 2 '.results = .results[:2]' 'at least three workloads are required' 'at least 3 workloads'
  regression_case 2 '.results[0].median_ns = 0' 'zero timing is not a measurement' 'not a positive number'
  regression_case 2 '.results[0].median_ns = -1' 'negative timing is refused' 'not a positive number'
  regression_case 2 '.results[0].median_ns = "100"' 'timing strings cannot enter logarithms' 'not a positive number'
  regression_case 2 'del(.results[0].checksum)' 'missing checksum is not true' 'workload is broken'
  regression_case 2 '.schema_version = 2' 'unknown run schema is refused' 'expected 1'
  regression_case 2 '.suite = "other"' 'unrelated benchmark suite is refused' 'expected "proven-bench"'
  for field in mean_median_ns mean_loo_ratio iterations; do
    jq --arg field "$field" '.workloads.alpha[$field] = 0' "$WORK/equal-baseline.json" > "$WORK/bad-baseline.json"
    assert_rc 2 "invalid baseline statistic refused: $field" \
      bash "$REPO_ROOT/scripts/check-bench-regression.sh" "$WORK/equal-run.json" "$WORK/bad-baseline.json"
    assert_grep "$field" 'malformed baseline names the invalid field'
  done

  # Distinct filenames in the same CI run must not inflate the baseline window.
  cp "$WORK/runs/1001/run.json" "$WORK/runs/1001/another.json"
  assert_rc 2 'duplicate CI run ID is refused even for different source paths' \
    bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" "$WORK"/runs/100*/run.json "$WORK/runs/1001/another.json"
  assert_grep 'duplicate source run_id' 'duplicate CI run diagnostic'
  ln -s "$WORK/runs/1001/run.json" "$WORK/run-alias.json"
  assert_rc 2 'symlink alias cannot count as an independent run' \
    bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" "$WORK"/runs/100*/run.json "$WORK/run-alias.json"
  assert_grep 'duplicate source run file' 'duplicate canonical path diagnostic'
  jq '.results[0].iterations = 6' "$WORK/runs/1001/run.json" > "$WORK/different-experiment.json"
  assert_rc 2 'baseline rejects mixed iteration counts' \
    bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" "$WORK"/runs/100*/run.json "$WORK/different-experiment.json"
  assert_grep 'different experiments' 'mixed experiments diagnostic'

  # An eleventh run with doubled times distinguishes the arithmetic mean
  # across all sources from selecting one run or taking a geometric mean.
  # Historical checksums do not gate baseline inputs (documented in bench-stats).
  jq '.results |= map(.median_ns *= 2 | .checksum = false)' "$WORK/runs/1001/run.json" > "$WORK/historical.json"
  bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" "$WORK"/runs/100*/run.json "$WORK/historical.json" > "$WORK/varied-baseline.json"
  assert_rc 0 'baseline averages every source, permits historical checksums, and records unknown run ID' \
    jq -e '.window == 11 and .sources[-1].run_id == null
      and (.workloads.alpha.mean_median_ns - (120000000 / 11) | fabs) < 1e-6
      and (.workloads.alpha.mean_loo_ratio - 0.3535533905932738 | fabs) < 1e-10' "$WORK/varied-baseline.json"

  # Validate shapes directly as units: every malformed shape must produce an
  # error list, while still allowing the documented minimum of three workloads.
  assert_rc 0 'benchmark shape validation rejects malformed containers and workload fields' \
    jq -n -e -L "$REPO_ROOT/scripts" 'include "bench-stats";
      {schema_version:1,suite:"proven-bench",results:[
        {name:"a",median_ns:1,iterations:5,checksum:true},
        {name:"b",median_ns:4,iterations:5,checksum:true},
        {name:"c",median_ns:16,iterations:5,checksum:true}]} as $valid
      | [null, [], "run", ($valid | .results = {}),
         ($valid | .results[0] = null), ($valid | .results[0].name = ""),
         ($valid | .results[0].name = 1), ($valid | .results[0].median_ns = null),
         ($valid | .results[0].iterations = 0), ($valid | .results[0].iterations = -1),
         ($valid | .results[0].iterations = "5")] as $invalid
      | ($valid | bench_errors == []) and all($invalid[]; bench_errors | length > 0)'
  assert_rc 0 'baseline shape validation rejects invalid statistics and container types' \
    jq -e -L "$REPO_ROOT/scripts" 'include "bench-stats";
      . as $valid
      | [null, [], ($valid | .kind = "other"), ($valid | .schema_version = 2),
         ($valid | .workloads = []), ($valid | del(.workloads.gamma)),
         ($valid | .workloads.alpha = null),
         ($valid | .workloads.alpha.mean_median_ns = "100"),
         ($valid | .workloads.alpha.mean_loo_ratio = -1),
         ($valid | .workloads.alpha.iterations = null)] as $invalid
      | ($valid | baseline_errors == []) and all($invalid[]; baseline_errors | length > 0)' \
      "$WORK/equal-baseline.json"

  # A changed workload set cannot be averaged into a baseline, even with
  # enough otherwise valid source runs and unchanged iteration counts.
  jq '.results[0].name = "delta"' "$WORK/runs/1001/run.json" > "$WORK/renamed-workload.json"
  reject_mixed_baseline() {
    bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" "$WORK"/runs/100*/run.json "$WORK/renamed-workload.json" \
      > "$WORK/rejected-mixed-baseline.json"
  }
  assert_rc 2 'baseline refuses mixed workload identities' reject_mixed_baseline
  assert_grep 'different experiments' 'workload identity disagreement is named'
  # Noncanonical output from a refused generation must not leak a partial baseline.
  assert_rc 0 'refused baseline generation emits no JSON document' \
    test ! -s "$WORK/rejected-mixed-baseline.json"
fi

echo "=== 6. Proof aggregation selection, deduplication, and failure folding ==="
cat > "$WORK/record-aggregate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 7 && "$6" == --output ]]
printf '%s\n' "${@:1:5}" >> "$AGGREGATE_CALLS"
[[ "$3" != "$FAIL_PROOF" ]] || exit 1
[[ ! -e "$7" ]]
printf '{"aggregated_proofs":[{"verdict":"closed"}]}\n' > "$7"
SH
chmod +x "$WORK/record-aggregate"
export AGGREGATE_CALLS="$WORK/aggregate-calls" FAIL_PROOF=''
for report in '{"entries":[]}' '{"entries":[{"provenance":"Static-Checked","proof_ladder":[{"proof_file":"ignored.idr"}]}]}' \
  '{"entries":[{"provenance":"Actually-Proven","proof_ladder":[]}]}' ; do
  printf '%s\n' "$report" > "$WORK/selection.json"
  assert_rc 0 'no proven proof files requires no external aggregator' \
    bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/selection.json" "$WORK/no-such-panic-attack"
done
for report in '[]' '{}' '{"entries":null}' '{"entries":{}}'; do
  printf '%s\n' "$report" > "$WORK/selection.json"
  assert_rc 2 "invalid report schema is a setup failure: $report" \
    bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/selection.json" "$WORK/record-aggregate"
done
printf '%s\n' '{"entries":[{"provenance":"Actually-Proven","proof_ladder":[{"proof_file":"a proof.idr"},{"proof_file":"z.idr"},{"proof_file":"a proof.idr"}]},{"provenance":"Static-Checked","proof_ladder":[{"proof_file":"ignored.idr"}]}]}' > "$WORK/selection.json"
printf 'aggregate\n--proof\na proof.idr\n--label\na proof.idr=a proof-ladder\naggregate\n--proof\nz.idr\n--label\nz.idr=z-ladder\n' > "$WORK/expected-calls"
: > "$AGGREGATE_CALLS"
assert_rc 0 'only proven files are aggregated, once each, preserving paths with spaces' \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/selection.json" "$WORK/record-aggregate"
assert_rc 0 'aggregator receives exact proof and label arguments' cmp "$WORK/expected-calls" "$AGGREGATE_CALLS"
: > "$AGGREGATE_CALLS"
FAIL_PROOF='a proof.idr' assert_rc 1 'a failed proof yields failure while remaining proofs are checked' \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/selection.json" "$WORK/record-aggregate"
assert_rc 0 'failure does not suppress later aggregation' cmp "$WORK/expected-calls" "$AGGREGATE_CALLS"

echo "=== 7. Isolated runner and lock portability regressions ==="
assert_rc 0 'runner outcome and benchmark output contracts' bash "$REPO_ROOT/tests/run_proven_suite_test.sh"
assert_rc 0 'actions.lock guards on POSIX mawk' bash "$REPO_ROOT/tests/workflows/check_lock_sync_test.sh"
assert_rc 0 'lock-sync-fix repairs Dependabot lock drift' bash "$REPO_ROOT/tests/workflows/lock_sync_fix_test.sh"
if command -v zig >/dev/null 2>&1; then
  assert_rc 0 'FFI string ownership and sentinel regressions' bash "$REPO_ROOT/tests/ffi_strings_test.sh"
fi

echo "proven_suite_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
