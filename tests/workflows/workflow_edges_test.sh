#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing tests for scripts/check-workflow-edges.sh.
#
# The checker is deliberately textual, so each rule is exercised by mutating a
# COPY of the real workflows — a rename here, an artifact there — and asserting
# exactly one failure comes out. A check that only ever passes proves nothing:
# every firing control below is a mutation of something this repository ships.
set +e
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO_DIR/scripts/check-workflow-edges.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() {
    fail=$((fail + 1))
    echo "  FAIL: $1" >&2
    echo "::error::workflow-edges test failed: $1" # NOSONAR
}

run() { bash "$CHECK" "${1:-$WORK/repo}" >"$WORK/out" 2>&1; }
expect_rc() { # expect_rc RC LABEL [ROOT]
    local want="$1" label="$2" root="${3:-$WORK/repo}" got=0
    run "$root" || got=$?
    if [ "$got" -eq "$want" ]; then ok "$label"; else
        bad "$label (wanted exit ${want}, got ${got})"
        sed 's/^/        /' "$WORK/out"
    fi
}
says() { if grep -Fq -- "$2" "$WORK/out"; then ok "$1"; else bad "$1 (no '$2' in output)"; sed 's/^/        /' "$WORK/out"; fi; }

# Fresh copy of the workflows directory for each case.
fresh() {
    rm -rf "$WORK/repo"
    mkdir -p "$WORK/repo/.github"
    cp -r "$REPO_DIR/.github/workflows" "$WORK/repo/.github/workflows"
    printf '%s' "$WORK/repo"
}

echo "=== 1. The repository as it ships ==="
fresh >/dev/null
expect_rc 0 "every edge resolves on the shipped workflows"
says "the summary counts the edges it checked" "workflow_run edge(s)"

echo "=== 2. Firing: a dead workflow_run edge ==="
fresh >/dev/null
sed -i 's/^name: Hypatia Security Scan$/name: Hypatia Scan/' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "renaming a producer is caught (workflow_run matches name:, not the file)" 
says "the failure names the dead edge" "Hypatia Security Scan"
says "the failure says what it breaks" "never re-render"

echo "=== 2b. A workflow name with the old name as a prefix is NOT a match ==="
fresh >/dev/null
sed -i 's/^name: Hypatia Security Scan$/name: Hypatia Security Scan v2/' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a renamed producer with the old name as a prefix is caught"
says "the mismatch names the exact old workflow" "Hypatia Security Scan"

echo "=== 3. Firing: a producer that stops running on pull_request ==="
fresh >/dev/null
python3 - "$WORK/repo/.github/workflows/static-analysis-gate.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("  pull_request:\n    branches: ['**']\n", "")
open(p, "w").write(s)
PY
expect_rc 1 "a producer with no pull_request trigger is caught"
says "the failure explains the consequence" "only after a push"

echo "=== 4. Firing: an artifact name that nothing produces ==="
fresh >/dev/null
python3 - "$WORK/repo/.github/workflows/static-analysis-gate.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("          name: static-analysis-findings\n", "          name: static-analysis\n", 1)
open(p, "w").write(s)
PY
expect_rc 1 "renaming the evidence artifact is caught"
says "the failure names the artifact" "never uploads"

echo "=== 5. Firing: a tool pin that disagrees with the producer ==="
fresh >/dev/null
sed -i 's/^  PANIC_ATTACK_SHA: b5530834a839734d1d181bfe6edb0d43d4233cf4$/  PANIC_ATTACK_SHA: b689a74d2762a1c19839ae3fbd59b7fe5ef920ea/' "$WORK/repo/.github/workflows/static-analysis-gate.yml"
sed -i 's/--panic-ref b5530834a839734d1d181bfe6edb0d43d4233cf4/--panic-ref b5530834a839734d1d181bfe6edb0d43d4233cf4/' "$WORK/repo/.github/workflows/fork-governance.yml"
expect_rc 1 "a producer pin that moves without the verdict job is caught"
says "the failure names the flag and the variable" "--panic-ref"

echo "=== 6. Firing: one tool pinned at two commits ==="
fresh >/dev/null
python3 - "$WORK/repo/.github/workflows/codeql.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("jobs:\n", "env:\n  PANIC_ATTACK_SHA: 1111111111111111111111111111111111111111\n\njobs:\n", 1)
open(p, "w").write(s)
PY
expect_rc 1 "a second pin for the same tool is caught"
says "the failure says the pin is in two places" "different commits"

echo "=== 7. Firing: no workflow_run at all ==="
fresh >/dev/null
python3 - "$WORK/repo/.github/workflows/verdict-grid-publish.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
start = s.index("  workflow_run:")
end = s.index("    types: [completed]\n") + len("    types: [completed]\n")
open(p, "w").write(s[:start] + s[end:])
PY
expect_rc 1 "a reporter with no workflow_run is caught"
says "the failure says the grid would never re-render" "never re-render"

echo "=== 8. Firing: two workflows with the same name: ==="
fresh >/dev/null
python3 - "$WORK/repo/.github/workflows/codeql.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.index("\nname: ")
j = s.index("\n", i + 1)
open(p, "w").write(s[:i] + "\nname: Hypatia Security Scan" + s[j:])
PY
expect_rc 1 "two files sharing a name: are caught"
says "the failure names the collision" "share a name"

echo "=== 9. Firing: no evidence sources at all ==="
fresh >/dev/null
sed -i 's/--source \(hypatia-scan\|static-analysis-gate\)\.yml:[a-z-]*/--quiet/g' "$WORK/repo/.github/workflows/fork-governance.yml"
expect_rc 1 "a reporter that collects nothing is caught"
says "the failure says the grid would have no rows" "no rows"

echo "=== 10. Setup errors ==="
expect_rc 2 "a missing repository directory is a setup error" "$WORK/nope"
rm -rf "$WORK/repo"; mkdir -p "$WORK/repo/.github/workflows"
expect_rc 2 "a missing reporter workflow is a setup error" "$WORK/repo"

echo "=== 11. Publisher edges and exact artifact identity ==="
fresh >/dev/null
sed -i 's/--source hypatia-scan.yml:/--source absent-scanner.yml:/' "$WORK/repo/.github/workflows/verdict-grid-publish.yml"
expect_rc 1 "a publisher source naming a missing workflow is refused"
says "the missing producer is identified" "absent-scanner.yml"

fresh >/dev/null
sed -i 's/--hypatia-ref [0-9a-f]*/--hypatia-ref 1111111111111111111111111111111111111111/' "$WORK/repo/.github/workflows/verdict-grid-publish.yml"
expect_rc 1 "a stale publisher pin fails even when the PR reporter pin is correct"
says "the diagnostic identifies the publisher" "--hypatia-ref in verdict-grid-publish.yml"

fresh >/dev/null
sed -i 's/--source \(hypatia-scan\|static-analysis-gate\)\.yml:[a-z-]*/--quiet/g' "$WORK/repo/.github/workflows/verdict-grid-publish.yml"
expect_rc 1 "a publisher with no evidence sources is refused"
says "the publisher-specific diagnostic explains the missing rows" "published grid would have no rows"

fresh >/dev/null
# A different step's name cannot stand in for an upload-artifact output name.
# The producer here is a local-upload job written by the test, so the control
# holds whatever shape this repository's hypatia-scan.yml has (a minted child
# may delegate its scan to a reusable workflow, section 10).
wf="$WORK/repo/.github/workflows/hypatia-scan.yml"
grid_pin="$(grep -o -- '--hypatia-ref [0-9a-f]\{40\}' "$WORK/repo/.github/workflows/fork-governance.yml" | head -n1 | awk '{print $2}')"
awk '/^jobs:/ { exit } { print }' "$wf" > "$wf.new"
printf 'jobs:\n  scan:\n    runs-on: ubuntu-latest\n    env:\n      HYPATIA_SHA: %s\n    steps:\n      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9\n        with:\n          name: hypatia-scan-findings-backup\n          path: out\n      - name: hypatia-scan-findings\n        run: true\n' "$grid_pin" >> "$wf.new"
mv "$wf.new" "$wf"
expect_rc 1 "an artifact prefix or unrelated step name cannot satisfy the source edge"
says "the diagnostic requires an actual artifact upload" "never uploads"

fresh >/dev/null
sed -i 's/^name: Hypatia Security Scan$/name: "Hypatia Security Scan"/' "$WORK/repo/.github/workflows/hypatia-scan.yml"
sed -i "s/^name: Static Analysis Gate$/name: 'Static Analysis Gate'/" "$WORK/repo/.github/workflows/static-analysis-gate.yml"
expect_rc 0 "quoted producer names preserve their workflow_run edges"

fresh >/dev/null
rm "$WORK/repo/.github/workflows/verdict-grid-publish.yml"
expect_rc 2 "a missing trusted publisher is a setup error"
says "the missing publisher is named" "publisher workflow"


echo "=== 10. A producer that delegates to a reusable workflow ==="
# Offline: the called workflow is served from EDGES_REUSABLE_DIR, never fetched.
HSHA="$(grep -o -- '--hypatia-ref [0-9a-f]\{40\}' "$REPO_DIR/.github/workflows/fork-governance.yml" | head -n1 | awk '{print $2}')"
RSHA=1111111111111111111111111111111111111111
REUSABLES="$WORK/reusables"
# delegate [WITH] — replace hypatia-scan.yml's jobs with one reusable call.
delegate() {
    local wf="$WORK/repo/.github/workflows/hypatia-scan.yml" ref="${2:-$RSHA}"
    awk '/^jobs:/ { exit } { print }' "$wf" > "$wf.new"
    printf 'jobs:\n  hypatia:\n    uses: owner/standards/.github/workflows/scan.yml@%s\n' "$ref" >> "$wf.new"
    [ -z "${1:-}" ] || printf '    with:\n      hypatia-ref: %s\n' "$1" >> "$wf.new"
    mv "$wf.new" "$wf"
}
# reusable [ARTIFACT] — the called workflow at RSHA, uploading ARTIFACT.
reusable() {
    local dir="$REUSABLES/owner/standards/$RSHA/.github/workflows"
    rm -rf "$REUSABLES"; mkdir -p "$dir"
    printf 'on:\n  workflow_call:\njobs:\n  scan:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9\n        with:\n          name: %s\n          path: out\n' "${1:-hypatia-scan-findings}" > "$dir/scan.yml"
}
export EDGES_REUSABLE_DIR="$REUSABLES"

fresh >/dev/null; reusable; delegate "$HSHA"
expect_rc 0 "a reusable producer passing the verdict's pin resolves both edges"

fresh >/dev/null; reusable; delegate
expect_rc 1 "a reusable producer that passes no hypatia-ref is caught"
says "the failure says the default runs instead" "without passing hypatia-ref"

fresh >/dev/null; reusable; delegate 2222222222222222222222222222222222222222
expect_rc 1 "a reusable producer passing a different pin is caught"
says "the mismatch names the input it read" "with: hypatia-ref"

fresh >/dev/null; reusable other-artifact; delegate "$HSHA"
expect_rc 1 "a reusable that does not upload the evidence artifact is caught"
says "the failure names the missing artifact" "never uploads"

fresh >/dev/null; reusable; delegate "$HSHA" v1
expect_rc 2 "a reusable call pinned to a tag cannot be followed (setup error)"
says "the failure asks for a full SHA" "full commit SHA"

fresh >/dev/null; rm -rf "$REUSABLES"; mkdir -p "$REUSABLES"; delegate "$HSHA"
expect_rc 2 "an unreadable reusable is a setup error, never a pass"
says "the failure names the unreadable call" "not in EDGES_REUSABLE_DIR"

fresh >/dev/null; reusable; delegate "$HSHA"
cat >> "$WORK/repo/.github/workflows/hypatia-scan.yml" <<'YML'
  local:
    runs-on: ubuntu-latest
    steps:
      - uses: owner/standards/.github/workflows/scan.yml@2222222222222222222222222222222222222222
YML
expect_rc 0 "a step action with a workflow-shaped path is not followed as a reusable call"
unset EDGES_REUSABLE_DIR
echo ""
if [ "$fail" -ne 0 ]; then
    echo "FAIL: workflow edges suite (${pass} passed, ${fail} failed)" >&2
    exit 1
fi
echo "PASS: workflow edges suite (${pass} checks)"
