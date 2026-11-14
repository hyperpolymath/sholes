#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# verdict-grid-lane.sh — collect, render and post the Hypatia verdict grid.
#
# Policy: metadatastician/standards docs/VERDICT-GRID-SPEC.adoc (a findings
# lane has one row per reporter: Hypatia, panic-attack, pons asinorum and every
# gitbot-fleet member the repository enrols). The renderer itself is NOT copied
# here: it stays in standards and is fetched at the pinned commit and checked
# against a recorded sha256, the way scripts/kyaml-format.sh is. A copy in this
# repository would be a second implementation that can drift from the one the
# estate tests; this script only decides WHAT the renderer is given and WHAT
# happens when it cannot run.
#
# WHY THIS IS A SCRIPT AND NOT INLINE SHELL
#
#   The previous wiring claimed a grid that did not exist: .github/workflows/
#   README.adoc described a `verdict` job, a `verdict-grid` artifact and a
#   `<!-- verdict-grid:hypatia ... -->` comment, and no workflow produced any of
#   them. The claim survived because nothing could test it. Everything below is
#   therefore split into subcommands a test can drive with a stub `gh` and a
#   stub renderer: discovery of another workflow's evidence, the renderer's
#   absence or corruption, badge validity, and comment create-vs-update.
#
# SUBCOMMANDS
#
#   collect   Find the run of a producing workflow for one commit, download the
#             artifact it produced, and record what was found (or why not).
#   render    Assemble the renderer's arguments, verify the renderer's digest,
#             run it, and validate what it wrote. Never executes an unverified
#             renderer; never reports a missing one as a pass.
#   comment   Post the grid to the pull request, updating the comment it posted
#             last time (one comment per lane per PR, found by its marker).
#   previous  Write the body of the marker comment this lane posted last time,
#             so the next render can fill its "since previous revision" column.
#   validate  Check the shapes of the evidence files (Hypatia array, panic and
#             pons status envelopes, enrolment manifest) without rendering.
#
# EXIT CONTRACT (proven-tests-and-benches 3-outcome convention)
#
#   0  did what was asked. For `render`, that includes a grid whose verdict is
#      orange or red: the verdict is not this script's exit code.
#   1  the requested work failed (unverified renderer, unreadable output,
#      comment API failure). The grid is then absent or replaced by the orange
#      "indeterminate" report, never by a green one.
#   2  usage error: a required argument is missing or malformed.
#
# ENVIRONMENT
#
#   GH_BIN              `gh` to use (default: gh). Tests point this at a stub.
#   GITHUB_REPOSITORY   owner/name, defaults for --repo.
#   GITHUB_OUTPUT       when set, `state=` and `evidence=` are appended.
#   GITHUB_STEP_SUMMARY when set, the rendered grid is appended.

set -euo pipefail

MARKER='<!-- verdict-grid:hypatia regenerated on every run -->'
ORANGE_BADGE='{"schemaVersion":1,"label":"Hypatia grid","message":"indeterminate","color":"orange"}'

# The renderer is pinned by commit AND by digest. The digest is what makes the
# pin meaningful: a commit can be rewritten out from under a moving tag, and a
# wrongly resolved ref would otherwise run unreviewed code in a job that holds
# pull-requests: write.
STANDARDS_REPO="${VERDICT_GRID_STANDARDS_REPO:-metadatastician/standards}"
STANDARDS_SHA="${VERDICT_GRID_STANDARDS_SHA:-f0b3cd4c464d33e1584f8528c17bce104555e256}"
RENDERER_SHA256="7c2cac9248fd249f607de827dc8dc9a3f6276bf9ca662be86aa435e9aeca48d7"
JQ_LIB_SHA256="36e7aa69afbe8c488b1a313fd9bd0cf2bf6af45d3f34b80afd793f6b20582896"

usage() {
    sed -n '5,60p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

note() { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
fail() { printf '::error::%s\n' "$*" >&2; }

# set_output KEY VALUE — append to $GITHUB_OUTPUT when it exists.
set_output() {
    [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

gh_bin() { printf '%s' "${GH_BIN:-gh}"; }

# ─────────────────────────────────────────────────────────────────────────────
# collect — another workflow's artifact, for this commit
# ─────────────────────────────────────────────────────────────────────────────

# collect_source WORKFLOW ARTIFACT DEST SHA — one source.
# Appends one JSON object to COLLECTED (a file), and downloads when found.
collect_source() {
    local workflow="$1" artifact="$2" dest="$3" sha="$4"
    local gh run_id="" reason="" status="" found=false
    gh="$(gh_bin)"

    if [[ ! -x "$gh" ]] && ! command -v "$gh" >/dev/null 2>&1; then
        reason="gh is not available, so ${workflow} evidence could not be fetched"
    else
        # The runs of this workflow for exactly this commit, newest first. A
        # run that is still in progress has no artifact yet; it is reported as
        # "not yet", never silently treated as a clean scan.
        if ! run_id="$("$gh" run list --repo "$REPO" --workflow "$workflow" \
                --commit "$sha" --event pull_request --limit 20 \
                --json databaseId,status,conclusion,event 2>/dev/null \
                | jq -r '[.[] | select(.event == "pull_request" and .status == "completed")] | sort_by(.databaseId) | last | .databaseId // empty')"; then
            run_id=""
        fi
        if [[ -z "$run_id" ]]; then
            reason="no run of ${workflow} is recorded for ${sha:0:12}"
        else
            status="$("$gh" run view "$run_id" --repo "$REPO" --json status,conclusion 2>/dev/null \
                | jq -r '"\(.status)/\(.conclusion // "none")"' 2>/dev/null || true)"
            if "$gh" run download "$run_id" --repo "$REPO" --name "$artifact" --dir "$dest" \
                    >/dev/null 2>&1; then
                found=true
                reason=""
            else
                reason="run ${run_id} of ${workflow} has no readable ${artifact} artifact (${status:-unknown state})"
            fi
        fi
    fi

    jq -cn --arg workflow "$workflow" --arg artifact "$artifact" --arg run "$run_id" \
        --arg status "$status" --arg reason "$reason" --argjson found "$found" \
        '{workflow: $workflow, artifact: $artifact, run_id: ($run | if . == "" then null else (tonumber? // .) end),
          state: $status, found: $found, reason: ($reason | if . == "" then null else . end)}' \
        >> "$COLLECTED"
    if [[ "$found" == true ]]; then
        note "collected ${artifact} from ${workflow} (run ${run_id})"
    else
        warn "${reason:-${artifact} was not collected}"
    fi
}

cmd_collect() {
    local out="" sha=""
    COLLECTED=""
    SOURCES=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out) out="$2"; shift 2 ;;
            --sha) sha="$2"; shift 2 ;;
            --source) SOURCES+=("$2"); shift 2 ;;
            --repo) REPO="$2"; shift 2 ;;
            *) fail "unknown option: $1"; usage ;;
        esac
    done
    [[ -n "$out" && -n "$sha" ]] || usage
    [[ -n "${REPO:-}" ]] || { fail "--repo (or GITHUB_REPOSITORY) is required"; exit 2; }
    [[ ${#SOURCES[@]} -gt 0 ]] || { fail "at least one --source is required"; exit 2; }
    mkdir -p "$out"
    COLLECTED="$out/collection.jsonl"
    : > "$COLLECTED"
    local spec workflow artifact dest
    for spec in "${SOURCES[@]}"; do
        IFS=':' read -r workflow artifact <<< "$spec"
        [[ -n "$workflow" && -n "$artifact" ]] || { fail "bad --source '$spec' (want workflow-file:artifact-name)"; exit 2; }
        dest="$out/$artifact"
        mkdir -p "$dest"
        collect_source "$workflow" "$artifact" "$dest" "$sha"
    done
    jq -s '.' "$COLLECTED" > "$out/collection.json"
    rm -f "$COLLECTED"
    local missing
    missing="$(jq -r '[.[] | select(.found | not) | "\(.artifact) (\(.workflow))"] | join("; ")' "$out/collection.json")"
    set_output evidence_missing "$missing"
    note "evidence: $(jq -r '[.[] | select(.found) | .artifact] | join(", ")' "$out/collection.json")"
    # Collection never fails the lane: a scanner that has not reported yet is
    # orange in the grid, which is the honest reading. The step says which.
    [[ -z "$missing" ]] || warn "grid rows without evidence this run: ${missing}"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# validate — the evidence shapes the grid reads
# ─────────────────────────────────────────────────────────────────────────────

# validate_hypatia FILE — an array of objects (paths may be absolute).
validate_hypatia() {
    local file="$1"
    [[ -e "$file" ]] || { warn "no Hypatia findings at ${file}: its row renders orange"; return 0; }
    if ! jq -e 'type == "array" and all(.[]; type == "object")' "$file" >/dev/null 2>&1; then
        fail "${file} is not one JSON array of findings; the grid will read it as unreadable evidence"
        return 1
    fi
    # The grid normalises severity words and makes a row orange on anything it
    # does not know. Name the offending values here instead of in the comment.
    local unknown
    unknown="$(jq -r '[.[] | (.severity // "") | ascii_downcase] | unique
        | map(select(. != "critical" and . != "high" and . != "error" and . != "medium"
                 and . != "warn" and . != "warning" and . != "low"
                 and . != "info" and . != "informational" and . != "note" and . != "suggestion"))
        | join(", ")' "$file")"
    [[ -z "$unknown" ]] || warn "${file} carries severity words the grid does not recognise: ${unknown}"
    return 0
}

# validate_envelope FILE TOOL — a scanner status envelope (VERDICT-GRID-SPEC).
# Bare arrays are the historical shape and are rejected by name, because a bare
# array cannot say "the scanner did not run" and so renders a clean row for a
# scan that never happened.
validate_envelope() {
    local file="$1" tool="$2"
    [[ -e "$file" ]] || { warn "no ${tool} evidence at ${file}: its row renders orange"; return 0; }
    if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
        fail "${file} is not a ${tool} status envelope (a bare array cannot say \"did not run\")"
        return 1
    fi
    if ! jq -e 'has("status") and (.status | type == "string")' "$file" >/dev/null 2>&1; then
        fail "${file} has no string \"status\"; the grid cannot tell a scan from a non-scan"
        return 1
    fi
    local status
    status="$(jq -r '.status' "$file")"
    case "$status" in
        ran)
            if ! jq -e '(.report | type) == "object"' "$file" >/dev/null 2>&1; then
                fail "${file} says status=ran but carries no report object"
                return 1
            fi
            ;;
        not_run | error | not_applicable)
            if [[ "$(jq -r '.reason // ""' "$file")" == "" ]]; then
                warn "${file} says status=${status} without a reason; the grid will show an unexplained orange row"
            fi
            ;;
        *)
            warn "${file} carries status=${status}, which is not ran/not_run/error/not_applicable"
            ;;
    esac
    return 0
}

validate_enrolment() {
    local file="$1"
    [[ -e "$file" ]] || { warn "no enrolment manifest at ${file}: every fleet row renders orange"; return 0; }
    if ! jq -e 'type == "object" and (.reporters | type) == "object"' "$file" >/dev/null 2>&1; then
        fail "${file} is not an enrolment manifest; the grid renders it as unreadable evidence"
        return 1
    fi
    return 0
}

cmd_validate() {
    local hyp="" pan="" pon="" enrol="" rc=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hypatia) hyp="$2"; shift 2 ;;
            --panic) pan="$2"; shift 2 ;;
            --pons) pon="$2"; shift 2 ;;
            --enrolment) enrol="$2"; shift 2 ;;
            *) fail "unknown option: $1"; usage ;;
        esac
    done
    [[ -n "$hyp$pan$pon$enrol" ]] || usage
    [[ -z "$hyp" ]] || validate_hypatia "$hyp" || rc=1
    [[ -z "$pan" ]] || validate_envelope "$pan" "panic-attack" || rc=1
    [[ -z "$pon" ]] || validate_envelope "$pon" "pons-asinorum" || rc=1
    [[ -z "$enrol" ]] || validate_enrolment "$enrol" || rc=1
    return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# render — the canonical renderer, verified
# ─────────────────────────────────────────────────────────────────────────────

# verified_renderer DIR — echoes the renderer path when both files exist and
# both digests match. Anything else returns 1 and says which check failed.
verified_renderer() {
    local dir="$1" file lib
    file="$dir/scripts/verdict-grid.sh"
    lib="$dir/scripts/lib/verdict-grid.jq"
    if [[ ! -f "$file" || ! -f "$lib" ]]; then
        fail "the verdict grid renderer is not available at ${dir}/scripts/verdict-grid.sh; the grid renders indeterminate (orange), never green"
        return 1
    fi
    if ! printf '%s  %s\n' "$RENDERER_SHA256" "$file" | sha256sum -c --strict >/dev/null 2>&1; then
        fail "${file} does not match the recorded sha256 (${RENDERER_SHA256}); refusing to run an unverified renderer"
        return 1
    fi
    if ! printf '%s  %s\n' "$JQ_LIB_SHA256" "$lib" | sha256sum -c --strict >/dev/null 2>&1; then
        fail "${lib} does not match the recorded sha256 (${JQ_LIB_SHA256}); refusing to run an unverified renderer"
        return 1
    fi
    printf '%s' "$file"
}

# fallback_report DIR REASON — the orange "indeterminate" rendering.
# Orange is the spec's word for "the evidence or the renderer was not
# available". Writing a green badge here would be the one unthinkable outcome.
fallback_report() {
    local out="$1" reason="$2"
    mkdir -p "$out"
    printf '%s\n' "$ORANGE_BADGE" > "$out/badge.json"
    {
        printf '%s\n' "$MARKER"
        printf '🟠 **indeterminate** · the verdict grid could not be rendered · `%s`\n' "${SHA:0:12}"
        printf '\n%s\n' "$reason"
        printf '\n_Orange means the evidence for this lane was unavailable, not that the repository passed._\n'
    } > "$out/report.md"
    jq -n --arg state "orange" --arg reason "$reason" --arg sha "$SHA" \
        '{state: $state, identity: {lane: "hypatia", sha: $sha}, reason: $reason,
          reporters: [], sources: []}' > "$out/report.json"
    set_output state orange
}

cmd_render() {
    local out="" renderer_dir="" hyp="" hsarif="" pan="" pon="" backs="" enrol="" prev=""
    local url="" pr="local" href="" pref="" qref="" changed="" lane="hypatia"
    local renderer_sha="$RENDERER_SHA256" lib_sha="$JQ_LIB_SHA256"
    local excludes=()
    SHA=""; RUN_ID="local"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out) out="$2"; shift 2 ;;
            --renderer-dir) renderer_dir="$2"; shift 2 ;;
            --renderer-sha256) renderer_sha="$2"; shift 2 ;;
            --lib-sha256) lib_sha="$2"; shift 2 ;;
            --hypatia) hyp="$2"; shift 2 ;;
            --hypatia-sarif) hsarif="$2"; shift 2 ;;
            --panic) pan="$2"; shift 2 ;;
            --pons) pon="$2"; shift 2 ;;
            --report-backs) backs="$2"; shift 2 ;;
            --enrolment) enrol="$2"; shift 2 ;;
            --previous) prev="$2"; shift 2 ;;
            --sha) SHA="$2"; shift 2 ;;
            --run) RUN_ID="$2"; shift 2 ;;
            --url) url="$2"; shift 2 ;;
            --pr) pr="$2"; shift 2 ;;
            --repo) REPO="$2"; shift 2 ;;
            --lane) lane="$2"; shift 2 ;;
            --hypatia-ref) href="$2"; shift 2 ;;
            --panic-ref) pref="$2"; shift 2 ;;
            --pons-ref) qref="$2"; shift 2 ;;
            --changed) changed="$2"; shift 2 ;;
            --exclude-prefix) excludes+=("$2"); shift 2 ;;
            *) fail "unknown option: $1"; usage ;;
        esac
    done
    [[ -n "$out" ]] || usage
    [[ -n "$SHA" ]] || usage
    renderer_dir="${renderer_dir:-.standards-grid}"

    RENDERER_SHA256="$renderer_sha"
    JQ_LIB_SHA256="$lib_sha"
    mkdir -p "$out"

    local renderer=""
    if ! renderer="$(verified_renderer "$renderer_dir")"; then
        fallback_report "$out" "The renderer pinned in ${STANDARDS_REPO}@${STANDARDS_SHA:0:12} was missing or did not match its recorded sha256."
        return 0
    fi

    local args=(
        render --out "$out"
        --lane "$lane"
        --sha "$SHA" --run "$RUN_ID" --pr "$pr" --repo "$REPO"
        --hypatia-ref "$href" --panic-ref "$pref" --pons-ref "$qref"
    )
    [[ -z "$url" ]] || args+=(--url "$url")
    [[ -z "$hyp" || ! -e "$hyp" ]] || args+=(--hypatia "$hyp")
    # The renderer grades the Hypatia row from SARIF; without it the row is
    # indeterminate ("no SARIF projection"). A missing file is omitted, never
    # faked, so absence still renders orange with that reason.
    [[ -z "$hsarif" || ! -e "$hsarif" ]] || args+=(--hypatia-sarif "$hsarif")
    [[ -z "$pan" || ! -e "$pan" ]] || args+=(--panic "$pan")
    [[ -z "$pon" || ! -e "$pon" ]] || args+=(--pons "$pon")
    [[ -z "$backs" || ! -d "$backs" ]] || args+=(--report-backs "$backs")
    [[ -z "$enrol" || ! -e "$enrol" ]] || args+=(--enrolment "$enrol")
    [[ -z "$prev" || ! -e "$prev" ]] || args+=(--previous "$prev")
    [[ -z "$changed" || ! -e "$changed" ]] || args+=(--changed "$changed")
    if [[ ${#excludes[@]} -gt 0 ]]; then
        local prefix
        for prefix in "${excludes[@]}"; do
            [[ -z "$prefix" ]] || args+=(--exclude-prefix "$prefix")
        done
    fi

    local rc=0
    bash "$renderer" "${args[@]}" > "$out/.render.log" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        cat "$out/.render.log" >&2 || true
        # 2 is a usage error inside the renderer: our own arguments are wrong,
        # so fix them rather than pretending the lane is indeterminate.
        if [[ "$rc" -eq 2 ]]; then
            fail "the verdict grid renderer rejected this invocation (exit 2); see its output above"
            return 2
        fi
        fallback_report "$out" "The renderer exited ${rc}; see the job log."
        return 0
    fi

    if ! jq -e '.state | type == "string"' "$out/report.json" >/dev/null 2>&1; then
        fallback_report "$out" "The renderer wrote no readable report.json."
        return 0
    fi
    if ! jq -e '.schemaVersion == 1 and (.label | type == "string")
                and (.message | type == "string") and (.color | type == "string")' \
            "$out/badge.json" >/dev/null 2>&1; then
        fallback_report "$out" "The renderer wrote a badge.json that is not a shields endpoint badge."
        return 0
    fi

    local state
    state="$(jq -r '.state' "$out/report.json")"
    set_output state "$state"
    set_output badge "$(jq -c . "$out/badge.json")"
    note "verdict grid: state=${state} badge=$(jq -r '.message + "/" + .color' "$out/badge.json")"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -s "$out/report.md" ]]; then
        cat "$out/report.md" >> "$GITHUB_STEP_SUMMARY"
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# previous / comment — one comment per lane per PR, updated in place
# ─────────────────────────────────────────────────────────────────────────────

# marker_comment_id REPO PR — id of the last comment carrying the marker, or "".
marker_comment_id() {
    local repo="$1" pr="$2" gh
    gh="$(gh_bin)"
    "$gh" api --paginate --slurp "repos/${repo}/issues/${pr}/comments" 2>/dev/null \
        | jq -r --arg marker "$MARKER" '
            [.[][] | select(.user.login == "github-actions[bot]" and ((.body // "") | contains($marker)))] | last | .id // empty' 2>/dev/null || true
}

cmd_previous() {
    local out=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out) out="$2"; shift 2 ;;
            --pr) PR="$2"; shift 2 ;;
            --repo) REPO="$2"; shift 2 ;;
            *) fail "unknown option: $1"; usage ;;
        esac
    done
    [[ -n "$out" ]] || usage
    : > "$out"
    if [[ -z "${PR:-}" || "$PR" == "local" || -z "${REPO:-}" ]]; then
        note "no pull request to read a previous grid from"
        return 0
    fi
    local gh body_tmp
    gh="$(gh_bin)"
    body_tmp="$(mktemp)"
    "$gh" api --paginate --slurp "repos/${REPO}/issues/${PR}/comments" 2>/dev/null \
        | jq -r --arg marker "$MARKER" '
            [.[][] | select(.user.login == "github-actions[bot]" and ((.body // "") | contains($marker)))] | last | .body // ""' > "$body_tmp" 2>/dev/null \
        || : > "$body_tmp"
    # An empty JSON string renders as a bare newline: a blank body is no body.
    if [[ -n "$(tr -d '[:space:]' < "$body_tmp")" ]]; then
        cat "$body_tmp" > "$out"
    fi
    rm -f "$body_tmp"
    if [[ -s "$out" ]]; then
        note "read the previous verdict grid from PR #${PR}"
    else
        note "no previous verdict grid on PR #${PR}: the delta column will say so"
    fi
    return 0
}

body_with_marker() {
    local file="$1"
    if head -n1 "$file" | grep -Fq "$MARKER"; then
        cat "$file"
    else
        printf '%s\n' "$MARKER"
        cat "$file"
    fi
}

cmd_comment() {
    local report="" dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --report) report="$2"; shift 2 ;;
            --pr) PR="$2"; shift 2 ;;
            --repo) REPO="$2"; shift 2 ;;
            --dry-run) dry_run=1; shift ;;
            *) fail "unknown option: $1"; usage ;;
        esac
    done
    [[ -n "$report" && -f "$report/report.md" ]] || usage
    [[ -n "${REPO:-}" ]] || usage

    if [[ -z "${PR:-}" || "$PR" == "local" || "$PR" == "null" ]]; then
        note "not a pull request run: the grid stays in the job summary and the verdict-grid artifact"
        set_output comment skipped-no-pr
        return 0
    fi

    local body
    body="$(body_with_marker "$report/report.md")"
    if [[ "$dry_run" -eq 1 ]]; then
        printf '%s\n' "$body"
        set_output comment dry-run
        return 0
    fi

    local gh
    gh="$(gh_bin)"
    local id=""
    id="$(marker_comment_id "$REPO" "$PR")"

    # A process-level temp file, removed by the EXIT trap: a RETURN trap would
    # fire after this function's locals are gone, under `set -u` an error.
    PAYLOAD="$(mktemp)"
    jq -n --arg body "$body" '{body: $body}' > "$PAYLOAD"

    if [[ -n "$id" ]]; then
        if "$gh" api -X PATCH "repos/${REPO}/issues/comments/${id}" --input "$PAYLOAD" >/dev/null; then
            note "updated the existing verdict grid comment (${id})"
            set_output comment updated
            return 0
        fi
        fail "could not update the existing verdict grid comment (${id})"
        return 1
    fi
    if "$gh" api -X POST "repos/${REPO}/issues/${PR}/comments" --input "$PAYLOAD" >/dev/null; then
        note "posted the verdict grid comment"
        set_output comment created
        return 0
    fi
    fail "could not post the verdict grid comment"
    return 1
}

cleanup() { [[ -z "${PAYLOAD:-}" ]] || rm -f "$PAYLOAD"; }

main() {
    local cmd="${1:-}"
    [[ -n "$cmd" ]] || usage
    shift
    REPO="${GITHUB_REPOSITORY:-}"
    PAYLOAD=""
    trap cleanup EXIT
    case "$cmd" in
        collect) cmd_collect "$@" ;;
        validate) cmd_validate "$@" ;;
        render) cmd_render "$@" ;;
        comment) cmd_comment "$@" ;;
        previous) cmd_previous "$@" ;;
        help | --help | -h) usage ;;
        *)
            fail "unknown command: ${cmd}"
            usage
            ;;
    esac
}

main "$@"
