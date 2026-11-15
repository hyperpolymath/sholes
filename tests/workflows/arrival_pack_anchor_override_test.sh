#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# arrival_pack_anchor_override_test.sh — controls for the "Anchor override"
# line of the CLAUDE.md arrival pack (.machine_readable/arrival-pack/).
#
# An anchor overrides the estate language policy in two ways: it forbids what
# the estate permits, and it allows what the estate denies. The engine once
# rendered only the first, so a repo whose anchor allowed a denied language
# still told its agents the estate denial applied (Codex review of sholes#13).
# Each case renders the engine over a fixture and reads the one line.
#
# Requires nickel and jq. Exit: 0 all controls hold; 1 a control failed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AP="$REPO_DIR/.machine_readable/arrival-pack"
for tool in nickel jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool is required" >&2; exit 1; }
done
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The fixture is this repo's own extract, so every field the engine reads is
# present; only the two anchor lists are replaced per case.
BASE="$WORK/base.json"
bash "$AP/extract.sh" "$REPO_DIR" > "$BASE" || { echo "FAIL: extract.sh did not run" >&2; exit 1; }

FAILED=0
CHECKS=0
# render ALLOWED_JSON FORBIDDEN_JSON -> the rendered region on stdout
render() {
    local allowed="$1" forbidden="$2" dir="$WORK/case.$CHECKS"
    mkdir -p "$dir"
    cp "$AP/arrival-pack.ncl" "$dir/"
    jq -cS --argjson a "$allowed" --argjson f "$forbidden" '.anchor_allowed = $a | .anchor_forbidden = $f' \
        "$BASE" > "$dir/claude-md-data.json"
    nickel export --format raw "$dir/arrival-pack.ncl"
}
# check LABEL ALLOWED_JSON FORBIDDEN_JSON EXPECTED_LINE ("" = no override line)
check() {
    local label="$1" want="$4" out line count
    CHECKS=$((CHECKS + 1))
    out="$(render "$2" "$3" 2>&1)" || { FAILED=$((FAILED + 1)); echo "  FAIL  $label (engine did not render)"; echo "$out" | sed 's/^/        /'; return; }
    count="$(grep -c -- '- \*\*Anchor override\*\*' <<<"$out")"
    line="$(grep -- '- \*\*Anchor override\*\*' <<<"$out")"
    if [[ -z "$want" && "$count" -eq 0 ]]; then
        echo "  PASS  $label"
    elif [[ -n "$want" && "$count" -eq 1 && "$line" == "$want" ]]; then
        echo "  PASS  $label"
    else
        FAILED=$((FAILED + 1)); echo "  FAIL  $label"
        echo "        want: ${want:-<no Anchor override line>}"
        echo "        got ($count line(s)): $line"
    fi
}

LEAD="- **Anchor override** (ANCHOR) — This repo's anchor"
TAIL="The anchor overrides the estate policy above."

check "no lists: no override line" '[]' '[]' ""
check "forbids only: the wording minted repos already carry" \
    '[]' '["Node.js","npm"]' \
    "$LEAD forbids: Node.js, npm. $TAIL"
check "allowed languages the estate does not deny are no override" \
    '["Rust","Idris2","Zig"]' '["Node.js","npm"]' \
    "$LEAD forbids: Node.js, npm. $TAIL"
check "allows a denied language: it is named" \
    '["Rust","Go"]' '[]' \
    "$LEAD allows, where the estate policy above denies: Go. $TAIL"
check "allows a denied language and forbids: both are named" \
    '["Go","Rust","Python"]' '["Node.js","npm"]' \
    "$LEAD allows, where the estate policy above denies: Go, Python; it forbids: Node.js, npm. $TAIL"
check "allowed but not denied, nothing forbidden: no override line" \
    '["Rust","Zig"]' '[]' ""

# The deny list is stated once in the engine: the policy line prints the same
# list the override compares against.
CHECKS=$((CHECKS + 1))
if render '[]' '[]' 2>/dev/null | grep -qF 'Deny: **Nix, Python, Go, TypeScript, ReScript, AGPL**. (Guix, not Nix.)'; then
    echo "  PASS  the language-policy line prints the estate deny list"
else
    FAILED=$((FAILED + 1)); echo "  FAIL  the language-policy line prints the estate deny list"
fi

echo "$CHECKS controls, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
