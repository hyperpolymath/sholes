#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The chora id is minted once from the birth path (standards A1 V8, A7 J11):
# scripts/uuid-v8.sh must give standards scripts/uuid-v8.js's profile C answer
# with each SHA-256 tool, refuse with none, and deed-field.sh --uuid must print
# a #uuid literal's body as written, never re-derive it.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
bash_bin=$(command -v bash)

# Fixed vectors: the independent oracle of standards tools/uuid-v8 (sha256sum
# and shell nibble arithmetic), plus this template's own birth path.
domains=(gv-clade-index gv-clade-index d d echidna-goal)
names=("github.com/hyperpolymath/standards" "github.com/hyperpolymath/rsr-template-repo" "" "a:b c" "é✓")
want=(b32d6be4-73ba-873e-9d61-e57f43c75cd1 8e515699-3fb9-8785-8883-ef2a100c2e02
      394e0f7e-2f80-8af2-b682-28464ce30d58 ca23a717-72b1-8d99-94c5-e32a4fda7acd
      939052b9-3381-8187-9199-1960e0a527a4)

tested=0
for tool in sha256sum shasum openssl; do
    src=$(command -v "$tool" 2>/dev/null) || { echo "SKIP: $tool not installed"; continue; }
    shim="$work/only-$tool"; mkdir -p "$shim"; ln -s "$src" "$shim/$tool"
    # shasum is a perl script; give it perl when it is the one under test.
    [ "$tool" != shasum ] || { p=$(command -v perl) && ln -s "$p" "$shim/perl"; }
    for i in "${!names[@]}"; do
        got=$(PATH="$shim" "$bash_bin" "$repo/scripts/uuid-v8.sh" "${domains[$i]}" "${names[$i]}") \
            || fail "uuid-v8.sh failed with only $tool"
        [ "$got" = "${want[$i]}" ] || fail "with only $tool, ${domains[$i]}:${names[$i]} gave $got, not ${want[$i]}"
    done
    tested=$((tested + 1))
done
[ "$tested" -gt 0 ] || fail "no SHA-256 tool was available to test with"
echo "PASS: uuid-v8.sh equals the standards profile C oracle with each of $tested SHA-256 tool(s)"

# Negative controls: no SHA-256 tool, and a domain holding ":", are refusals.
mkdir -p "$work/none"
rc=0; out=$(PATH="$work/none" "$bash_bin" "$repo/scripts/uuid-v8.sh" d x 2>"$work/err") || rc=$?
[ "$rc" -eq 2 ] && [ -z "$out" ] && grep -q 'needs sha256sum, shasum or openssl' "$work/err" \
    || fail "with no SHA-256 tool it exited $rc and printed '$out'"
rc=0; out=$("$bash_bin" "$repo/scripts/uuid-v8.sh" 'a:b' x 2>/dev/null) || rc=$?
[ "$rc" -eq 2 ] && [ -z "$out" ] || fail "a domain with ':' exited $rc and printed '$out'"
echo "PASS: uuid-v8.sh refuses (exit 2) with no SHA-256 tool and with a ':' in the domain"

# deed-field.sh --uuid prints a #uuid body as written: no tool is consulted.
d="$work/df"; mkdir -p "$d/bin"
for t in bash awk sed grep tr cat dirname head basename; do ln -s "$(command -v "$t")" "$d/bin/$t"; done
printf '(repo-deed\n  :repo-uuid #uuid"%s")\n' "${want[1]}" > "$d/x_chora.deed"
got=$(PATH="$d/bin" "$bash_bin" "$repo/scripts/deed-field.sh" --uuid "$d/x_chora.deed" 2>"$work/err") \
    || { cat "$work/err" >&2; fail "deed-field.sh --uuid failed on a #uuid literal"; }
[ "$got" = "${want[1]}" ] && [ ! -s "$work/err" ] || fail "deed-field.sh --uuid gave '$got' for a #uuid literal"
echo "PASS: deed-field.sh --uuid prints a #uuid body as written, with no hashing tool"

# An uppercase or v4 body is refused, never normalised.
# Built from the oracle so no non-v8 literal sits in this file (ADR-008 gate).
for bad in "$(printf %s "${want[1]}" | tr a-f A-F)" "${want[1]/-8785-/-4785-}"; do
    printf '(repo-deed\n  :repo-uuid #uuid"%s")\n' "$bad" > "$d/x_chora.deed"
    rc=0; "$bash_bin" "$repo/scripts/deed-field.sh" --uuid "$d/x_chora.deed" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "deed-field.sh --uuid accepted $bad (exit $rc)"
done
echo "PASS: deed-field.sh --uuid refuses an uppercase or version 4 body"

# A legacy #u8 literal is derived through uuid-v8.sh, with a note on stderr.
printf '(repo-deed\n  :repo-uuid #u8"gv-clade-index:%s")\n' "${names[0]}" > "$d/x_chora.deed"
got=$("$bash_bin" "$repo/scripts/deed-field.sh" --uuid "$d/x_chora.deed" 2>"$work/err") || fail "#u8 legacy literal failed"
[ "$got" = "${want[0]}" ] && grep -q 'legacy #u8' "$work/err" || fail "#u8 gave '$got'"
echo "PASS: deed-field.sh --uuid derives a legacy #u8 literal and says so"
