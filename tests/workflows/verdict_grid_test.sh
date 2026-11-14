#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing + Setup-error tests for scripts/verdict-grid-lane.sh.
#
# The lane's risky behaviour is not "does it render a table" — the canonical
# renderer does that, and it lives in standards. It is:
#
#   * collecting another workflow's evidence for one commit, and saying exactly
#     why a scanner has no evidence (not run / still running / artifact gone);
#   * refusing to execute a renderer whose digest does not match, and rendering
#     an ORANGE indeterminate grid when it cannot run — never a green one;
#   * rejecting a bare-array panic-attack file, which cannot distinguish "clean"
#     from "never ran";
#   * updating its own PR comment in place instead of adding one per run.
#
# Each is exercised with a stub `gh` and a stub renderer, so nothing here
# touches github.com and the real renderer is not required to run the suite.
# A separate group runs the WIRING checks over .github/workflows with a mutated
# copy, so those checks are proven able to fail.
set +e
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LANE="$REPO_DIR/scripts/verdict-grid-lane.sh"
FORK_GOV="$REPO_DIR/.github/workflows/fork-governance.yml"
HYPATIA_WF="$REPO_DIR/.github/workflows/hypatia-scan.yml"
PUBLISHER="$REPO_DIR/.github/workflows/verdict-grid-publish.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() {
    fail=$((fail + 1))
    echo "  FAIL: $1" >&2
    # Workflow commands are read from stdout; the human message goes to stderr.
    # NOSONAR
    echo "::error::verdict-grid test failed: $1"
}

# expect RC LABEL -- CMD...  (runs CMD, compares its exit status)
expect() {
    local want="$1" label="$2"
    shift 2
    [[ "$1" == "--" ]] && shift
    local got=0
    "$@" >"$WORK/out" 2>&1 || got=$?
    if [[ "$got" -eq "$want" ]]; then
        ok "$label"
    else
        bad "$label (wanted exit ${want}, got ${got})"
        sed 's/^/        /' "$WORK/out"
    fi
}

contains() { # contains LABEL PATTERN FILE
    if grep -Fq -- "$2" "$3"; then ok "$1"; else bad "$1 (no '$2' in $3)"; sed 's/^/        /' "$3"; fi
}
not_contains() {
    if grep -Fq -- "$2" "$3"; then bad "$1 (unexpected '$2' in $3)"; else ok "$1"; fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────────────────────────────────────
FX="$WORK/fixtures"
mkdir -p "$FX/evidence" "$FX/renderer/scripts/lib" "$FX/bin"

cat > "$FX/hypatia.json" <<'JSON'
[
  {"severity": "high", "rule_module": "workflow_audit", "type": "WF013", "file": ".github/workflows/x.yml", "line": 10, "reason": "unpinned action"},
  {"severity": "low", "rule_module": "root_hygiene", "type": "ERR-GIT-001", "file": "README.adoc", "line": 1, "reason": "note"}
]
JSON

cat > "$FX/panic.json" <<'JSON'
{"status": "ran", "tool": "panic-attack", "ref": "b689a74d2762a1c19839ae3fbd59b7fe5ef920ea", "reason": null, "exit_code": 0,
 "report": {"weak_points": [{"category": "panic", "file": "src/main.rs", "severity": "high", "description": "unwrap"}]}}
JSON

cat > "$FX/pons.json" <<'JSON'
{"status": "not_run", "tool": "pons-asinorum", "ref": "32e55677d8fd1f3010848dee22e822c2f385c2a0", "reason": "not installed", "report": null}
JSON

cat > "$FX/panic-bare-array.json" <<'JSON'
[{"category": "panic", "file": "src/main.rs", "severity": "high"}]
JSON

cat > "$FX/panic-ran-no-report.json" <<'JSON'
{"status": "ran", "tool": "panic-attack", "ref": "b689a74", "reason": null}
JSON

cat > "$FX/enrolment.json" <<'JSON'
{"schema": 1, "reporters": {"rhodibot": {"enrolled": true, "title": "rhodibot (RSR compliance)"},
 "glambot": {"enrolled": false, "reason": "no served HTML surface"}}}
JSON

printf 'not an enrolment manifest\n' > "$FX/enrolment-broken.json"
mkdir -p "$FX/report-backs"
cat > "$FX/report-backs/rhodibot.json" <<'JSON'
{"reporter": "rhodibot", "title": "rhodibot (RSR compliance)", "status": "ran", "reason": null,
 "ref": "abc", "findings": [{"rule_id": "RSR-001", "severity": "error", "file": "README.adoc", "line": 1, "message": "missing badge"}]}
JSON

# Stub renderer: records its argv, then writes the three outputs the real one
# writes. Real digest is computed for it so verification still runs.
cat > "$FX/renderer/scripts/verdict-grid.sh" <<'RENDERER_FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
args_copy=("$@")
printf '%s\n' "${args_copy[@]}" >> "${STUB_ARGV_LOG:-/dev/null}"
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$out" ]] || exit 2
mkdir -p "$out"
printf '%s\n' "${args_copy[@]}" > "$out/argv.txt"
if [[ "${STUB_MODE:-ok}" == "fail" ]]; then
    echo "stub renderer exploded" >&2
    exit 1
fi
if [[ "${STUB_MODE:-ok}" == "usage" ]]; then
    echo "stub renderer: bad usage" >&2
    exit 2
fi
state="${STUB_STATE:-yellow}"
printf '%s\n' '{"state": "'"$state"'", "identity": {"lane": "hypatia"}, "reporters": []}' > "$out/report.json"
if [[ "${STUB_MODE:-ok}" == "bad-report" ]]; then
    printf '%s\n' '{"state": 0}' > "$out/report.json"
fi
printf '%s\n' '<!-- verdict-grid:hypatia regenerated on every run -->' '🟡 yellow · rendered by the stub' > "$out/report.md"
if [[ "${STUB_MODE:-ok}" == "bad-badge" ]]; then
    printf '%s\n' '{"label": "no schema"}' > "$out/badge.json"
else
    printf '%s\n' '{"schemaVersion": 1, "label": "Hypatia grid", "message": "yellow", "color": "yellow"}' > "$out/badge.json"
fi
RENDERER_FIXTURE
chmod +x "$FX/renderer/scripts/verdict-grid.sh"
printf '%s\n' '# stub jq lib' > "$FX/renderer/scripts/lib/verdict-grid.jq"
RENDERER_SHA="$(sha256sum "$FX/renderer/scripts/verdict-grid.sh" | cut -d' ' -f1)"
LIB_SHA="$(sha256sum "$FX/renderer/scripts/lib/verdict-grid.jq" | cut -d' ' -f1)"

# ─────────────────────────────────────────────────────────────────────────────
# Stub gh
# ─────────────────────────────────────────────────────────────────────────────
cat > "$FX/bin/gh" <<'GH_FIXTURE'
#!/usr/bin/env bash
# Stub gh: records every invocation, answers only what the lane asks for.
set -uo pipefail
# The log lives beside the stub, so the test never depends on an environment
# variable surviving function calls and `bash` re-execs.
here="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$*" >> "$here/gh.log"
case "${1:-}" in
  run)
    case "${2:-}" in
      list)
        if [[ -n "${GH_RUNS_FILE:-}" ]]; then
            cat "$GH_RUNS_FILE"
        elif [[ "${GH_MODE:-found}" == "no-run" ]]; then
            echo '[]'
        else
            echo '[{"databaseId": 42, "event": "pull_request", "status": "completed", "conclusion": "success"}]'
        fi
        ;;
      view)
        if [[ -n "${GH_RUNS_FILE:-}" ]]; then
            jq -c --argjson id "$3" '.[] | select(.databaseId == $id) | {status, conclusion}' "$GH_RUNS_FILE"
        else
            echo '{"status": "completed", "conclusion": "success"}'
        fi
        ;;
      download)
        # Copy a fixture into --dir, unless the stub is told the artifact is gone.
        dir=""
        name=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --dir) dir="$2"; shift 2 ;;
                --name) name="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        if [[ "${GH_MODE:-found}" == "no-artifact" || "$name" == "${GH_MISSING_ARTIFACT:-}" ]]; then
            echo "no valid artifacts found" >&2
            exit 1
        fi
        mkdir -p "$dir"
        printf '%s\n' '{"stub": true}' > "$dir/$name.json"
        ;;
      *) exit 1 ;;
    esac
    ;;
  api)
    # Capture the actual API payload, including newlines and JSON escaping.
    # A log of argv alone cannot prove that the report body was preserved.
    if [[ "${2:-}" == "-X" ]]; then
        method="$3"
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "--input" ]]; then cp "$2" "$here/comment-payload.json"; break; fi
            shift
        done
        [[ "${GH_MODE:-}" != "post-error" || "$method" != POST ]] || exit 1
        [[ "${GH_MODE:-}" != "patch-error" || "$method" != PATCH ]] || exit 1
        echo '{}'
        exit 0
    fi
    if [[ -n "${GH_COMMENTS_FILE:-}" ]]; then
        cat "$GH_COMMENTS_FILE"
        exit 0
    fi
    if [[ "${GH_MODE:-none}" == "existing" || "${GH_MODE:-none}" == "patch-error" ]]; then
        echo '[[{"id": 9001, "user": {"login": "github-actions[bot]"}, "body": "<!-- verdict-grid:hypatia regenerated on every run -->\nold grid"}]]'
    elif [[ "${GH_MODE:-none}" == "forged" ]]; then
        echo '[[{"id": 9002, "user": {"login": "untrusted-contributor"}, "body": "<!-- verdict-grid:hypatia regenerated on every run -->\\nforged grid"}]]'
    else
        echo '[[]]'
    fi
    ;;
  *) exit 1 ;;
esac
GH_FIXTURE
chmod +x "$FX/bin/gh"

lane() { # lane SUBCOMMAND [args...]
    GH_BIN="$FX/bin/gh" REPO=example/template GITHUB_REPOSITORY=example/template \
        bash "$LANE" "$@"
}

echo "=== 1. Evidence shapes (validate) ==="
expect 0 "a Hypatia findings array validates" -- lane validate --hypatia "$FX/hypatia.json"
printf '%s\n' '{"findings": []}' > "$FX/hypatia-object.json"
expect 1 "a Hypatia object (not an array) is rejected" -- lane validate --hypatia "$FX/hypatia-object.json"
printf '%s\n' '[{"severity": "SEVERE"}]' > "$FX/hypatia-unknown.json"
lane validate --hypatia "$FX/hypatia-unknown.json" >"$WORK/out" 2>&1
[[ $? -eq 0 ]] && ok "an unknown severity word is a warning, not a failure" || bad "unknown severity must not fail the lane"
contains "the warning names the unrecognised severity" "severe" "$WORK/out"

expect 0 "a panic status envelope with status=ran validates" -- lane validate --panic "$FX/panic.json"
expect 1 "a bare panic array is rejected (it cannot say 'did not run')" -- lane validate --panic "$FX/panic-bare-array.json"
expect 1 "status=ran without a report is rejected" -- lane validate --panic "$FX/panic-ran-no-report.json"
expect 0 "status=not_run with a reason validates (advisory absence)" -- lane validate --pons "$FX/pons.json"
expect 0 "a valid enrolment manifest validates" -- lane validate --enrolment "$FX/enrolment.json"
expect 1 "an unreadable enrolment manifest is rejected" -- lane validate --enrolment "$FX/enrolment-broken.json"
expect 2 "validate with no arguments is a usage error" -- lane validate
expect 2 "an unknown subcommand is a usage error" -- lane frobnicate

for tool in panic pons; do
    for body in '{}' '{"status":1}' '{"status":"ran","report":[]}' '{"status":"ran","report":null}'; do
        printf '%s\n' "$body" > "$FX/invalid-envelope.json"
        expect 1 "$tool rejects an incomplete or incorrectly typed status envelope: $body" -- \
            lane validate "--$tool" "$FX/invalid-envelope.json"
    done
    for status in not_run error not_applicable; do
        printf '{"status":"%s"}\n' "$status" > "$FX/advisory-envelope.json"
        expect 0 "$tool reports $status without inventing a scanner failure" -- \
            lane validate "--$tool" "$FX/advisory-envelope.json"
        contains "missing $tool/$status reason is explained" 'without a reason' "$WORK/out"
    done
done
printf '%s\n' '[{},null]' > "$FX/invalid-hypatia.json"
expect 1 "a single non-object invalidates the Hypatia findings array" -- \
    lane validate --hypatia "$FX/invalid-hypatia.json"

printf '%s\n' '[]' > "$FX/empty-hypatia.json"
expect 0 "an empty Hypatia array is valid evidence of a clean scan" -- \
    lane validate --hypatia "$FX/empty-hypatia.json"
expect 0 "absent evidence is advisory for all four input families" -- \
    lane validate --hypatia "$FX/missing-hypatia.json" --panic "$FX/missing-panic.json" \
    --pons "$FX/missing-pons.json" --enrolment "$FX/missing-enrolment.json"
for warning in 'no Hypatia findings' 'no panic-attack evidence' 'no pons-asinorum evidence' 'no enrolment manifest'; do
    contains "missing input is explained: $warning" "$warning" "$WORK/out"
done

# A rejected first input must not hide diagnostics for the remaining sources.
expect 1 "validation checks every supplied input after an earlier failure" -- \
    lane validate --hypatia "$FX/hypatia-object.json" --panic "$FX/panic-bare-array.json" \
    --pons "$FX/panic-ran-no-report.json" --enrolment "$FX/enrolment-broken.json"
for diagnostic in 'not one JSON array' 'not a panic-attack status envelope' 'no report object' 'not an enrolment manifest'; do
    contains "validation retains the independent diagnostic: $diagnostic" "$diagnostic" "$WORK/out"
done

echo "=== 2. Collecting another workflow's evidence ==="
out="$WORK/collect-found"
: > "$FX/gh.log"
expect 0 "collect succeeds when the run and artifact exist" -- \
    lane collect --out "$out" --sha 0123456789abcdef0123456789abcdef01234567 \
    --source static-analysis-gate.yml:static-analysis-findings
jq -e '.[0].found == true and .[0].run_id == 42' "$out/collection.json" >/dev/null 2>&1 \
    && ok "collection.json records the run it read" || bad "collection.json must record found:true and the run id"
[[ -f "$out/static-analysis-findings/static-analysis-findings.json" ]] \
    && ok "the artifact lands in <out>/<artifact>/" || bad "the artifact was not downloaded into <out>/<artifact>/"
contains "the download names the workflow" "--workflow static-analysis-gate.yml" "$FX/gh.log"
contains "the source lookup filters PR events" "--event pull_request" "$FX/gh.log"
cat > "$FX/runs-mixed.json" <<'JSON'
[{"databaseId": 42, "event": "pull_request", "status": "completed", "conclusion": "success"},
 {"databaseId": 99, "event": "workflow_dispatch", "status": "completed", "conclusion": "success"}]
JSON
out="$WORK/collect-mixed"
GH_RUNS_FILE="$FX/runs-mixed.json" expect 0 "collect ignores newer workflow-dispatch runs for same commit" -- \
    lane collect --out "$out" --sha 0123456789abcdef0123456789abcdef01234567 \
    --source static-analysis-gate.yml:static-analysis-findings
jq -e '.[0].run_id == 42' "$out/collection.json" >/dev/null 2>&1 \
    && ok "selected scan came from a PR event" || bad "non-PR run could override PR evidence"

contains "the download names the artifact" "--name static-analysis-findings" "$FX/gh.log"
contains "the download is scoped to the artifact directory" "--dir " "$FX/gh.log"

out="$WORK/collect-none"
GH_MODE=no-run expect 0 "collect exits 0 when the scanner has no run yet" -- \
    lane collect --out "$out" --sha 0123456789abcdef0123456789abcdef01234567 \
    --source hypatia-scan.yml:hypatia-scan-findings
jq -e '.[0].found == false and (.[0].reason | test("no run of hypatia-scan.yml"))' "$out/collection.json" >/dev/null 2>&1 \
    && ok "a missing run is recorded with its reason (never a clean scan)" || bad "a missing run must be recorded with a reason"

out="$WORK/collect-noartifact"
GH_MODE=no-artifact expect 0 "collect exits 0 when the run has no artifact" -- \
    lane collect --out "$out" --sha 0123456789abcdef0123456789abcdef01234567 \
    --source hypatia-scan.yml:hypatia-scan-findings
jq -e '.[0].found == false and (.[0].reason | test("no readable hypatia-scan-findings artifact"))' "$out/collection.json" >/dev/null 2>&1 \
    && ok "an absent artifact is recorded with its reason" || bad "an absent artifact must be recorded"

out="$WORK/collect-nogh"
# Called directly, not through lane(): lane() pins GH_BIN to the stub.
expect 0 "collect exits 0 when gh is missing" -- \
    env GH_BIN=/nonexistent/gh REPO=example/template GITHUB_REPOSITORY=example/template \
    bash "$LANE" collect --out "$out" --sha 0123456789abcdef0123456789abcdef01234567 \
    --source hypatia-scan.yml:hypatia-scan-findings
jq -e '.[0].found == false and (.[0].reason | test("gh is not available"))' "$out/collection.json" >/dev/null 2>&1 \
    && ok "a missing gh is recorded, not mistaken for a clean scan" || bad "a missing gh must be recorded"
expect 2 "collect without --source is a usage error" -- \
    lane collect --out "$WORK/nope" --sha 0123456789abcdef0123456789abcdef01234567

out="$WORK/collect mixed sources"
printf '%s\n' '[{"databaseId":8,"event":"pull_request","status":"completed"},{"databaseId":73,"event":"pull_request","status":"completed"},{"databaseId":12,"event":"pull_request","status":"completed"}]' > "$FX/runs.json"
: > "$FX/gh.log"
: > "$FX/outputs"
GH_RUNS_FILE="$FX/runs.json" GH_MISSING_ARTIFACT=hypatia-scan-findings GITHUB_OUTPUT="$FX/outputs" \
    expect 0 "collection isolates a missing artifact and selects the newest run" -- \
    lane collect --out "$out" --sha 0123456789abcdef0123456789abcdef01234567 \
    --source hypatia-scan.yml:hypatia-scan-findings \
    --source static-analysis-gate.yml:static-analysis-findings
jq -e 'length == 2 and all(.[]; .run_id == 73)
    and .[0].found == false and .[1].found == true and .[1].reason == null' "$out/collection.json" >/dev/null \
    && ok "each source records its own outcome at the newest run" || bad "collection mixed up source outcomes or run order"
contains "collection queries the requested commit" "--commit 0123456789abcdef0123456789abcdef01234567" "$FX/gh.log"
contains "only absent evidence is exposed to Actions" 'evidence_missing=hypatia-scan-findings (hypatia-scan.yml)' "$FX/outputs"
[[ ! -e "$out/collection.jsonl" ]] && ok "the intermediate JSONL manifest is removed" || bad "collection leaked its intermediate manifest"

echo "=== 2b. Only completed PR runs can supply evidence ==="
cat > "$FX/runs-filtered.json" <<'JSON'
[{"databaseId":17,"event":"pull_request","status":"completed","conclusion":"success"},
 {"databaseId":95,"event":"pull_request","status":"in_progress"},
 {"databaseId":71,"event":"pull_request","status":"completed","conclusion":"failure"},
 {"databaseId":99,"event":"push","status":"completed","conclusion":"success"},
 {"databaseId":94,"event":"pull_request","status":"queued"},
 {"databaseId":98,"event":"workflow_dispatch","status":"completed","conclusion":"success"}]
JSON
: > "$FX/gh.log"
GH_RUNS_FILE="$FX/runs-filtered.json" expect 0 "collection prefers the newest completed PR even when its scanner failed" -- \
    lane collect --out "$WORK/collect-filtered" --sha 0123456789abcdef0123456789abcdef01234567 \
    --source hypatia-scan.yml:hypatia-scan-findings
jq -e '.[0].found == true and .[0].run_id == 71 and .[0].state == "completed/failure"
    and .[0].reason == null' "$WORK/collect-filtered/collection.json" >/dev/null \
    && ok "failed completed scans retain their findings instead of borrowing an older clean run" \
    || bad "collection selected an incomplete, unrelated or older clean run"
contains "the artifact is downloaded from the authenticated run id" 'run download 71 ' "$FX/gh.log"
not_contains "a running scan is never downloaded" 'run download 95 ' "$FX/gh.log"

for records in \
    '[{"databaseId":99,"event":"pull_request","status":"in_progress"}]' \
    '[{"databaseId":99,"event":"pull_request","status":"queued"}]' \
    '[{"databaseId":99,"event":"push","status":"completed"}]' \
    '[{"databaseId":99,"status":"completed"}]' \
    '[{"databaseId":99,"event":"pull_request"}]' \
    '{broken'; do
    printf '%s\n' "$records" > "$FX/runs-ineligible.json"
    : > "$FX/gh.log"
    GH_RUNS_FILE="$FX/runs-ineligible.json" expect 0 "ineligible or unreadable runs remain missing evidence: $records" -- \
        lane collect --out "$WORK/collect-ineligible" --sha 0123456789abcdef0123456789abcdef01234567 \
        --source hypatia-scan.yml:hypatia-scan-findings
    jq -e '.[0].found == false and .[0].run_id == null and (.[0].reason | contains("no run of hypatia-scan.yml"))' \
        "$WORK/collect-ineligible/collection.json" >/dev/null \
        && ok "ineligible runs produce an explicit absence record" || bad "ineligible run was accepted as evidence"
    not_contains "ineligible runs never reach artifact download" 'run download' "$FX/gh.log"
done

echo "=== 3. Rendering through the verified renderer ==="
render_args=(render --out "$WORK/grid" --renderer-dir "$FX/renderer"
    --renderer-sha256 "$RENDERER_SHA" --lib-sha256 "$LIB_SHA"
    --hypatia "$FX/hypatia.json" --panic "$FX/panic.json" --pons "$FX/pons.json"
    --report-backs "$FX/report-backs" --enrolment "$FX/enrolment.json"
    --sha 0123456789abcdef0123456789abcdef01234567 --run 42
    --pr 7 --repo example/template --lane hypatia
    --hypatia-ref be98f74ce93df200752f3798efa1305bfa3e0e10
    --panic-ref b689a74d2762a1c19839ae3fbd59b7fe5ef920ea
    --pons-ref 32e55677d8fd1f3010848dee22e822c2f385c2a0
    --url https://github.com/example/template/actions/runs/42
    --exclude-prefix 9-archive/ --changed "$WORK/changed.txt")
printf '%s\n' "src/lib.rs" > "$WORK/changed.txt"
: > "$FX/argv.log"
STUB_ARGV_LOG="$FX/argv.log" expect 0 "render runs the verified renderer" -- lane "${render_args[@]}"
grep -Fq -- "--hypatia" "$WORK/grid/argv.txt" && ok "the Hypatia evidence is passed to the renderer" \
    || bad "the Hypatia evidence must be passed"
grep -Fq -- "--report-backs" "$WORK/grid/argv.txt" && ok "the fleet report-backs are passed to the renderer" \
    || bad "the report-backs must be passed"
grep -Fq -- "--enrolment" "$WORK/grid/argv.txt" && ok "the enrolment manifest is passed to the renderer" \
    || bad "the enrolment manifest must be passed"
grep -Fq -- "--exclude-prefix" "$WORK/grid/argv.txt" && ok "declared scope exclusions are passed" \
    || bad "scope exclusions must be passed"
grep -Fq -- "--changed" "$WORK/grid/argv.txt" && ok "delta scope is passed when a base commit resolved" \
    || bad "delta scope must be passed"
printf '%s\n' '{"runs":[{"results":[]}]}' > "$FX/hypatia.sarif"
: > "$FX/argv.log"
STUB_ARGV_LOG="$FX/argv.log" expect 0 "render forwards the Hypatia SARIF" -- lane "${render_args[@]}" --hypatia-sarif "$FX/hypatia.sarif"
grep -Fxq -- "--hypatia-sarif" "$WORK/grid/argv.txt" && grep -Fxq -- "$FX/hypatia.sarif" "$WORK/grid/argv.txt" \
    && ok "the Hypatia SARIF reaches the renderer (the grid grades the row from it)" \
    || bad "the Hypatia SARIF must reach the renderer"

grep -Fq -- "--panic-ref" "$WORK/grid/argv.txt" && ok "the tool commits are passed for the profile hash" \
    || bad "tool commits must be passed"

# Empty and missing optional paths must not become renderer arguments. Quoted
# paths and repeated scope exclusions must remain separate argument values.
printf '%s\n' 'previous grid' > "$WORK/previous grid.md"
expect 0 "render forwards a previous baseline and each non-empty exclusion intact" -- \
    lane render --out "$WORK/grid optional paths" --renderer-dir "$FX/renderer" \
    --renderer-sha256 "$RENDERER_SHA" --lib-sha256 "$LIB_SHA" \
    --sha 0123456789abcdef0123456789abcdef01234567 --repo example/template \
    --previous "$WORK/previous grid.md" --exclude-prefix 'generated files/' --exclude-prefix '' \
    --exclude-prefix '9-archive/' --hypatia "$FX/absent.json" --panic "$FX/absent.json" \
    --hypatia-sarif "$FX/absent.sarif" \
    --pons "$FX/absent.json" --enrolment "$FX/absent.json" --report-backs "$FX/absent-dir" \
    --changed "$FX/absent.txt"
printf '%s\n' --previous "$WORK/previous grid.md" --exclude-prefix 'generated files/' --exclude-prefix '9-archive/' > "$WORK/expected-optional-args"
sed -n '/^--previous$/,$p' "$WORK/grid optional paths/argv.txt" > "$WORK/actual-optional-args"
cmp -s "$WORK/expected-optional-args" "$WORK/actual-optional-args" \
    && ok "baseline paths and repeated exclusions preserve argument boundaries" || bad "optional argument values changed"
for flag in --hypatia --hypatia-sarif --panic --pons --enrolment --report-backs --changed; do
    if grep -Fxq -- "$flag" "$WORK/grid optional paths/argv.txt"; then
        bad "missing optional input $flag was forwarded"
    else
        ok "missing optional input $flag is omitted"
    fi
done

: > "$FX/outputs"
printf 'Earlier summary\n' > "$FX/summary"
GITHUB_OUTPUT="$FX/outputs" GITHUB_STEP_SUMMARY="$FX/summary" \
    expect 0 "render appends its state and report to Actions files" -- lane "${render_args[@]}"
printf 'Earlier summary\n' > "$WORK/expected-summary"
cat "$WORK/grid/report.md" >> "$WORK/expected-summary"
cmp -s "$WORK/expected-summary" "$FX/summary" && ok "the summary preserves earlier steps and the complete report" \
    || bad "the rendered report was not appended to the summary"
contains "Actions receives the rendered state" 'state=yellow' "$FX/outputs"
contains "Actions receives the shields badge as one output line" 'badge={"schemaVersion":1,"label":"Hypatia grid","message":"yellow","color":"yellow"}' "$FX/outputs"

echo "=== 4. An unusable renderer is orange, never green ==="
# 4a. absent
absent=(render --out "$WORK/grid-absent" --renderer-dir "$WORK/no-renderer"
    --sha 0123456789abcdef0123456789abcdef01234567 --repo example/template)
expect 0 "an absent renderer still produces a report" -- lane "${absent[@]}"
jq -e '.message == "indeterminate" and .color == "orange"' "$WORK/grid-absent/badge.json" >/dev/null 2>&1 \
    && ok "an absent renderer renders orange" || bad "an absent renderer must render orange"
contains "the orange report says why" "missing or did not match" "$WORK/grid-absent/report.md"
contains "the fallback text agrees with its orange badge" '🟠 **indeterminate**' "$WORK/grid-absent/report.md"

# 4b. digest mismatch, and the renderer must not have executed
: > "$FX/argv.log"
mismatch=(render --out "$WORK/grid-mismatch" --renderer-dir "$FX/renderer"
    --renderer-sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    --lib-sha256 "$LIB_SHA" --sha 0123456789abcdef0123456789abcdef01234567 --repo example/template)
STUB_ARGV_LOG="$FX/argv.log" expect 0 "a digest mismatch still produces a report" -- lane "${mismatch[@]}"
jq -e '.color == "orange"' "$WORK/grid-mismatch/badge.json" >/dev/null 2>&1 \
    && ok "a digest mismatch renders orange" || bad "a digest mismatch must render orange"
[[ -s "$FX/argv.log" ]] && bad "an unverified renderer must NOT be executed" || ok "an unverified renderer is not executed"

# 4c. renderer exits 1
STUB_MODE=fail expect 0 "a failing renderer produces a report" -- \
    lane render --out "$WORK/grid-fail" --renderer-dir "$FX/renderer" \
    --renderer-sha256 "$RENDERER_SHA" --lib-sha256 "$LIB_SHA" \
    --sha 0123456789abcdef0123456789abcdef01234567 --repo example/template
jq -e '.color == "orange"' "$WORK/grid-fail/badge.json" >/dev/null 2>&1 \
    && ok "a failing renderer renders orange" || bad "a failing renderer must render orange"

# 4d. renderer exits 2 (usage)
STUB_MODE=usage expect 2 "a renderer usage error is our usage error" -- \
    lane render --out "$WORK/grid-usage" --renderer-dir "$FX/renderer" \
    --renderer-sha256 "$RENDERER_SHA" --lib-sha256 "$LIB_SHA" \
    --sha 0123456789abcdef0123456789abcdef01234567 --repo example/template

# 4e. renderer writes a badge that is not a shield badge
STUB_MODE=bad-badge expect 0 "a malformed badge still produces a report" -- \
    lane render --out "$WORK/grid-badbadge" --renderer-dir "$FX/renderer" \
    --renderer-sha256 "$RENDERER_SHA" --lib-sha256 "$LIB_SHA" \
    --sha 0123456789abcdef0123456789abcdef01234567 --repo example/template
jq -e '.schemaVersion == 1 and .color == "orange"' "$WORK/grid-badbadge/badge.json" >/dev/null 2>&1 \
    && ok "a malformed badge is replaced by the orange endpoint badge" || bad "a malformed badge must be replaced"

: > "$FX/argv.log"
STUB_ARGV_LOG="$FX/argv.log" expect 0 "the library digest is checked independently of the renderer" -- \
    lane render --out "$WORK/grid-badlib" --renderer-dir "$FX/renderer" \
    --renderer-sha256 "$RENDERER_SHA" --lib-sha256 "$(printf '0%.0s' {1..64})" \
    --sha 0123456789abcdef0123456789abcdef01234567 --repo example/template
[[ ! -s "$FX/argv.log" ]] && ok "a corrupt library prevents renderer execution" || bad "a corrupt library was executed"
jq -e '.state == "orange" and .identity.sha == "0123456789abcdef0123456789abcdef01234567"' "$WORK/grid-badlib/report.json" >/dev/null \
    && ok "library verification failure retains the target commit in its fallback" || bad "library fallback lost state or identity"

STUB_MODE=bad-report expect 0 "a successful renderer with an invalid report falls back to orange" -- \
    lane render --out "$WORK/grid-badreport" --renderer-dir "$FX/renderer" \
    --renderer-sha256 "$RENDERER_SHA" --lib-sha256 "$LIB_SHA" \
    --sha 0123456789abcdef0123456789abcdef01234567 --repo example/template
jq -e '.state == "orange" and (.reason | contains("no readable report.json"))' "$WORK/grid-badreport/report.json" >/dev/null \
    && ok "an invalid report cannot expose the renderer's successful badge" || bad "invalid renderer report did not produce an honest fallback"

# Reusing an output directory must replace all earlier successful artifacts,
# including the Markdown report that a later comment step will publish.
GITHUB_OUTPUT="$FX/fallback-outputs" expect 0 "an unavailable renderer replaces every stale successful output" -- \
    lane render --out "$WORK/grid" --renderer-dir "$WORK/no-renderer" \
    --sha fedcba9876543210fedcba9876543210fedcba98 --repo example/template
jq -e '.schemaVersion == 1 and .message == "indeterminate" and .color == "orange"' "$WORK/grid/badge.json" >/dev/null \
    && ok "the stale badge becomes indeterminate" || bad "a stale successful badge survived"
jq -e '.state == "orange" and .identity.sha == "fedcba9876543210fedcba9876543210fedcba98"
    and .reporters == [] and .sources == []' "$WORK/grid/report.json" >/dev/null \
    && ok "the fallback report identifies this revision without stale evidence" || bad "fallback report retained old evidence"
contains "the replacement Markdown identifies the new revision" 'fedcba987654' "$WORK/grid/report.md"
not_contains "the replacement Markdown discards the earlier renderer report" 'rendered by the stub' "$WORK/grid/report.md"
contains "the fallback state is exported to Actions" 'state=orange' "$FX/fallback-outputs"

echo "=== 5. One comment per lane per pull request ==="
: > "$FX/gh.log"
GH_MODE=none expect 0 "a new PR gets the grid comment" -- \
    lane comment --report "$WORK/grid" --pr 7 --repo example/template
contains "a first run POSTs the comment" "-X POST repos/example/template/issues/7/comments" "$FX/gh.log"

: > "$FX/gh.log"
GH_MODE=existing expect 0 "an existing grid comment is updated" -- \
    lane comment --report "$WORK/grid" --pr 7 --repo example/template
contains "an existing run PATCHes its own comment" "-X PATCH repos/example/template/issues/comments/9001" "$FX/gh.log"
not_contains "an existing run does not POST a second comment" "-X POST" "$FX/gh.log"

: > "$FX/gh.log"
GH_MODE=forged expect 0 "a forged user marker does not suppress posting" -- \
    lane comment --report "$WORK/grid" --pr 7 --repo example/template
contains "the forged marker is ignored" "-X POST repos/example/template/issues/7/comments" "$FX/gh.log"
not_contains "a contributor comment is never patched" "-X PATCH repos/example/template/issues/comments/9002" "$FX/gh.log"

: > "$FX/gh.log"
expect 0 "a push run posts nothing" -- lane comment --report "$WORK/grid" --repo example/template
[[ -s "$FX/gh.log" ]] && bad "a push run must not call the comment API" || ok "a push run makes no comment API call"

contains "the posted body carries the lane marker" "verdict-grid:hypatia" "$WORK/grid/report.md"

echo "=== 6. Reading the previous grid (delta column) ==="
GH_MODE=none expect 0 "previous with no existing comment writes an empty file" -- \
    lane previous --repo example/template --pr 7 --out "$WORK/prev-none.md"
[[ -s "$WORK/prev-none.md" ]] && bad "an absent previous grid must write nothing" || ok "an absent previous grid writes nothing"

GH_MODE=existing expect 0 "previous reads the marker comment's body" -- \
    lane previous --repo example/template --pr 7 --out "$WORK/prev.md"
contains "the previous body is what the renderer compares against" "old grid" "$WORK/prev.md"

GH_MODE=forged expect 0 "forged prior grid cannot become delta baseline" -- \
    lane previous --repo example/template --pr 7 --out "$WORK/prev-forged.md"
[[ -s "$WORK/prev-forged.md" ]] && bad "forged prior grid must not be trusted" || ok "forged prior grid excluded"

expect 0 "previous without a pull request is a no-op" -- \
    lane previous --repo example/template --out "$WORK/prev-push.md"
[[ -s "$WORK/prev-push.md" ]] && bad "a push run must not read a comment" || ok "a push run reads no comment"

echo "=== 6b. Comment pagination, payloads and API failures ==="
marker='<!-- verdict-grid:hypatia regenerated on every run -->'
jq -n --arg marker "$marker" '[[
    {id:1,user:{login:"github-actions[bot]"},body:($marker + "\nolder grid")},
    {id:2,user:{login:"github-actions[bot]"},body:null}
], [
    {id:3,user:{login:"github-actions[bot]"},body:($marker + "\nlatest grid")},
    {id:4,user:{login:"contributor"},body:($marker + "\nforged newer grid")},
    {id:5,user:{login:"github-actions[bot]"},body:"an unrelated bot comment"}
]]' > "$FX/comments.json"
: > "$FX/gh.log"
GH_COMMENTS_FILE="$FX/comments.json" expect 0 "the last owned marker across pages is updated" -- \
    lane comment --report "$WORK/grid" --pr 7 --repo example/template
contains "pagination selects the latest authentic comment" "-X PATCH repos/example/template/issues/comments/3" "$FX/gh.log"
not_contains "pagination does not add another comment" "-X POST" "$FX/gh.log"
GH_COMMENTS_FILE="$FX/comments.json" expect 0 "previous uses the same authentic paginated baseline" -- \
    lane previous --repo example/template --pr 7 --out "$WORK/prev-paged.md"
printf '%s\n' "$marker" 'latest grid' > "$WORK/expected-prev.md"
cmp -s "$WORK/expected-prev.md" "$WORK/prev-paged.md" && ok "previous excludes forged and unrelated later comments" \
    || bad "pagination chose the wrong baseline"

mkdir -p "$WORK/report with spaces"
printf '%s\n' 'A "quoted" finding at C:\source' '' 'second paragraph' > "$WORK/report with spaces/report.md"
GH_MODE=none expect 0 "a report without a marker is posted with its full body" -- \
    lane comment --report "$WORK/report with spaces" --pr 7 --repo example/template
jq -r '.body' "$FX/comment-payload.json" > "$WORK/posted-body.md"
{ printf '%s\n' "$marker"; cat "$WORK/report with spaces/report.md"; } > "$WORK/expected-body.md"
cmp -s "$WORK/expected-body.md" "$WORK/posted-body.md" && ok "JSON payload preserves quotes, backslashes, blank lines and one marker" \
    || bad "comment payload altered report bytes"

for mode in post-error patch-error; do
    : > "$FX/gh.log"
    GH_MODE="$mode" expect 1 "a $mode is surfaced to the caller" -- \
        lane comment --report "$WORK/grid" --pr 7 --repo example/template
    contains "the failed write is explained" "could not" "$WORK/out"
    if [[ "$mode" == patch-error ]]; then
        not_contains "a failed PATCH cannot create a duplicate comment" "-X POST" "$FX/gh.log"
    fi
done

: > "$FX/gh.log"
expect 0 "dry-run prints a marked body without any API calls" -- \
    lane comment --report "$WORK/report with spaces" --pr 7 --repo example/template --dry-run
[[ ! -s "$FX/gh.log" ]] && ok "dry-run leaves the comment API untouched" || bad "dry-run called the API"
cmp -s "$WORK/expected-body.md" "$WORK/out" && ok "dry-run shows the exact proposed comment" || bad "dry-run body differs from publication"

echo "=== 7. Wiring: fork-governance owns the grid ==="
WIRE_FAIL=0
wire_ok() { ok "wiring: $1"; }
wire_bad() { bad "wiring: $1"; WIRE_FAIL=1; }

wiring_checks() { # wiring_checks PR_WORKFLOW PUBLISHER_WORKFLOW [HYPATIA_WORKFLOW]
    local workflow="$1" publisher="$2" hypatia_wf="${3:-$HYPATIA_WF}" verdict_block
    WIRE_FAIL=0
    verdict_block="$WORK/verdict-block.yml"
    awk '/^  verdict:/ { inside = 1 }
         inside && /^  [a-z0-9-]+:$/ && $0 != "  verdict:" { exit }
         inside { print }' "$workflow" > "$verdict_block"
    grep -Eq 'collect .*--source|--source ' "$workflow" && wire_ok "the PR verdict collects scanner evidence" \
        || wire_bad "the PR verdict must collect scanner evidence"
    grep -Fq "render --out" "$workflow" && wire_ok "the PR grid is rendered by the lane script" \
        || wire_bad "the PR grid must be rendered by the lane script"
    grep -Eq '^[[:space:]]+actions: read$' "$verdict_block" && wire_ok "the PR verdict has actions:read" \
        || wire_bad "the PR verdict requires actions:read"
    if ! grep -Eq '^[[:space:]]+pull-requests: write$' "$verdict_block"; then
        wire_ok "PR-time renderer has no pull-request write token"
    else
        wire_bad "untrusted PR-time renderer must not have pull-requests:write"
    fi
    grep -Fq 'name: verdict-grid' "$workflow" && wire_ok "the PR verdict artifact is uploaded" \
        || wire_bad "the PR verdict artifact must be uploaded"
    grep -Fq 'name: Publish verdict grid' "$publisher" && wire_ok "trusted publisher exists" \
        || wire_bad "trusted publisher is missing"
    grep -Fq 'workflow_run:' "$publisher" && wire_ok "trusted publisher reacts to producer completion" \
        || wire_bad "trusted publisher must run on completed workflows"
    grep -Fq 'verdict-grid-lane.sh comment' "$publisher" && wire_ok "trusted publisher owns comment publication" \
        || wire_bad "only trusted publisher may write PR grid comments"
    grep -Fq 'pull-requests: write' "$publisher" && wire_ok "publisher has comment permission" \
        || wire_bad "publisher needs pull-requests:write"
    grep -Fq -- '--event pull_request' "$publisher" && wire_ok "publisher refuses non-PR fleet artifacts" \
        || wire_bad "publisher fleet evidence must come from a PR run"
    grep -Fq 'if ! bash scripts/verdict-grid-lane.sh validate' "$publisher" && wire_ok "publisher handles malformed producer evidence" \
        || wire_bad "invalid evidence must not leave a stale green comment"
    grep -Fq '"message":"indeterminate"' "$publisher" && wire_ok "publisher emits an orange fallback" \
        || wire_bad "publisher must surface invalid evidence as indeterminate"
    grep -Fq 'args+=(--changed "$RUNNER_TEMP/changed-files.txt")' "$publisher" && wire_ok "publisher uses changed-file scope" \
        || wire_bad "publisher must not claim a full-tree delta on unscoped evidence"
    grep -Fq -- '--hypatia-sarif "$ev/hypatia-scan-findings/hypatia.sarif"' "$workflow" && wire_ok "the PR grid is given the Hypatia SARIF" \
        || wire_bad "the PR grid must be given the Hypatia SARIF"
    grep -Fq -- '--hypatia-sarif "$ev/hypatia-scan-findings/hypatia.sarif"' "$publisher" && wire_ok "publisher is given the Hypatia SARIF" \
        || wire_bad "publisher must pass the Hypatia SARIF to the renderer"
    # Only the upload-artifact step's `path:` block counts: the later
    # `sarif_file: hypatia.sarif` (Code Scanning upload) must not satisfy this.
    awk '/name: hypatia-scan-findings/ {f=1; next}
         f && /^[[:space:]]+path:[[:space:]]*\|/ {p=1; next}
         p && /^[[:space:]]+[A-Za-z_-]+:/ {p=0; f=0}
         p && /^[[:space:]]+hypatia\.sarif[[:space:]]*$/ {found=1}
         END {exit !found}' "$hypatia_wf" \
        && wire_ok "the producer artifact carries hypatia.sarif" \
        || wire_bad "hypatia-scan-findings must include hypatia.sarif"
    if grep -Fq 'verdict-grid-lane.sh comment' "$workflow"; then
        wire_bad "PR-time workflow must not publish comments"
    else
        wire_ok "PR-time workflow does not post comments"
    fi
    if grep -Fq 'workflow_run:' "$workflow"; then
        wire_bad "PR-time workflow must not run as privileged workflow_run"
    else
        wire_ok "workflow_run handled only by publisher"
    fi
    return "$WIRE_FAIL"
}

if wiring_checks "$FORK_GOV" "$PUBLISHER"; then ok "fork-governance/publisher trust split"; else bad "fork-governance/publisher trust split"; fi

echo "=== 8. Firing: the wiring checks catch a broken workflow ==="
fire_case() { # fire_case LABEL SED-EXPR FILE
    local label="$1" expr="$2" source="$3" copy="$WORK/mutant.yml"
    sed -E "$expr" "$source" > "$copy"
    if cmp -s "$source" "$copy"; then
        bad "firing control '$label': the mutation changed nothing"
        return
    fi
    if [[ "$source" == "$HYPATIA_WF" ]]; then
        if (wiring_checks "$FORK_GOV" "$PUBLISHER" "$copy") >/dev/null 2>&1; then
            bad "firing control '$label' was not caught"
        else ok "firing control: '$label' is caught"; fi
    elif [[ "$source" == "$FORK_GOV" ]]; then
        if (wiring_checks "$copy" "$PUBLISHER") >/dev/null 2>&1; then
            bad "firing control '$label' was not caught"
        else ok "firing control: '$label' is caught"; fi
    else
        if (wiring_checks "$FORK_GOV" "$copy") >/dev/null 2>&1; then
            bad "firing control '$label' was not caught"
        else ok "firing control: '$label' is caught"; fi
    fi
}
fire_case "dropping trusted comment posting" 's/verdict-grid-lane\.sh comment/true/' "$PUBLISHER"
fire_case "dropping publisher pull-requests: write" 's/^([[:space:]]+)pull-requests: write$/\1pull-requests: read/' "$PUBLISHER"
fire_case "granting PR verdict pull-requests: write" '/^  verdict:/,$ s/^([[:space:]]+)pull-requests: read$/\1pull-requests: write/' "$FORK_GOV"
fire_case "dropping trusted workflow_run trigger" 's/workflow_run:/workflow_dispatch_x:/' "$PUBLISHER"
fire_case "dropping PR grid artifact" 's/name: verdict-grid$/name: grid/' "$FORK_GOV"
fire_case "allowing non-PR fleet evidence" 's/--event pull_request/--event workflow_dispatch/' "$PUBLISHER"
fire_case "dropping orange fallback" 's/"message":"indeterminate"/"message":"success"/' "$PUBLISHER"
fire_case "dropping the publisher Hypatia SARIF" 's/--hypatia-sarif/--hypatia-unused/' "$PUBLISHER"
fire_case "dropping the PR-grid Hypatia SARIF" 's/--hypatia-sarif/--hypatia-unused/' "$FORK_GOV"
fire_case "dropping hypatia.sarif from the artifact path (sarif_file line remains)" '/^[[:space:]]+hypatia\.sarif[[:space:]]*$/d' "$HYPATIA_WF"
fire_case "removing changed-file scope" 's/args\+=\(--changed/args+=(--unused-changed/' "$PUBLISHER"

expect 0 "producer envelopes and publisher authentication satisfy their contracts" -- \
    bash "$REPO_DIR/tests/workflows/workflow_evidence_test.sh"

echo ""
if [[ "$fail" -ne 0 ]]; then
    echo "FAIL: verdict grid lane suite (${pass} passed, ${fail} failed)" >&2
    exit 1
fi
echo "PASS: verdict grid lane suite (${pass} checks)"
