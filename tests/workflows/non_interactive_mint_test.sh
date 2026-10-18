#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The non-interactive mint (RSR_NON_INTERACTIVE=1, answers in the
# environment) is the path scaffoldia, CI and agents use. It never completed:
# a `read() { return 0; }` shim left unanswered prompts unset, so `set -u`
# killed the mint, and turned the substitution `while read` loops into
# infinite loops. The e2e test drives only the interactive path, so nothing
# noticed. This drives every prompt non-interactively up to "Proceed?" and
# answers no, so it writes nothing and runs in seconds.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
cd "$repo"
recipe=build/just/repo-init.just
cfg=$(mktemp -d); trap 'rm -rf "$cfg"' EXIT
before=$(git status --porcelain --untracked-files=all)
# 1. No shim may shadow the builtin the recipe's loops depend on.
if grep -nE '^[[:space:]]*read[[:space:]]*\(\)' "$recipe"; then
    echo "FAIL: $recipe defines a read() function; it shadows the loops' read" >&2; exit 1
fi
# 2. Required answers only, then decline: every prompt resolves from the
#    environment without stdin and without tripping `set -u`.
out=$(env -i PATH="$PATH" HOME="$cfg" XDG_CONFIG_HOME="$cfg" RSR_NON_INTERACTIVE=1 \
    PROJECT_NAME="Mint Check" REPO=mint-check OWNER=example-owner \
    AUTHOR="Example Author" AUTHOR_EMAIL=author@example.org CONFIRM=n \
    timeout 120 just repo-init </dev/null 2>&1) || { echo "$out" >&2; echo "FAIL: non-interactive mint did not reach Proceed?" >&2; exit 1; }
grep -q '^Aborted\.$' <<<"$out" || { echo "$out" >&2; echo "FAIL: expected the declined mint to abort cleanly" >&2; exit 1; }
# 3. A missing required answer fails loudly, by name, not as an unbound variable.
if out=$(env -i PATH="$PATH" HOME="$cfg" XDG_CONFIG_HOME="$cfg" RSR_NON_INTERACTIVE=1 \
    REPO=mint-check OWNER=example-owner AUTHOR="Example Author" \
    AUTHOR_EMAIL=author@example.org timeout 120 just repo-init </dev/null 2>&1); then
    echo "FAIL: a mint without PROJECT_NAME succeeded" >&2; exit 1
fi
grep -q 'Error: project name required' <<<"$out" || { echo "$out" >&2; echo "FAIL: missing PROJECT_NAME did not fail by name" >&2; exit 1; }
if grep -q 'unbound variable' <<<"$out"; then echo "$out" >&2; echo "FAIL: unbound variable" >&2; exit 1; fi
# 4. Nothing was written (compared with the tree as this test found it).
[ "$(git status --porcelain --untracked-files=all)" = "$before" ] || { git status --short >&2; echo "FAIL: the declined mint modified the tree" >&2; exit 1; }
echo 'PASS: non-interactive prompts resolve from the environment; missing answers fail by name; no read() shim'
