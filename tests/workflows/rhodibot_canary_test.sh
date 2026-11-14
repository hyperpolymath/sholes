#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The Rhodibot canary fails the run when it would create or delete a file. Its
# would-create rule asked for CONTRIBUTING.md only, so a repository whose guide
# is CONTRIBUTING.adoc (the estate writes prose in AsciiDoc) tripped it every
# week. This runs the canary's own script, taken from the workflow, on
# fixtures: an .adoc guide is enough, either form at the root or in .github/;
# no guide at all, and both forms at once, still trip it.
set -euo pipefail
yq --version 2>&1 | grep -q mikefarah || { echo "FAIL: this test needs Mike Farah yq (Go, 4.53.3+); the yq on PATH is a different tool" >&2; exit 1; }
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
yq '.jobs.canary.steps[] | select(.name == "Rhodibot — detect drift (no mutations)") | .run' \
    "$repo/.github/workflows/rsr-compliance-canary.yml" > "$work/canary.sh"
grep -q 'CONTRIBUTING' "$work/canary.sh" || fail 'fixture: the canary step was not extracted'

# fixture NAME FILES… — a repository that is clean but for its guide.
fixture() {
    local d="$work/$1"; shift
    mkdir -p "$d/.github"
    : > "$d/x_chora.deed"; : > "$d/LICENSE"; : > "$d/README.adoc"; : > "$d/SECURITY.md"
    local f; for f in "$@"; do : > "$d/$f"; done
    echo "$d"
}
# run DIR — the canary's exit status; its output in $work/out.
run() { (cd "$1" && GITHUB_STEP_SUMMARY=/dev/null bash "$work/canary.sh") > "$work/out" 2>&1; }

for guide in CONTRIBUTING.adoc .github/CONTRIBUTING.adoc CONTRIBUTING.md .github/CONTRIBUTING.md; do
    d=$(fixture "ok-${guide//\//_}" "$guide")
    run "$d" || { cat "$work/out" >&2; fail "the canary tripped on a repository whose guide is $guide"; }
done
echo 'PASS: a CONTRIBUTING guide in AsciiDoc or Markdown, at the root or in .github/, is not drift'

d=$(fixture none)
if run "$d"; then fail 'the canary passed a repository with no CONTRIBUTING guide'; fi
grep -q 'no CONTRIBUTING.adoc or CONTRIBUTING.md (would be created)' "$work/out" || { cat "$work/out" >&2; fail 'the missing guide was not named'; }
d=$(fixture both CONTRIBUTING.adoc CONTRIBUTING.md)
if run "$d"; then fail 'the canary passed both CONTRIBUTING.md and CONTRIBUTING.adoc'; fi
grep -q 'duplicate CONTRIBUTING.md + CONTRIBUTING.adoc' "$work/out" || { cat "$work/out" >&2; fail 'the duplicate guide was not named'; }
echo 'PASS: (-) no guide, and both forms at once, still trip the canary'

# This repository itself is clean.
(cd "$repo" && GITHUB_STEP_SUMMARY=/dev/null bash "$work/canary.sh") > "$work/out" 2>&1 \
    || { cat "$work/out" >&2; fail 'the canary trips on this repository'; }
echo 'PASS: the canary is clean on this repository'
