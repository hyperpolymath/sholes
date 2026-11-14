#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# adopt-canon-lockstep.sh: give a minted repository this template's current
# Canon lockstep job and its decision script, and nothing else.
#
# WHY: instances minted before the job called scripts/canon-pin-check.sh carry
# an inline copy of it (9 distinct copies across 30 repos, census 2026-11-12).
# Those copies demand equality with the canon on standards main, so a canon
# release turns an instance red although its pin is provenance, "the canon
# release it was cut from" (repo-init.just). The template's job now passes an
# older pin with a notice (scripts/canon-pin-check.sh). Copying the whole
# dogfood-gate.yml would overwrite whatever else the instance changed, so only
# the `canon-lockstep:` job block is replaced.
#
# What it writes, and nothing else:
#   * the `canon-lockstep:` job in <repo>/.github/workflows/dogfood-gate.yml,
#     replaced by the template's own block (read from this checkout, so there
#     is one source);
#   * <repo>/scripts/canon-pin-check.sh, copied from this checkout.
#
# FAIL-CLOSED (exit 1, nothing written): no dogfood-gate.yml; more than one
# `canon-lockstep:` key; or a repo actions.lock whose dogfood-gate.yml entry
# does not already list every action the template block uses (the runner
# refuses a workflow whose actions the lock does not cover). A repo with no
# `canon-lockstep:` job is left alone (exit 0): this tool repairs the job, it
# does not add it.
#
# Usage: adopt-canon-lockstep.sh <repo-root>
# Exit:  0 adopted or already current or no job; 1 refused; 2 usage.
set -euo pipefail

TPL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -eq 1 ] && [ -d "$1" ] || { sed -n '25,26p' "$0" >&2; exit 2; }
REPO="$(cd "$1" && pwd)"
WF="$REPO/.github/workflows/dogfood-gate.yml"
LOCK="$REPO/.github/workflows/actions.lock"
refuse() { echo "adopt-canon-lockstep: REFUSED ($*); nothing written" >&2; exit 1; }

# The job key, plain or quoted, with an optional trailing comment.
START_RE="^  [\"']?canon-lockstep[\"']?:[[:space:]]*(#.*)?\$"

# job_block <file>: the canon-lockstep job, from its key to the line before
# the next key. Any non-comment line at two spaces of indent (the next job,
# however it is written: `build:`, `build: # note`, `"build":`) or at column
# 0 ends it. Comment and blank lines just before that boundary belong to the
# next job's header, so they are not part of this block.
job_block() {
  awk -v S="$START_RE" '
    !f && $0 ~ S { f = 1; print; next }
    f && (/^  [^ #]/ || /^[^ #]/) { exit }
    f && (/^ ?#/ || /^  #/ || /^[[:space:]]*$/) { buf = buf $0 "\n"; next }
    f { printf "%s", buf; buf = ""; print }' "$1"
}

[ -f "$WF" ] || refuse "no .github/workflows/dogfood-gate.yml"
n=$(grep -cE "$START_RE" "$WF" || true)
[ "$n" -le 1 ] || refuse "$n canon-lockstep jobs in dogfood-gate.yml"
[ "$n" -eq 1 ] || { echo "adopt-canon-lockstep: no canon-lockstep job; left alone"; exit 0; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
job_block "$TPL/.github/workflows/dogfood-gate.yml" > "$tmp/new"
[ -s "$tmp/new" ] || refuse "the template has no canon-lockstep job to copy"
# Trailing blank lines belong to the gap between jobs, not to the job.
sed -i -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$tmp/new"

# Every action the template block uses must already be locked for this workflow.
if [ -f "$LOCK" ]; then
  awk -v k="    '.github/workflows/dogfood-gate.yml':" '$0==k{f=1;next} f&&!/^        - /{exit} f' "$LOCK" \
    | grep -oE "'[^']+'" | tr -d "'" | awk '{i=index($0,"@"); print tolower(substr($0,1,i-1)) substr($0,i)}' \
    | sort -u > "$tmp/locked"
  grep -oE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}' "$tmp/new" \
    | sed -E 's/uses:[[:space:]]*//; s#^([^/]+/[^/@]+)[^@]*@#\1@#' \
    | awk '{i=index($0,"@"); print tolower(substr($0,1,i-1)) substr($0,i)}' | sort -u > "$tmp/needed"
  missing=$(comm -23 "$tmp/needed" "$tmp/locked" | tr '\n' ' ')
  [ -z "$missing" ] || refuse "actions.lock does not list for dogfood-gate.yml: ${missing% }"
fi

job_block "$WF" > "$tmp/old"
sed -i -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$tmp/old"
if cmp -s "$tmp/old" "$tmp/new" && cmp -s "$TPL/scripts/canon-pin-check.sh" "$REPO/scripts/canon-pin-check.sh" 2>/dev/null; then
  echo "adopt-canon-lockstep: already current"; exit 0
fi

# Replace the old block's lines with the new block, keeping everything else.
start=$(grep -nE "$START_RE" "$WF" | cut -d: -f1)
len=$(wc -l < "$tmp/old")
{ head -n "$((start - 1))" "$WF"; cat "$tmp/new"; tail -n +"$((start + len))" "$WF"; } > "$tmp/wf"
mkdir -p "$REPO/scripts"
cp "$tmp/wf" "$WF"
cp "$TPL/scripts/canon-pin-check.sh" "$REPO/scripts/canon-pin-check.sh"
chmod +x "$REPO/scripts/canon-pin-check.sh"
echo "adopt-canon-lockstep: canon-lockstep job and scripts/canon-pin-check.sh now match the template"
