#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Unified 3-outcome test & proof runner grounded in hyperpolymath/proven-tests-and-benches.
#
# Usage: scripts/run-proven-suite.sh [--require-zig] [--bench] [--report FILE]
#
# --require-zig: the zig compiler must be present WHEN src/interface/ffi exists.
# With no src/interface/ffi (pruned by an archetype) the Zig lane is reported as
# NOT APPLICABLE (distinct from PASS, counted in the summary), not an error.
#
# Exit contract:
#   0 = every tier passed (Silence on clean tree + Firing on every negative mutant)
#   1 = a subject check, proof honesty lint, or contract test failed
#   2 = setup / cannot-look failure (missing tool or missing suite — never a pass)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_ZIG=0
RUN_BENCH=0
REPORT_PATH=""
OWNED_REPORT_TMP=""
BENCH_TMP=""

# Remove the runner-owned temporary report directory and benchmark file, if set.
cleanup() {
  [ -n "$OWNED_REPORT_TMP" ] && rm -rf "$OWNED_REPORT_TMP"
  [ -n "$BENCH_TMP" ] && rm -f "$BENCH_TMP"
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --require-zig) REQUIRE_ZIG=1; shift ;;
    --bench) RUN_BENCH=1; shift ;;
    --report)
      [ "$#" -ge 2 ] || { echo "run-proven-suite: --report needs a path" >&2; exit 2; }
      REPORT_PATH="$2"
      shift 2
      ;;
    *) echo "run-proven-suite: unknown option '$1'" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT" || exit 2

if [ -z "$REPORT_PATH" ]; then
  OWNED_REPORT_TMP="$(mktemp -d)"
  REPORT_PATH="$OWNED_REPORT_TMP/proven-tests-report.json"
else
  mkdir -p "$(dirname "$REPORT_PATH")" || { echo "run-proven-suite: cannot create report parent directory" >&2; exit 2; }
fi

subject_failures=0
setup_failures=0
passed_lanes=0
na_lanes=0
NA_LABELS=()

# run_lane LABEL COMMAND... — run a lane and accumulate its outcome without
# propagating its exit status: 2 increments setup_failures; other nonzero
# statuses increment subject_failures.
run_lane() {
  local label="$1" rc=0
  shift
  printf '==> [proven-suite] %s\n' "$label"
  "$@" || rc=$?
  case "$rc" in
    0) printf '    PASS (0): %s\n' "$label"; passed_lanes=$((passed_lanes + 1)) ;;
    2)
      printf '    INERT/SETUP (2): %s\n' "$label" >&2
      setup_failures=$((setup_failures + 1))
      # A workflow annotation, because the lane table is printed at the end of a
      # 200-line log: a red job whose only account of itself is "Process
      # completed with exit code 1" cannot be triaged without the raw log, and
      # the annotations endpoint is the one part of that failure GitHub exposes
      # to the API.
      [ "${GITHUB_ACTIONS:-}" = "true" ] && \
        printf '::warning title=proven-suite lane could not run::%s (exit 2)\n' "$label"
      ;;
    *)
      printf '    FAIL (%d): %s\n' "$rc" "$label" >&2
      subject_failures=$((subject_failures + 1))
      [ "${GITHUB_ACTIONS:-}" = "true" ] && \
        printf '::error title=proven-suite lane failed::%s (exit %d)\n' "$label" "$rc"
      ;;
  esac
}

# require_file PATH — return 0 for an existing regular file; otherwise increment
# setup_failures and return 1.
require_file() {
  if [ ! -f "$1" ]; then
    printf '    INERT/SETUP (2): missing required gate script: %s\n' "$1" >&2
    setup_failures=$((setup_failures + 1))
    return 1
  fi
  return 0
}

# ── Tier 1: Idris2 honesty lint + proof-ladder report ────────────────────────
if require_file scripts/check-escape-hatches.sh; then
  run_lane "Idris2 proof escape-hatch & totality gate" \
    bash scripts/check-escape-hatches.sh src verification .machine_readable/coaptation
fi

mapfile -t PROOF_FILES < <(find src verification .machine_readable/coaptation -name '*.idr' -type f | LC_ALL=C sort)

# Only claim "Actually-Proven" when the Idris2 typechecker discharges every
# module in the corpus; static escape-hatch totality verification without the
# Idris2 kernel is recorded honestly as "Static-Checked" (never overclaiming).
PROOF_PROVENANCE="Static-Checked"
if command -v idris2 >/dev/null 2>&1; then
  idris_ok=1
  for pf in "${PROOF_FILES[@]}"; do
    if ! idris2 --check "$pf" >/dev/null 2>&1; then
      idris_ok=0
      subject_failures=$((subject_failures + 1))
      printf '    FAIL (1): idris2 --check %s\n' "$pf" >&2
    fi
  done
  if [ "$idris_ok" -eq 1 ] && [ "${#PROOF_FILES[@]}" -gt 0 ]; then
    PROOF_PROVENANCE="Actually-Proven"
  fi
fi

{
  printf '{"entries":[{"name":"rsr-idris2-proof-corpus","proof_ladder":['
  first=1
  for pf in "${PROOF_FILES[@]}"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"proof_file":"%s"}' "$pf"
  done
  printf '],"provenance":"%s"}],"schema_version":1}\n' "$PROOF_PROVENANCE"
} > "$REPORT_PATH"

if require_file scripts/emit-aggregate-inputs.sh; then
  run_lane "Proof-ladder aggregation (emit-aggregate-inputs)" \
    bash scripts/emit-aggregate-inputs.sh "$REPORT_PATH"
fi

# ── Tier 2: Repository invariant & estate data-format gates ──────────────────
require_file scripts/check-root-shape.sh && \
  run_lane "Root shape bidirectional allowlist" bash scripts/check-root-shape.sh .
require_file scripts/check-ijson-jcs.sh && \
  run_lane "I-JSON (RFC 7493) + JCS (RFC 8785) canonical gate" bash scripts/check-ijson-jcs.sh --enforce .
require_file scripts/check-lock-sync.sh && \
  run_lane "Workflow actions.lock integrity" bash scripts/check-lock-sync.sh .github/workflows
require_file scripts/check-required-contexts.sh && \
  run_lane "Required status contexts producibility gate" bash scripts/check-required-contexts.sh .
# The verdict grid's edges: a workflow_run that names no workflow's `name:`, an
# artifact the named producer never uploads, a pin the producer moved without
# the reporter, or one tool pinned at two commits. Each fails silently in
# production, so it is checked here as well as in the CICD Squabbler gate.
require_file scripts/check-workflow-edges.sh && \
  run_lane "Workflow edges (producer -> verdict grid)" bash scripts/check-workflow-edges.sh .
require_file scripts/check-hypatia-ignore.sh && \
  run_lane "Hypatia exemption meta-rules (.hypatia-ignore)" bash scripts/check-hypatia-ignore.sh .
# The layer order, the ownership table and the clash resolutions are stated in
# .machine_readable/policies/hypatia-rule-order.json and implemented across four
# files. This lane is what keeps that statement from drifting away from them.
require_file scripts/check-hypatia-rule-order.sh && \
  run_lane "Hypatia rule order & clash resolution" bash scripts/check-hypatia-rule-order.sh .
require_file .github/hooks/validate-deed.sh && \
  run_lane "CHORA deed validation & retired .a2ml refusal" bash .github/hooks/validate-deed.sh
require_file .github/hooks/validate-k9.sh && \
  run_lane "K9 pedigree & contract validation" bash .github/hooks/validate-k9.sh

# ── Tier 3: Silence + Firing contract & E2E test suites ──────────────────────
require_file tests/proven_suite_test.sh && \
  run_lane "Proven tools Silence + Firing self-tests" bash tests/proven_suite_test.sh
require_file tests/workflows/check_ijson_jcs_test.sh && \
  run_lane "I-JSON/JCS Silence + Firing self-tests" bash tests/workflows/check_ijson_jcs_test.sh
require_file tests/workflows/squabble_gate_test.sh && \
  run_lane "CICD-Squabbler & required-context Silence + Firing self-tests" bash tests/workflows/squabble_gate_test.sh
require_file tests/workflows/secret_scanner_contract_test.sh && \
  run_lane "Secret scanner three-context contract Silence + Firing self-tests" bash tests/workflows/secret_scanner_contract_test.sh
require_file tests/shape/check_root_shape_test.sh && \
  run_lane "Root shape Silence + Firing self-tests" bash tests/shape/check_root_shape_test.sh
require_file www/tests/run-all.sh && \
  run_lane "Site & .well-known boundary + planted controls" bash www/tests/run-all.sh

# ── Tier 4: Zig FFI unit tests + E2E mint instantiation ──────────────────────
# Run Zig FFI tests in a temporary copy with project placeholders filled in.
# Remove the copy on return and propagate the zig build test exit status.
run_zig_ffi_tests() {
  local work tok_lc tok_uc
  work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  cp -R src/interface/ffi "$work/ffi"
  tok_lc="{{""project}}"
  tok_uc="{{""PROJECT}}"
  sed -i -e "s/${tok_lc}/test_project/g" -e "s/${tok_uc}/TEST_PROJECT/g" \
    "$work/ffi/build.zig" "$work/ffi/src/main.zig" "$work/ffi/test/integration_test.zig" 2>/dev/null || true
  (cd "$work/ffi" && zig build test)
}

# mark_not_applicable LABEL REASON — record a lane that has no subject in this
# tree. It is a distinct outcome: not PASS (nothing was verified) and not FAIL
# (nothing is wrong). It is printed at the lane and again, counted, in the
# closing summary, so a green run can never be read as "the lane passed".
mark_not_applicable() {
  printf '==> [proven-suite] %s\n' "$1"
  printf '    NOT APPLICABLE: %s\n' "$2"
  na_lanes=$((na_lanes + 1))
  NA_LABELS+=("$1 ($2)")
  [ "${GITHUB_ACTIONS:-}" = "true" ] && \
    printf '::notice title=proven-suite lane not applicable::%s (%s)\n' "$1" "$2"
  return 0
}

# --require-zig means "when there is Zig to test, the compiler must be present".
# It does NOT mean "src/interface/ffi must exist": an archetype may prune the
# FFI seam on purpose (rust-cli drops src/interface/), and CI passes the flag
# unconditionally across archetypes. With no ffi directory there is no subject,
# so the lane is NOT APPLICABLE whether or not zig is installed and whether or
# not --require-zig is given; that is checked FIRST so a pruned tree is not
# failed for lacking a compiler it has no use for. The lane is reported, never
# silently dropped, and is counted apart from passes in the summary.
if [ ! -d src/interface/ffi ]; then
  mark_not_applicable "Zig FFI ABI layout & memory-leak unit tests" \
    "not applicable: src/interface/ffi absent (pruned by archetype)"
elif command -v zig >/dev/null 2>&1; then
  run_lane "Zig FFI ABI layout & memory-leak unit tests" run_zig_ffi_tests
elif [ "$REQUIRE_ZIG" -eq 1 ]; then
  printf '    INERT/SETUP (2): zig compiler required (--require-zig) but missing on PATH\n' >&2
  setup_failures=$((setup_failures + 1))
else
  printf '==> [proven-suite] Zig FFI unit tests: skipped locally (pass --require-zig in CI to fail-closed)\n'
fi

if command -v rustc >/dev/null 2>&1 && command -v just >/dev/null 2>&1; then
  require_file tests/e2e/template_instantiation_test.sh && \
    run_lane "Template mint instantiation E2E" bash tests/e2e/template_instantiation_test.sh .
fi

# ── Tier 5: Benchmark regression gate (optional --bench) ─────────────────────
if [ "$RUN_BENCH" -eq 1 ]; then
  if ! command -v jq >/dev/null 2>&1; then
    printf '    INERT/SETUP (2): jq required for --bench regression gate\n' >&2
    setup_failures=$((setup_failures + 1))
  elif require_file benches/template_bench.sh && require_file scripts/check-bench-regression.sh && require_file benches/baseline.json; then
    BENCH_TMP="$(mktemp)"
    run_lane "Template benchmark execution (--json)" \
      bash -c "bash benches/template_bench.sh --json . > '$BENCH_TMP'"
    run_lane "Six-Sigma leave-one-out benchmark regression gate" \
      bash scripts/check-bench-regression.sh "$BENCH_TMP" benches/baseline.json
  fi
fi

printf 'proven-suite: lanes: %d passed, %d failed, %d setup/inert, %d not applicable\n' \
  "$passed_lanes" "$subject_failures" "$setup_failures" "$na_lanes"
for _na in "${NA_LABELS[@]+"${NA_LABELS[@]}"}"; do
  printf 'proven-suite: NOT APPLICABLE (not a pass): %s\n' "$_na"
done

if [ "$setup_failures" -gt 0 ]; then
  printf 'proven-suite: SETUP/INERT FAILURE (%d setup, %d subject)\n' "$setup_failures" "$subject_failures" >&2
  exit 2
fi
if [ "$subject_failures" -gt 0 ]; then
  printf 'proven-suite: SUBJECT FAILURE (%d failing lane(s))\n' "$subject_failures" >&2
  exit 1
fi
if [ "$na_lanes" -gt 0 ]; then
  printf 'proven-suite: ALL APPLICABLE LANES PASSED (%d lane(s) not applicable and NOT verified)\n' "$na_lanes"
else
  printf 'proven-suite: ALL LANES PASSED\n'
fi
exit 0
