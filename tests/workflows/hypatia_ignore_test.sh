#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing tests for scripts/check-hypatia-ignore.sh.
#
# Every rule the checker enforces is exercised twice: once on a fixture that
# satisfies it and once on a fixture that breaks exactly it. The real
# .hypatia-ignore must pass, because a checker that cannot pass is switched off.
set +e
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO_DIR/scripts/check-hypatia-ignore.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() {
    fail=$((fail + 1))
    echo "  FAIL: $1" >&2
    echo "::error::hypatia-ignore test failed: $1" # NOSONAR
}

# fixture NAME — a throwaway repo root with the files the entries name.
fixture() {
    local root="$WORK/$1"
    mkdir -p "$root/build/docs-seed" "$root/.github/workflows" "$root/lib/rules" "$root/docs"
    printf 'x\n' > "$root/.github/workflows/release.yml"
    printf 'x\n' > "$root/lib/rules/rule.ex"
    printf 'x\n' > "$root/docs/page.adoc"
    printf '%s' "$root"
}

run() { # run ROOT
    bash "$CHECK" "$1" >"$WORK/out" 2>&1
}

expect_rc() { # expect_rc RC LABEL ROOT
    local want="$1" label="$2" root="$3" got=0
    run "$root" || got=$?
    if [ "$got" -eq "$want" ]; then ok "$label"; else
        bad "$label (wanted exit ${want}, got ${got})"
        sed 's/^/        /' "$WORK/out"
    fi
}
says() { # says LABEL PATTERN
    if grep -Fq -- "$2" "$WORK/out"; then ok "$1"; else bad "$1 (no '$2' in output)"; sed 's/^/        /' "$WORK/out"; fi
}

echo "=== 1. The repository's own .hypatia-ignore ==="
root="$WORK/real"
mkdir -p "$root"
cp "$REPO_DIR/.hypatia-ignore" "$root/.hypatia-ignore"
# The entries name real paths, so the fixture mirrors them rather than mocking
# the existence test away.
mkdir -p "$root/build/docs-seed" "$root/.github/workflows"
for f in push-email-notify release build-notification dependabot-automerge label-triage labels sonarqube \
    security-policy quality dot-wellknown-enforcement static-analysis-gate; do
    printf 'x\n' > "$root/.github/workflows/$f.yml"
done
expect_rc 0 "the shipped .hypatia-ignore passes its own checker" "$root"

echo "=== 2. Rules that must fail ==="
# 2a. bare path: exempts every rule, which the format allows but the checker
#     refuses without a module/type selector.
root="$(fixture bare-path)"
printf '# a reason that is long enough\nbuild/docs-seed/\n' > "$root/.hypatia-ignore"
expect_rc 1 "a bare path is refused (it exempts every rule)" "$root"
says "the bare-path failure says why" "a bare path exempts every rule"

# 2b. selector shape
root="$(fixture bad-selector)"
printf '# reason\nnotamodule:lib/rules/\n' > "$root/.hypatia-ignore"
expect_rc 1 "a selector without <module>/<type> is refused" "$root"

# 2c. empty path
root="$(fixture empty-path)"
printf '# reason\nstructural_drift/SD022:\n' > "$root/.hypatia-ignore"
expect_rc 1 "an empty path fragment is refused" "$root"

# 2d. unbounded fragment
root="$(fixture unbounded)"
printf '# reason\nstructural_drift/SD022:lib\n' > "$root/.hypatia-ignore"
expect_rc 1 "an unbounded fragment is refused" "$root"
says "the unbounded-fragment failure names the substring problem" "raw substring match"

# 2e. stale path
root="$(fixture stale)"
printf '# reason\nstructural_drift/SD022:lib/gone/\n' > "$root/.hypatia-ignore"
expect_rc 1 "a fragment naming a path that no longer exists is refused" "$root"
says "the stale-path failure explains the rename case" "stale exemption"

# 2f. missing reason
root="$(fixture no-reason)"
{
    for i in $(seq 1 9); do echo "# filler line $i"; done
    echo ""
    echo "structural_drift/SD022:lib/rules/"
} > "$root/.hypatia-ignore"
expect_rc 1 "an entry whose nearest line above is blank-with-no-comment is refused" "$root"
says "the missing-reason failure says what is missing" "no stated reason"

# 2g. duplicate
root="$(fixture duplicate)"
{
    echo "# reason for both"
    echo "structural_drift/SD022:lib/rules/"
    echo "structural_drift/SD022:lib/rules/"
} > "$root/.hypatia-ignore"
expect_rc 1 "a duplicated entry is refused" "$root"
says "the duplicate failure names the entry" "duplicate entry"

# 2h. subsumption: the narrower entry can never fire
root="$(fixture subsumed)"
{
    echo "# directory-wide reason"
    echo "workflow_audit/*:.github/workflows/"
    echo "# narrower reason that is dead"
    echo "workflow_audit/WF013:.github/workflows/release.yml"
} > "$root/.hypatia-ignore"
expect_rc 1 "an entry subsumed by a broader one is refused" "$root"
says "the subsumption failure names the broader entry" "already covered by"

# 2i. two colons
root="$(fixture two-colons)"
printf '# reason\nstructural_drift/SD022:lib/rules:a\n' > "$root/.hypatia-ignore"
expect_rc 1 "a second ':' is refused" "$root"

echo "=== 3. Rules that must pass ==="
root="$(fixture minimal)"
{
    echo "# A directory exemption, which ends on a boundary."
    echo "structural_drift/SD022:build/docs-seed/"
    echo ""
    echo "# A file exemption, which cannot widen to sibling names."
    echo "workflow_audit/WF013:.github/workflows/release.yml"
    echo ""
    echo "# A module wildcard, bounded by a directory."
    echo "research_extensions/*:.github/workflows/"
} > "$root/.hypatia-ignore"
expect_rc 0 "bounded directory, file and wildcard entries all pass" "$root"

root="$(fixture grouped)"
{
    echo "# module A"
    echo "structural_drift/SD022:build/docs-seed/"
    echo "# module A again, same block"
    echo "structural_drift/SD001:lib/rules/"
    echo "# module B"
    echo "workflow_audit/WF013:.github/workflows/release.yml"
} > "$root/.hypatia-ignore"
expect_rc 0 "modules in one contiguous block pass" "$root"

root="$(fixture split-blocks)"
{
    echo "# module A first"
    echo "structural_drift/SD022:build/docs-seed/"
    echo "# module B"
    echo "workflow_audit/WF013:.github/workflows/release.yml"
    echo "# module A again"
    echo "structural_drift/SD001:lib/rules/"
} > "$root/.hypatia-ignore"
expect_rc 0 "a split block is a note, not a failure" "$root"
says "the split block is reported as a note" "reviewers do"

echo "=== 4. Setup errors ==="
expect_rc 2 "a missing repository directory is a setup error" "$WORK/does-not-exist"
root="$(fixture no-ignore)"; rm -f "$root/.hypatia-ignore"
expect_rc 2 "a missing .hypatia-ignore is a setup error" "$root"

echo "=== 5. Parsing and exemption boundaries ==="
root="$(fixture 'repo with spaces')"
# CRLF and an unterminated final line occur in hand-edited ignore files.
printf '# shared reason\r\nstructural_drift/SD022:lib/rules/\r\nstructural_drift/SD001:docs/page.adoc' > "$root/.hypatia-ignore"
expect_rc 0 "CRLF, a shared reason, spaces in the root and no final LF are accepted" "$root"

root="$(fixture final-line)"
printf '# reason\nstructural_drift/SD022:lib/gone/' > "$root/.hypatia-ignore"
expect_rc 1 "an unterminated invalid final entry is still checked" "$root"
says "the final-line diagnostic identifies the stale path" "path 'lib/gone/' does not exist"

root="$(fixture same-type-subsumption)"
printf '# reason\nworkflow_audit/WF013:.github/workflows/\nworkflow_audit/WF013:.github/workflows/release.yml\n' > "$root/.hypatia-ignore"
expect_rc 1 "a directory subsumes a narrower entry of the same type" "$root"
says "same-type subsumption identifies the broad entry" "already covered by workflow_audit/WF013:.github/workflows/"

root="$(fixture separate-selectors)"
printf '# independent rules\nworkflow_audit/WF001:.github/workflows/\nworkflow_audit/WF013:.github/workflows/release.yml\nresearch_extensions/*:.github/workflows/release.yml\n' > "$root/.hypatia-ignore"
expect_rc 0 "a broader path cannot suppress another type or module" "$root"

root="$(fixture wildcard-narrower)"
printf '# distinct scopes\nworkflow_audit/WF013:.github/workflows/\nworkflow_audit/*:.github/workflows/release.yml\n' > "$root/.hypatia-ignore"
expect_rc 0 "one broad rule type does not subsume a narrower all-types exemption" "$root"

root="$(fixture substring-subsummation)"
mkdir -p "$root/nested/lib/rules"
printf '# Hypatia matches substrings rather than rooted prefixes\nstructural_drift/SD022:lib/rules/\nstructural_drift/SD022:nested/lib/rules/\n' > "$root/.hypatia-ignore"
expect_rc 1 "subsumption includes an embedded path fragment" "$root"
says "embedded fragment is reported as already covered" "already covered by structural_drift/SD022:lib/rules/"

echo "=== 6. Reason blocks and selector identity ==="
root="$(fixture reason-reset)"
printf '# first block only\nstructural_drift/SD022:lib/rules/\n\nworkflow_audit/WF013:.github/workflows/release.yml\n' > "$root/.hypatia-ignore"
expect_rc 1 "a reason cannot carry over a blank line into the next block" "$root"
says "the unexplained entry is identified by line and selector" "line 4: 'workflow_audit/WF013:.github/workflows/release.yml' has no stated reason"

root="$(fixture reason-renewed)"
printf '# first block\nstructural_drift/SD022:lib/rules/\n\n# second block\nworkflow_audit/WF013:.github/workflows/release.yml\n' > "$root/.hypatia-ignore"
expect_rc 0 "a new reason after a blank line opens an independent block" "$root"

root="$(fixture same-path-selectors)"
printf '# Independent rules may exempt the same file\nworkflow_audit/WF013:docs/page.adoc\nworkflow_audit/WF014:docs/page.adoc\nstructural_drift/SD022:docs/page.adoc\n' > "$root/.hypatia-ignore"
expect_rc 0 "duplicate detection includes both the module and the rule type" "$root"

for selector in Workflow_audit/WF013 workflow_audit/ workflow_audit/WF-013; do
    root="$(fixture invalid-selector)"
    printf '# reason\n%s:docs/page.adoc\n' "$selector" > "$root/.hypatia-ignore"
    expect_rc 1 "an invalid selector is refused: $selector" "$root"
    says "the invalid selector is named precisely" "selector '$selector' is not"
done

echo ""
if [ "$fail" -ne 0 ]; then
    echo "FAIL: hypatia-ignore meta-rule suite (${pass} passed, ${fail} failed)" >&2
    exit 1
fi
echo "PASS: hypatia-ignore meta-rule suite (${pass} checks)"
