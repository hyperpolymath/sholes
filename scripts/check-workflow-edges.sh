#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-workflow-edges.sh — the intra-repository half of the CICD-Squabbler gate.
#
# hyperpolymath/cicd-squabbler's `chains` command follows CROSS-repository CI
# edges: a reusable workflow or action pinned at a dead commit. This repository's
# verdict grid introduced edges of the same kind INSIDE one repository, which
# squabble cannot see and which fail silently:
#
#   * `.github/workflows/fork-governance.yml` is triggered by
#     `workflow_run: workflows: [...]`, which matches a workflow's `name:`, not
#     its file. Rename `name: Hypatia Security Scan` and the grid stops
#     re-rendering — no error, no red check, just an orange row forever.
#   * It reads artifacts by name (`--source <file>:<artifact>`). Rename an
#     upload step's `name:` and the evidence vanishes the same way.
#   * It names each scanner's pinned commit (`--hypatia-ref`, `--panic-ref`,
#     `--pons-ref`) for the grid's profile hash. If the producer moves its pin
#     and the reporter is not moved with it, two revisions look comparable when
#     they are not.
#   * One tool pinned at two different commits in two workflows is a clash, not
#     a choice: whichever workflow ran last decides what the grid graded.
#   * A producer may delegate its scan to a job-level reusable-workflow call.
#     Then the artifact and the scanner pin live in the CALLED workflow, read
#     here at the full SHA the call pins (network, or EDGES_REUSABLE_DIR), and
#     the pin is the one the call passes (`with: hypatia-ref:`): a call that
#     passes none runs the reusable's own default, not the verdict's pin.
#
# Every check here is a rule about the pipeline's shape, not about the code
# under test, which is why it belongs beside `check-required-contexts.sh` in the
# squabble gate rather than in the manifest-janitor set.
#
# Exit contract (proven-tests-and-benches 3-outcome convention):
#   0 = every edge resolves and no tool is pinned twice
#   1 = a dead edge, an unproduced artifact, a stale pin, or a duplicate tool pin
#   2 = setup error (missing repo, workflows dir, or the reporter workflow; a
#       reusable producer not pinned to a full SHA, or not readable)
#
# Deliberately NOT checked: that a producer's gate is "right". Gating is each
# producer's own decision (see the header of fork-governance.yml); this script
# only checks that the reporting edges still point at something.
set -euo pipefail

REPO_ROOT="${1:-.}"
if [ ! -d "$REPO_ROOT" ]; then
  echo "check-workflow-edges: repo directory '$REPO_ROOT' does not exist" >&2
  exit 2
fi
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
REPORTER="$WORKFLOWS_DIR/fork-governance.yml"
PUBLISHER="$WORKFLOWS_DIR/verdict-grid-publish.yml"

if [ ! -d "$WORKFLOWS_DIR" ]; then
  echo "check-workflow-edges: workflows directory '$WORKFLOWS_DIR' does not exist" >&2
  exit 2
fi
if [ ! -f "$REPORTER" ]; then
  echo "check-workflow-edges: reporter workflow '$REPORTER' does not exist" >&2
  exit 2
fi
if [ ! -f "$PUBLISHER" ]; then
  echo "check-workflow-edges: publisher workflow '$PUBLISHER' does not exist" >&2
  exit 2
fi

# ── helpers ─────────────────────────────────────────────────────────────────
errors=0
fail() {
  echo "FAIL: $*" >&2
  errors=$((errors + 1))
}

# workflow_name FILE — the `name:` of a workflow, or empty for `name:` absent.
# Only the FIRST top-level `name:` is read: `on: push: ...` keys and job names
# are indented, and a workflow with no `name:` is identified by its path alone.
workflow_name() {
  awk '
    /^name:[[:space:]]*/ { sub(/^name:[[:space:]]*/, ""); gsub(/^["'"'"']|["'"'"']$/, ""); print; exit }
    /^[^[:space:]#]/ { next }
  ' "$1"
}

# produced_artifacts FILE — every artifact name an upload-artifact step writes.
produced_artifacts() {
  awk '
    /uses:[[:space:]]*actions\/upload-artifact@/ { in_upload = 1; next }
    in_upload && /^[[:space:]]*- name:/ { in_upload = 0 }
    in_upload && /^[[:space:]]*name:[[:space:]]/ {
      sub(/^[[:space:]]*name:[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; in_upload = 0
    }
  ' "$1"
}

# env_pin FILE VAR — the value of a `VAR:` line in the workflow's env blocks.
env_pin() {
  awk -v var="$2" '
    $0 ~ "^[[:space:]]*" var ":[[:space:]]" {
      sub("^[[:space:]]*" var ":[[:space:]]*", ""); gsub(/["'"'"']/, ""); print; exit
    }
  ' "$1"
}


# reusable_calls FILE — every job-level reusable-workflow call in FILE
# (`uses: OWNER/REPO/.github/workflows/X.yml@REF` outside every job's `steps:`
# block), one per line. A producer may delegate its scan to such a call, and
# the artifact it uploads and the scanner it pins then live in the called
# workflow, not in FILE.
reusable_calls() {
  awk '
    BEGIN { stepind = -1 }
    { line = $0; sub(/[[:space:]]+#.*$/, "", line) }
    line ~ /[^[:space:]]/ {
      match(line, /^[[:space:]]*/); ind = RLENGTH
      if (stepind >= 0 && ind <= stepind) stepind = -1
      if (line ~ /^[[:space:]]*steps:/) stepind = ind
    }
    stepind < 0 && line ~ /^[[:space:]]+uses:[[:space:]]*["\047]?[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/\.github\/workflows\/[^[:space:]@]+\.ya?ml@/ {
      sub(/^[[:space:]]*uses:[[:space:]]*/, "", line); gsub(/["\047]/, "", line); sub(/[[:space:]]+$/, "", line)
      print line
    }
  ' "$1"
}

# reusable_source CALL — prints the path of a local copy of the called
# workflow, read at the commit the call pins. Only a full 40-hex SHA is
# followed: a tag or branch could move between this check and the run.
# EDGES_REUSABLE_DIR (the tests) supplies copies offline as
# <dir>/OWNER/REPO/SHA/PATH; otherwise raw.githubusercontent.com serves them.
# A call that cannot be read is a setup error (exit 2), never a pass: the edge
# through it would be unverified.
reusable_cache="$(mktemp -d)"
reusable_source() {
  local call="$1" spec ref owner repo path out
  spec="${call%@*}"; ref="${call##*@}"
  owner="${spec%%/*}"; spec="${spec#*/}"; repo="${spec%%/*}"; path="${spec#*/}"
  if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    echo "check-workflow-edges: reusable call '${call}' is not pinned to a full commit SHA; what it uploads and pins cannot be checked" >&2
    return 2
  fi
  out="$reusable_cache/$owner/$repo/$ref/$path"
  if [ ! -f "$out" ]; then
    mkdir -p "$(dirname "$out")"
    if [ -n "${EDGES_REUSABLE_DIR:-}" ]; then
      if ! cp "$EDGES_REUSABLE_DIR/$owner/$repo/$ref/$path" "$out" 2>/dev/null; then
        echo "check-workflow-edges: reusable '${call}' is not in EDGES_REUSABLE_DIR" >&2
        return 2
      fi
    elif ! curl --proto =https --proto-redir =https -fsSL --retry 3 --max-time 30 "https://raw.githubusercontent.com/$owner/$repo/$ref/$path" -o "$out"; then
      echo "check-workflow-edges: could not read reusable '${call}' at its pinned commit; the edge through it cannot be verified" >&2
      return 2
    fi
  fi
  printf '%s' "$out"
}
# ── 1. workflow_run edges resolve to a workflow `name:` ─────────────────────
# `workflow_run: workflows:` is a YAML list under the trigger. Read it as text:
# the file is under this repository's control and a YAML parser is one more
# dependency for a check whose whole value is running where nothing else does.
edges="$(awk '
  /^on:/ { in_on = 1; next }
  /^[^[:space:]#]/ { in_on = 0 }
  in_on && /^[[:space:]]+workflow_run:/ { in_wr = 1; next }
  in_wr && /^[[:space:]]+workflows:/ { in_list = 1; next }
  in_list && /^[[:space:]]+- / {
    sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; next
  }
  in_list && !/^[[:space:]]+- / { in_list = 0; in_wr = 0 }
' "$PUBLISHER")"

if [ -z "$edges" ]; then
  fail "verdict-grid-publish.yml declares no workflow_run trigger: the verdict grid would never re-render after a scanner finishes"
fi

names_file="$(mktemp)"
trap 'rm -rf "$names_file" "$reusable_cache"' EXIT
for wf in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
  [ -e "$wf" ] || continue
  n="$(workflow_name "$wf")"
  [ -n "$n" ] || continue
  printf '%s\t%s\n' "$n" "$(basename "$wf")" >> "$names_file"
done

while IFS= read -r edge; do
  [ -n "$edge" ] || continue
  if ! cut -f1 "$names_file" | grep -qxF "$edge"; then
    fail "workflow_run edge '${edge}' names no workflow's name: — the grid will never re-render for it"
  fi
done <<< "$edges"

# Two files with the same `name:` means workflow_run fires for a workflow whose
# identity is ambiguous (and GitHub's UI shows two identical checks).
dupes="$(cut -f1 "$names_file" | sort | uniq -d)"
if [ -n "$dupes" ]; then
  fail "two or more workflows share a name: (${dupes//$'\n'/, }) — workflow_run cannot tell them apart"
fi

# ── 2. every evidence source is produced by the workflow it names ──────────
source_scan() {
  awk '/--source[[:space:]]/ { for (i = 1; i <= NF; i++) if ($i == "--source") { print $(i + 1); break } }' "$1"
}
sources_pr="$(source_scan "$REPORTER")"
sources_pub="$(source_scan "$PUBLISHER")"
[ -n "$sources_pr" ] || fail "fork-governance.yml collects no evidence (--source <workflow>:<artifact>) — the grid would have no rows"
[ -n "$sources_pub" ] || fail "verdict-grid-publish.yml collects no evidence (--source <workflow>:<artifact>) — published grid would have no rows"
sources="$(printf '%s\n%s\n' "$sources_pr" "$sources_pub" | sed '/^$/d' | sort -u)"

while IFS= read -r src; do
  [ -n "$src" ] || continue
  wf_file="${src%%:*}"
  artifact="${src#*:}"
  target="$WORKFLOWS_DIR/$wf_file"
  if [ ! -f "$target" ]; then
    fail "evidence source names '${wf_file}', which is not a workflow in .github/workflows/"
    continue
  fi
  if ! produced_artifacts "$target" | grep -qxF "$artifact"; then
    # The producer may delegate to a reusable workflow, which then uploads it.
    via=""
    while IFS= read -r call; do
      [ -n "$call" ] || continue
      src="$(reusable_source "$call")" || exit 2
      if produced_artifacts "$src" | grep -qxF "$artifact"; then via="$call"; break; fi
    done <<< "$(reusable_calls "$target")"
    [ -n "$via" ] || fail "evidence source '${wf_file}:${artifact}' names an artifact '${wf_file}' never uploads"
  fi
  if ! grep -Eq '^[[:space:]]+pull_request:' "$target"; then
    fail "'${wf_file}' does not run on pull_request, so its artifact exists only after a push"
  fi
done <<< "$sources"

# ── 3. the reporter's tool pins equal the producers' pins ──────────────────
# Tool pin in the reporter (grid identity) vs the pin in the workflow that
# actually runs that tool. A mismatch makes the profile hash disagree with the
# binary that produced the findings.
check_pin() { # check_pin REPORTER REPORT_FLAG PRODUCER VAR [INPUT]
  # INPUT: when PRODUCER delegates to a reusable workflow, the input through
  # which it passes the pin; the reusable's own default is not the verdict's.
  local report="$1" flag="$2" producer="$3" var="$4" input="${5:-}"
  local in_reporter in_producer pin_name="$var"
  in_reporter="$({ grep -o -- "${flag}[[:space:]]\\+[0-9a-f]\\{40\\}" "$report" || true; } | awk '{print $2}' | head -n1)"
  in_producer="$(env_pin "$WORKFLOWS_DIR/$producer" "$var" | head -n1)"
  if [ -z "$in_reporter" ]; then
    fail "$(basename "$report") names no ${flag}; its findings would carry no tool identity"
    return
  fi
  if [ -z "$in_producer" ] && [ -n "$input" ] && [ -n "$(reusable_calls "$WORKFLOWS_DIR/$producer")" ]; then
    in_producer="$(env_pin "$WORKFLOWS_DIR/$producer" "$input" | head -n1)"
    pin_name="with: $input"
    if [ -z "$in_producer" ]; then
      fail "'${producer}' calls a reusable workflow without passing ${input}, so the scan runs that workflow's default, not the ${flag} ${in_reporter:0:12} the verdict claims; pass 'with: ${input}: <sha>'"
      return
    fi
  fi
  if [ -z "$in_producer" ]; then
    fail "'${producer}' pins no ${var}, but the verdict claims ${flag} ${in_reporter:0:12}"
    return
  fi
  if [ "$in_reporter" != "$in_producer" ]; then
    fail "${flag} in $(basename "$report") (${in_reporter:0:12}) does not match ${pin_name} in ${producer} (${in_producer:0:12})"
  fi
}
for report in "$REPORTER" "$PUBLISHER"; do
  check_pin "$report" --hypatia-ref hypatia-scan.yml HYPATIA_SHA hypatia-ref
  check_pin "$report" --panic-ref static-analysis-gate.yml PANIC_ATTACK_SHA
  check_pin "$report" --pons-ref static-analysis-gate.yml PONS_SHA
done

# ── 4. no tool pinned at two commits in this repository ────────────────────
# panic-attack is pinned once for its scan and once for patch-bridge triage; the
# pair must agree, which is why both use env.PANIC_ATTACK_SHA. A literal second
# pin in another workflow is the clash this catches.
pins_file="$(mktemp)"
trap 'rm -rf "$names_file" "$pins_file" "$reusable_cache"' EXIT
for wf in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
  [ -e "$wf" ] || continue
  for var in HYPATIA_SHA HYPATIA_REF PANIC_ATTACK_SHA PONS_SHA; do
    v="$(env_pin "$wf" "$var" | head -n1)"
    [ -n "$v" ] || continue
    case "$v" in
      *'${{'* | 'latest' | 'HEAD') continue ;; # floating by design, documented at the pin
    esac
    printf '%s\t%s\t%s\n' "$var" "$v" "$(basename "$wf")" >> "$pins_file"
  done
  # A reusable call's hypatia-ref input pins the same scanner as HYPATIA_SHA.
  if [ -n "$(reusable_calls "$wf")" ]; then
    v="$(env_pin "$wf" hypatia-ref | head -n1)"
    case "$v" in
      "" | *'${{'* | 'latest' | 'HEAD') ;;
      *) printf '%s\t%s\t%s\n' HYPATIA_SHA "$v" "$(basename "$wf") (with: hypatia-ref)" >> "$pins_file" ;;
    esac
  fi
done
while IFS= read -r var; do
  [ -n "$var" ] || continue
  n="$(awk -F'\t' -v v="$var" '$1 == v {print $2}' "$pins_file" | sort -u | grep -c . || true)"
  if [ "$n" -gt 1 ]; then
    detail="$(awk -F'\t' -v v="$var" '$1 == v {printf "%s %s; ", substr($2, 1, 12), $3}' "$pins_file")"
    fail "${var} is pinned at ${n} different commits in this repository (${detail%; })"
  fi
done <<< "$(cut -f1 "$pins_file" | sort -u)"

# HYPATIA_SHA and HYPATIA_REF are two spellings of the same pin.
h_sha="$(env_pin "$WORKFLOWS_DIR/hypatia-scan.yml" HYPATIA_SHA | head -n1)"
h_ref="$(env_pin "$WORKFLOWS_DIR/hypatia-scan.yml" HYPATIA_REF | head -n1)"
if [ -n "$h_sha" ] && [ -n "$h_ref" ] && [ "$h_sha" != "$h_ref" ]; then
  fail "hypatia-scan.yml pins HYPATIA_SHA ${h_sha:0:12} and HYPATIA_REF ${h_ref:0:12}"
fi

# ── verdict ────────────────────────────────────────────────────────────────
if [ "$errors" -ne 0 ]; then
  echo "check-workflow-edges: ${errors} broken edge(s)" >&2
  exit 1
fi
echo "check-workflow-edges: all workflow edges resolve; $(printf '%s' "$edges" | grep -c . || true) workflow_run edge(s), $(printf '%s' "$sources" | grep -c . || true) evidence source(s)"
