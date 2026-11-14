#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Unit controls for the PR #265 producer envelopes and trusted publisher.
# Execute the actual workflow shell blocks against synthetic scanners and gh;
# no compilers, credentials, network, Actions runner or renderer are needed.
# Usage: bash tests/workflows/workflow_evidence_test.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Fail if the named run block disappears. Running extracted production code
# keeps these tests sensitive to changes in the workflow rather than a copy.
extract_step() {
    awk -v step="$2" '
        $0 == "      - name: " step { found=1; next }
        found && /^        run: \|$/ { emit=1; next }
        emit && /^          / { sub(/^          /, ""); print; lines++; next }
        emit && /^$/ { print; next }
        emit { exit }
        END { if (!lines) exit 1 }
    ' "$1" > "$3" || fail "cannot find workflow step: $2"
}
extract_step "$REPO_DIR/.github/workflows/static-analysis-gate.yml" 'Run panic-attack assail' "$WORK/panic.sh"
extract_step "$REPO_DIR/.github/workflows/static-analysis-gate.yml" 'Run pons-asinorum deep recon audit' "$WORK/pons.sh"
extract_step "$REPO_DIR/.github/workflows/verdict-grid-publish.yml" 'Authenticate source run and identify current pull request' "$WORK/authenticate.sh"

# Exported functions shadow external tools even when the machine happens to
# have a real scanner installed. Validate argv so changed invocations fail.
panic-attack() {
    [[ "$#" == 4 && "$1" == assail && "$2" == . && "$3" == --output ]] || return 99
    case "$SCANNER_MODE" in
        missing) return 0 ;;
        empty) : > "$4" ;;
        *) cp "$SCANNER_REPORT" "$4" ;;
    esac
    return "$SCANNER_EXIT"
}
pons() {
    if [[ "$#" == 1 && "$1" == --version ]]; then echo 'synthetic pons'; return 0; fi
    [[ "$#" == 4 && "$1" == scan && "$2" == --format && "$3" == json && "$4" == . ]] || return 99
    cat "$SCANNER_REPORT"
    return "$SCANNER_EXIT"
}
export -f panic-attack pons

# Each execution starts with empty output files and an isolated working tree.
scanner_case() {
    local tool="$1" mode="$2" input="$3" scanner_rc="$4" want="$5" status="$6"
    local dir="$WORK/$tool-$mode" got=0
    mkdir -p "$dir/temp"
    printf '%s\n' "$input" > "$dir/input.json"
    : > "$dir/output"; : > "$dir/summary"
    (
        cd "$dir"
        SCANNER_REPORT="$dir/input.json" SCANNER_MODE="$mode" SCANNER_EXIT="$scanner_rc" \
            RUNNER_TEMP="$dir/temp" GITHUB_OUTPUT="$dir/output" GITHUB_STEP_SUMMARY="$dir/summary" \
            PANIC_ATTACK_SHA=panic-pin PONS_SHA=pons-pin bash "$WORK/$tool.sh"
    ) > "$dir/log" 2>&1 || got=$?
    [[ "$got" -eq "$want" ]] || { cat "$dir/log" >&2; fail "$tool/$mode: expected exit $want, got $got"; }
    local file="$dir/pons-findings.json" name=pons-asinorum pin=pons-pin
    if [[ "$tool" == panic ]]; then file="$dir/panic-attack-findings.json"; name=panic-attack; pin=panic-pin; fi
    jq -e --arg status "$status" --arg tool "$name" --arg pin "$pin" --argjson rc "$scanner_rc" '
        .status == $status and .tool == $tool and .ref == $pin and .exit_code == $rc
        and (if $status == "ran" then .reason == null and (.report | type == "object")
             else .report == null and (.reason | type == "string" and length > 0) end)
    ' "$file" >/dev/null || fail "$tool/$mode: dishonest envelope"
    if [[ "$status" == ran ]]; then
        jq -e --slurpfile raw "$dir/input.json" '.report == $raw[0]' "$file" >/dev/null \
            || fail "$tool/$mode: envelope must preserve the original report"
    elif [[ "$tool" == panic ]]; then
        [[ ! -s "$dir/output" ]] || fail "$tool/$mode: failed scanner emitted success counts"
    fi
    echo "PASS: $tool/$mode emits $status and preserves the exit code"
}

scanner_case panic clean '{"weak_points":[]}' 0 0 ran
scanner_case panic mixed '{"weak_points":[{"severity":"CRITICAL","suppressed":true},{"severity":"HIGH"},{"severity":"warn"},{"severity":"low"},{"description":"no severity"}]}' 0 0 ran
printf 'total=4\ncritical=0\nhigh=1\nmedium=1\nlow=1\n' > "$WORK/expected-counts"
cmp -s "$WORK/expected-counts" "$WORK/panic-mixed/output" || fail 'panic counts must normalize case and exclude suppressed findings'
scanner_case panic nonzero '{"weak_points":[]}' 7 1 error
scanner_case panic missing '{}' 0 1 error
scanner_case panic empty '{}' 0 1 error
scanner_case panic malformed '{broken' 0 1 error
scanner_case panic wrong-shape '{"weak_points":{}}' 0 1 error

scanner_case pons clean '{"findings":[]}' 0 0 ran
# pons gates (owner ruling 2026-11-12): two non-speculative ERRORs block (exit 1)
# even though the scan itself ran and its envelope is honest ("ran").
scanner_case pons mixed '{"findings":[{"severity":"error","evidence":"SPECULATIVE"},{"severity":"ERROR","evidence":"speculative"},{"severity":"error","evidence":"proven"},{"severity":"ERROR"},{"severity":"warn"},{"severity":"info"}]}' 0 1 ran
scanner_case pons speculative-only '{"findings":[{"severity":"error","evidence":"SPECULATIVE"},{"severity":"warn"}]}' 0 0 ran
for row in '| ERROR (non-speculative) | 2 |' '| WARN | 1 |' '| INFO | 1 |'; do
    grep -Fxq "$row" "$WORK/pons-mixed/summary" || fail "pons summary lost $row"
done
scanner_case pons nonzero '{"findings":[]}' 9 1 error
scanner_case pons malformed '{broken' 0 1 error
scanner_case pons wrong-shape '{"findings":null}' 0 1 error

# Exercise the new path conversion directly from the Hypatia workflow. It
# must strip only the workspace directory, preserving other paths and fields.
awk '
    /jq --arg ws "\$GITHUB_WORKSPACE\/"/ { emit=1 }
    emit { sub(/^          /, ""); print; lines++ }
    emit && /hypatia-findings.relativized.json/ { exit }
    END { if (!lines) exit 1 }
' "$REPO_DIR/.github/workflows/hypatia-scan.yml" > "$WORK/relativize.sh" || fail 'cannot locate Hypatia path conversion'
mkdir -p "$WORK/path conversion"
cat > "$WORK/path conversion/hypatia-findings.json" <<'JSON'
[{"file":"/workspace/repo/src/a.rs","severity":"high","reason":"retain this"},
 {"file":"/workspace/repo-other/a.rs"},{"file":"src/b.rs"},
 {"file":null},{"file":17},{"severity":"low"}]
JSON
(
    cd "$WORK/path conversion"
    GITHUB_WORKSPACE=/workspace/repo bash "$WORK/relativize.sh"
)
jq -e --slurpfile raw "$WORK/path conversion/hypatia-findings.json" '
    . == ($raw[0] | .[0].file = "src/a.rs")
' "$WORK/path conversion/hypatia-findings.relativized.json" >/dev/null \
    || fail 'Hypatia conversion changed sibling prefixes, relative/non-string paths or finding metadata'
echo 'PASS: Hypatia paths become repository relative without changing unrelated evidence'

# Source-run and PR responses are data, served by a local function. Endpoint
# matching ensures unexpected calls cannot fall through to the real gh CLI.
gh() {
    case "$*" in
        'api repos/example/template/actions/runs/42') cat "$SOURCE_RUN" ;;
        'api --paginate --slurp repos/example/template/commits/abc123/pulls') cat "$SOURCE_PRS" ;;
        *) echo "unexpected gh invocation: $*" >&2; return 99 ;;
    esac
}
export -f gh
printf '%s\n' '{"workflow_run":{"id":42,"head_sha":"abc123"},"repository":{"full_name":"example/template"}}' > "$WORK/event.json"
printf '%s\n' '{"id":42,"event":"pull_request","status":"completed","repository":{"full_name":"example/template"},"head_sha":"abc123"}' > "$WORK/run.json"
printf '%s\n' '[[{"number":7,"state":"open","head":{"sha":"abc123"},"base":{"repo":{"full_name":"example/template"}}}]]' > "$WORK/prs.json"

authenticate() {
    local want="$1" got=0
    : > "$WORK/auth-output"
    SOURCE_RUN="$WORK/run-case.json" SOURCE_PRS="$WORK/pr-case.json" \
        RUNNER_TEMP="$WORK" GITHUB_EVENT_PATH="$WORK/event.json" \
        GITHUB_REPOSITORY=example/template GITHUB_OUTPUT="$WORK/auth-output" \
        bash "$WORK/authenticate.sh" > "$WORK/auth-log" 2>&1 || got=$?
    [[ "$got" -eq "$want" ]] || { cat "$WORK/auth-log" >&2; fail "authentication: wanted $want, got $got"; }
}

cp "$WORK/run.json" "$WORK/run-case.json"
# A valid PR on a later page must be found; closed, stale and foreign-base PRs
# are excluded before checking uniqueness.
jq '.[0][0] as $pr | [[$pr + {state:"closed"}, $pr + {head:{sha:"stale"}},
    $pr + {base:{repo:{full_name:"elsewhere/repo"}}}], [$pr]]' "$WORK/prs.json" > "$WORK/pr-case.json"
authenticate 0
printf 'pr=7\nsha=abc123\n' > "$WORK/auth-expected"
cmp -s "$WORK/auth-expected" "$WORK/auth-output" || fail 'a unique current PR was not identified across pages'
echo 'PASS: publisher selects only a unique current open PR in the intended repository'

for mutation in '.id = 99' '.event = "push"' '.status = "in_progress"' \
    '.repository.full_name = "foreign/template"' '.head_sha = "superseded"'; do
    jq "$mutation" "$WORK/run.json" > "$WORK/run-case.json"
    authenticate 1
    [[ ! -s "$WORK/auth-output" ]] || fail "untrusted source exposed publication outputs: $mutation"
    echo "PASS: publisher refuses source run with $mutation"
done

cp "$WORK/run.json" "$WORK/run-case.json"
for mutation in '[[]]' '[[.[0][0] + {head:{sha:"stale"}}]]' '[[.[0][0], .[0][0] + {number:8}]]'; do
    jq "$mutation" "$WORK/prs.json" > "$WORK/pr-case.json"
    authenticate 0
    [[ ! -s "$WORK/auth-output" ]] || fail "missing, stale or ambiguous PR produced publication outputs: $mutation"
    grep -Fq 'No unique current PR' "$WORK/auth-log" || fail 'refusal was not explained'
    echo 'PASS: missing, stale or ambiguous PR prevents publication'
done
