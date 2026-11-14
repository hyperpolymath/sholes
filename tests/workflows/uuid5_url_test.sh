#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The repo uuid is a function of its name, so it must be the same on every
# machine: a mint without uuidgen once rendered UNASSIGNED and the drift
# gate's replay (which has uuidgen) reported the unchanged child as drift
# (Codex review of #275). scripts/uuid5-url.sh derives it with whichever SHA-1
# tool is installed; each must give util-linux uuidgen's answer, and with
# none it must refuse, never print something uuid-shaped.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
bash_bin=$(command -v bash)

# Fixed vectors, from `uuidgen --sha1 --namespace @url --name NAME` (util-linux
# 2.39), so the test holds where uuidgen is absent.
names=("github.com/metadatastician/lintel" "github.com/a b/ü&x" "gitlab.com/x/y.jl")
want=(9ff6d785-9049-588c-b2b9-58ba6b791579 7471e3e9-0030-54f9-acac-9b67c9f2a178 b9e0966d-05b0-5e75-952e-30961f73de6f)

tested=0
for tool in sha1sum shasum openssl; do
    src=$(command -v "$tool" 2>/dev/null) || { echo "SKIP: $tool not installed"; continue; }
    # A PATH holding this one SHA-1 tool and nothing else the script could use.
    shim="$work/only-$tool"; mkdir -p "$shim"; ln -s "$src" "$shim/$tool"
    for i in "${!names[@]}"; do
        got=$(PATH="$shim" "$bash_bin" "$repo/scripts/uuid5-url.sh" "${names[$i]}") \
            || fail "uuid5-url.sh failed with only $tool"
        [ "$got" = "${want[$i]}" ] || fail "with only $tool, '${names[$i]}' gave $got, not ${want[$i]}"
        if command -v uuidgen >/dev/null 2>&1 && uuidgen --sha1 --namespace @url --name x >/dev/null 2>&1; then
            [ "$got" = "$(uuidgen --sha1 --namespace @url --name "${names[$i]}")" ] \
                || fail "with only $tool, '${names[$i]}' differs from this machine's uuidgen"
        fi
    done
    tested=$((tested + 1))
done
[ "$tested" -gt 0 ] || fail "no SHA-1 tool was available to test with"
echo "PASS: uuid5-url.sh equals uuidgen --sha1 --namespace @url with each of $tested SHA-1 tool(s)"

# Negative control: no SHA-1 tool at all is a refusal (exit 2), not a guess.
mkdir -p "$work/none"
rc=0; out=$(PATH="$work/none" "$bash_bin" "$repo/scripts/uuid5-url.sh" github.com/o/r 2>"$work/err") || rc=$?
[ "$rc" -eq 2 ] && [ -z "$out" ] && grep -q 'needs sha1sum, shasum or openssl' "$work/err" \
    || fail "with no SHA-1 tool it exited $rc and printed '$out'"
echo "PASS: with no SHA-1 tool, uuid5-url.sh refuses (exit 2) and prints nothing"

# deed-field.sh --uuid falls back to the same derivation where uuidgen cannot
# do it (macOS's uuidgen has no --sha1): a uuidgen that fails is shadowed here.
src=$(command -v sha1sum 2>/dev/null || command -v shasum 2>/dev/null || command -v openssl)
d="$work/df"; mkdir -p "$d/bin"
ln -s "$src" "$d/bin/$(basename "$src")"
for t in bash awk sed grep tr cat dirname head basename; do ln -s "$(command -v "$t")" "$d/bin/$t"; done
printf '#!%s\nexit 1\n' "$bash_bin" > "$d/bin/uuidgen"; chmod +x "$d/bin/uuidgen"
printf '(repo-deed\n  :repo-uuid #u5"github.com/metadatastician/lintel")\n' > "$d/x_chora.deed"
got=$(PATH="$d/bin" "$bash_bin" "$repo/scripts/deed-field.sh" --uuid "$d/x_chora.deed" 2>"$work/err") \
    || { cat "$work/err" >&2; fail "deed-field.sh --uuid failed without a --sha1 uuidgen"; }
[ "$got" = "${want[0]}" ] || fail "deed-field.sh --uuid gave $got, not ${want[0]}"
echo "PASS: deed-field.sh --uuid uses the same derivation when uuidgen cannot"
