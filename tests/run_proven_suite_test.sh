#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Unit tests for runner outcome folding and benchmark serialization. Real
# dispatch code runs against tiny local lanes; no full suite or builds run.
# Usage: bash tests/run_proven_suite_test.sh
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$work/out" >&2; exit 1; }
mkdir -p "$work/bin" "$work/tree/scripts" "$work/tree/benches" "$work/tree/src" \
  "$work/tree/verification" "$work/tree/.machine_readable/coaptation"
# Hide optional compilers so the controls are independent of the host tools.
for tool in bash dirname mkdir mktemp rm find sort seq date env; do
  ln -s "$(command -v "$tool")" "$work/bin/$tool"
done
cp "$repo/scripts/run-proven-suite.sh" "$work/tree/scripts/"
cp "$repo/benches/template_bench.sh" "$work/tree/benches/"
printf 'module Proof\n%%default total\n' > "$work/tree/src/Proof.idr"
cat > "$work/lane" <<'SH'
#!/usr/bin/env bash
lane=${BASH_SOURCE[0]##*/}
printf '%s\n' "$lane" >> "$LANE_CALLS"
[[ "$lane" != "${SETUP_GATE:-}" ]] || exit 2
[[ "$lane" != "${FAIL_GATE:-}" ]] || exit 7
exit 0
SH
for file in scripts/check-escape-hatches.sh scripts/emit-aggregate-inputs.sh \
  scripts/check-root-shape.sh scripts/check-ijson-jcs.sh scripts/check-lock-sync.sh \
  scripts/check-required-contexts.sh scripts/check-workflow-edges.sh scripts/check-hypatia-ignore.sh \
  scripts/check-hypatia-rule-order.sh \
  .github/hooks/validate-deed.sh .github/hooks/validate-k9.sh \
  tests/proven_suite_test.sh tests/workflows/check_ijson_jcs_test.sh \
  tests/workflows/squabble_gate_test.sh tests/workflows/secret_scanner_contract_test.sh \
  tests/shape/check_root_shape_test.sh www/tests/run-all.sh; do
  mkdir -p "$work/tree/$(dirname "$file")"
  cp "$work/lane" "$work/tree/$file"
done
export LANE_CALLS="$work/calls"
run() { # <expected exit> <script> [args...]
  local want=$1 got=0
  shift
  : > "$LANE_CALLS"
  BASH_ENV=/dev/null PATH="$work/bin" bash "$@" > "$work/out" 2> "$work/err" || got=$?
  [[ "$got" -eq "$want" ]] || { cat "$work/err" >&2; fail "expected exit $want, got $got"; }
}
runner="$work/tree/scripts/run-proven-suite.sh"
run 0 "$runner" --report "$work/reports with spaces/run.json"
grep -qF 'ALL APPLICABLE LANES PASSED' "$work/out" || fail 'missing success outcome'
jq -e '.schema_version == 1 and .entries[0].provenance == "Static-Checked"
  and .entries[0].proof_ladder == [{proof_file:"src/Proof.idr"}]' \
  "$work/reports with spaces/run.json" >/dev/null || fail 'static report overclaims or loses proof files'
[[ "$(wc -l < "$LANE_CALLS")" -eq 17 ]] || fail 'clean run did not dispatch all required lanes'
echo 'PASS: clean runner executes all lanes and emits an honest report at a path with spaces'

# Zig lane with NO src/interface/ffi (an archetype pruned it, e.g. rust-cli).
# The lane must be VISIBLY not-applicable: distinct from PASS, counted apart in
# the summary, never a silent pass and never a confusing cp failure. The tree
# above has no ffi directory, so the first clean run already exercised it.
grep -qF 'NOT APPLICABLE: not applicable: src/interface/ffi absent (pruned by archetype)' "$work/out" \
  || fail 'pruned ffi did not report the Zig lane as not applicable'
grep -qF '1 not applicable' "$work/out" || fail 'not-applicable lane was not counted in the summary'
grep -qF '17 passed, 0 failed, 0 setup/inert, 1 not applicable' "$work/out" \
  || fail 'not-applicable lane was folded into the pass count'
grep -qF 'ALL APPLICABLE LANES PASSED (1 lane(s) not applicable and NOT verified)' "$work/out" \
  || fail 'a run with a not-applicable lane claimed ALL LANES PASSED'
! grep -qF 'PASS (0): Zig FFI' "$work/out" || fail 'not-applicable Zig lane was reported as PASS'
# --require-zig means "zig must be present when there is Zig to test": with no
# ffi directory it is NOT an error, with or without a compiler.
run 0 "$runner" --require-zig
grep -qF 'NOT APPLICABLE: not applicable: src/interface/ffi absent' "$work/out" \
  || fail '--require-zig with no ffi dir hid the not-applicable status'
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/zig"; chmod +x "$work/bin/zig"
run 0 "$runner" --require-zig
grep -qF 'NOT APPLICABLE: not applicable: src/interface/ffi absent' "$work/out" \
  || fail 'a zig compiler on PATH turned a missing ffi dir into a pass'
rm "$work/bin/zig"
echo 'PASS: absent src/interface/ffi is reported NOT APPLICABLE (not PASS, counted), under --require-zig too'

# From here the tree carries the FFI seam, so a missing compiler matters.
mkdir -p "$work/tree/src/interface/ffi"

FAIL_GATE=check-root-shape.sh run 1 "$runner"
grep -qF 'run-all.sh' "$LANE_CALLS" || fail 'subject failure stopped subsequent lanes'
grep -qF 'SUBJECT FAILURE' "$work/err" || fail 'nonzero lane did not become subject failure'
SETUP_GATE=check-required-contexts.sh FAIL_GATE=check-root-shape.sh run 2 "$runner"
grep -qF 'SETUP/INERT FAILURE (1 setup, 1 subject)' "$work/err" || fail 'setup failure must take precedence'
run 2 "$runner" --require-zig
grep -qF 'zig compiler required' "$work/err" || fail 'missing required compiler was silently skipped'
run 2 "$runner" --report
[[ ! -s "$LANE_CALLS" ]] || fail 'missing option argument ran lanes'
run 2 "$runner" --unknown
[[ ! -s "$LANE_CALLS" ]] || fail 'unknown option ran lanes'
mv "$work/tree/scripts/check-lock-sync.sh" "$work/saved-lane"
run 2 "$runner"
grep -qF 'missing required gate script' "$work/err" || fail 'missing gate did not cause setup error'
mv "$work/saved-lane" "$work/tree/scripts/check-lock-sync.sh"
echo 'PASS: failures fold to 1/2, setup takes precedence, options and missing gates fail explicitly'

# The PR adds these required lanes. A total dispatch count alone cannot prove
# each is wired, or that its failure participates in the runner's outcome.
for gate in check-workflow-edges.sh check-hypatia-ignore.sh check-hypatia-rule-order.sh; do
  run 0 "$runner"
  [[ "$(grep -cFx "$gate" "$LANE_CALLS")" -eq 1 ]] || fail "$gate must run exactly once"
  FAIL_GATE="$gate" run 1 "$runner"
  grep -qF 'SUBJECT FAILURE (1 failing lane(s))' "$work/err" || fail "$gate failure was not folded"
  grep -qxF 'run-all.sh' "$LANE_CALLS" || fail "$gate failure stopped later lanes"
  SETUP_GATE="$gate" run 2 "$runner"
  grep -qF 'SETUP/INERT FAILURE (1 setup, 0 subject)' "$work/err" || fail "$gate setup error was not folded"
  mv "$work/tree/scripts/$gate" "$work/saved-lane"
  run 2 "$runner"
  grep -qF "missing required gate script: scripts/$gate" "$work/err" || fail "$gate absence was silent"
  grep -qxF 'run-all.sh' "$LANE_CALLS" || fail "$gate absence stopped later lanes"
  mv "$work/saved-lane" "$work/tree/scripts/$gate"
done
echo 'PASS: all three new governance lanes dispatch once, propagate failures, and require their scripts'

cat > "$work/bin/idris2" <<'SH'
#!/usr/bin/env bash
[[ "$1" == --check && "$2" == src/Proof.idr ]] || exit 99
exit "${IDRIS_STATUS:-0}"
SH
chmod +x "$work/bin/idris2"
run 0 "$runner" --report "$work/checked.json"
jq -e '.entries[0].provenance == "Actually-Proven"' "$work/checked.json" >/dev/null \
  || fail 'successful proof checking did not promote provenance'
IDRIS_STATUS=1 run 1 "$runner" --report "$work/rejected.json"
jq -e '.entries[0].provenance == "Static-Checked"' "$work/rejected.json" >/dev/null \
  || fail 'failed typecheck was labelled Actually-Proven'
echo 'PASS: proof provenance is promoted only after successful typechecking'

bench="$work/tree/benches/template_bench.sh"
run 0 "$bench" --json "$work/tree"
jq -e '.schema_version == 1 and .suite == "proven-bench" and .commit == "unknown"
  and [.results[].name] == ["escape_hatches","ijson_jcs","required_contexts","root_shape"]
  and all(.results[]; .checksum == true and .iterations == 5 and .median_ns > 0)' \
  "$work/out" >/dev/null || fail 'JSON benchmark contract is wrong'
for name in check-escape-hatches.sh check-ijson-jcs.sh check-required-contexts.sh check-root-shape.sh; do
  [[ "$(grep -cFx "$name" "$LANE_CALLS")" -eq 6 ]] || fail "$name needs one warmup plus five samples"
done
cp "$work/out" "$work/bench.json"
bun "$repo/scripts/ijson-jcs-cli.js" check < "$work/bench.json" || fail 'benchmark JSON is not canonical'
FAIL_GATE=check-root-shape.sh run 1 "$bench" "$work/tree" json
jq -e '(.results | length) == 4
  and all(.results[]; .checksum == (.name != "root_shape"))' "$work/out" >/dev/null \
  || fail 'failed workload was omitted or timed as clean'
run 0 "$bench" --csv "$work/tree"
[[ "$(head -1 "$work/out")" == 'workload,iterations,median_ns,checksum' ]] || fail 'CSV header changed'
[[ "$(wc -l < "$work/out")" -eq 5 ]] || fail 'CSV must contain all four workloads'
run 2 "$bench" --json "$work/missing-tree"
rm "$work/tree/scripts/check-escape-hatches.sh"
run 2 "$bench" --json "$work/tree"
[[ ! -s "$work/out" && ! -s "$LANE_CALLS" ]] || fail 'missing workload wrote timings or ran partial benchmark'
echo 'PASS: benchmark outputs, warmups, failure checksums, and missing-workload refusal'

# Exercise --bench at the runner boundary without running real repository
# checks. The direct benchmark serialization is exercised above.
cp "$work/lane" "$work/tree/scripts/check-escape-hatches.sh"
run 2 "$runner" --bench
grep -qF 'jq required for --bench' "$work/err" || fail 'missing benchmark dependency did not cause setup failure'
grep -qFx 'run-all.sh' "$LANE_CALLS" || fail 'missing optional benchmark tool suppressed required lanes'
ln -s "$(command -v jq)" "$work/bin/jq"
printf '{}\n' > "$work/tree/benches/baseline.json"
cat > "$work/tree/benches/template_bench.sh" <<'SH'
#!/usr/bin/env bash
[[ "$#" == 2 && "$1" == --json && "$2" == . ]] || exit 99
printf 'benchmark\n' >> "$LANE_CALLS"
printf '{"synthetic":true}\n'
SH
cat > "$work/tree/scripts/check-bench-regression.sh" <<'SH'
#!/usr/bin/env bash
[[ "$#" == 2 && -s "$1" && "$2" == benches/baseline.json ]] || exit 99
printf '%s\n' "$1" > "$BENCH_CAPTURE"
printf 'regression\n' >> "$LANE_CALLS"
exit "${REGRESSION_STATUS:-0}"
SH
export BENCH_CAPTURE="$work/bench-path"
run 0 "$runner" --bench
grep -qxF 'benchmark' "$LANE_CALLS" || fail 'runner did not execute benchmark'
grep -qxF 'regression' "$LANE_CALLS" || fail 'runner did not compare benchmark to baseline'
[[ ! -e "$(cat "$BENCH_CAPTURE")" ]] || fail 'runner leaked its temporary benchmark report'
REGRESSION_STATUS=1 run 1 "$runner" --bench
grep -qF 'SUBJECT FAILURE (1 failing lane(s))' "$work/err" || fail 'regression did not fold into subject failure'
[[ ! -e "$(cat "$BENCH_CAPTURE")" ]] || fail 'regression failure leaked benchmark report'
echo 'PASS: optional benchmark dependency, dispatch, regression folding, and temporary report cleanup'
