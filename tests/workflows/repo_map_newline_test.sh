#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# gen-repo-map.sh builds the map from lines, so a path holding a newline would
# be mapped as two bogus entries (Codex review of #277). It is refused by name,
# in both modes; a repository without one is not.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g0() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

R="$work/r"
g0 init -q "$R"
mkdir -p "$R/notes"; printf 'x\n' > "$R/notes/plain.txt"
g0 -C "$R" add -A
for mode in "" --worktree; do
    # Control: no such path, no such refusal (whatever else the run reports).
    if bash "$repo/scripts/gen-repo-map.sh" $mode "$R" 2>"$work/err" >/dev/null || true; then :; fi
    if grep -q 'containing a newline' "$work/err"; then fail "refused a repository with no newline path (mode '${mode:-index}')"; fi
done
printf 'y\n' > "$R/notes/a
b"
g0 -C "$R" add -A
for mode in "" --worktree; do
    rc=0; bash "$repo/scripts/gen-repo-map.sh" $mode "$R" 2>"$work/err" >/dev/null || rc=$?
    [ "$rc" -eq 2 ] && grep -q 'containing a newline' "$work/err" && grep -qF 'notes/a\nb' "$work/err" \
        || { cat "$work/err" >&2; fail "a newline path was not refused by name (mode '${mode:-index}', exit $rc)"; }
done
echo 'PASS: gen-repo-map.sh refuses a path holding a newline, by name, in both modes'
