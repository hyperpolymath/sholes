#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# mint_tools_preflight_test.sh — `just repo-init` must refuse, before writing
# anything, when nickel or a KYAML-capable yq is missing. It used to fail after
# rewriting 100+ files. Each control has a failing and a passing fixture:
#   1. scripts/check-mint-tools.sh: no nickel            -> exit 1, names nickel
#   2. scripts/check-mint-tools.sh: old/non-KYAML yq     -> exit 1, names yq
#   3. scripts/check-mint-tools.sh: both missing         -> exit 1, names both
#   4. scripts/check-mint-tools.sh: both present         -> exit 0
#   5. just repo-init, both missing                      -> non-zero, tree unchanged
# Control 5 needs a mintable tree (the template itself); in a minted child it is
# reported as not run, never as a pass.
#
# Usage: bash tests/workflows/mint_tools_preflight_test.sh
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# A PATH holding every tool on the caller's PATH EXCEPT yq and nickel, so a
# fixture decides alone whether either exists.
base="$work/base"; mkdir -p "$base"
IFS=: read -ra _dirs <<<"$PATH"
for d in "${_dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        n="${f##*/}"
        case "$n" in yq|nickel) continue ;; esac
        [ -x "$f" ] && [ ! -e "$base/$n" ] && ln -s "$f" "$base/$n"
    done
done
fake() { # fake DIR NAME BODY
    mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"
}
fake "$work/good" yq 'case "$1" in --version) echo "yq (https://github.com/mikefarah/yq/) version v4.53.3"; exit 0 ;; esac; cat >/dev/null; exit 0'   # models mikefarah yq
fake "$work/good" nickel 'exit 0'
fake "$work/oldyq" yq 'exit 1'          # a yq that cannot write KYAML
fake "$work/foreignyq" yq 'case "$1" in --version) echo "yq 3.4.1"; exit 0 ;; esac; cat >/dev/null; exit 0'   # writes KYAML but is not mikefarah yq

check() { # check PATHDIRS... -> runs the script with PATH=<dirs>:base
    local p="$base"; for d in "$@"; do p="$d:$p"; done
    PATH="$p" bash "$repo/scripts/check-mint-tools.sh" "$repo" 2>&1
}

mkdir -p "$work/yqonly"; cp "$work/good/yq" "$work/yqonly/"
out="$(check "$work/yqonly")"; st=$?
if [ "$st" -ne 0 ] && grep -q 'nickel' <<<"$out" && ! grep -q '  - yq' <<<"$out"; then ok "no nickel: refused, nickel named"; else bad "no nickel: expected exit 1 naming only nickel (got $st): $out"; fi

mkdir -p "$work/nickelonly"; cp "$work/good/nickel" "$work/nickelonly/"
out="$(check "$work/nickelonly")"; st=$?
if [ "$st" -ne 0 ] && grep -q '  - yq' <<<"$out" && ! grep -q '  - nickel' <<<"$out"; then ok "no yq: refused, yq named"; else bad "no yq: expected exit 1 naming only yq (got $st): $out"; fi

mkdir -p "$work/oldyq2"; cp "$work/oldyq/yq" "$work/oldyq2/"; cp "$work/good/nickel" "$work/oldyq2/"
out="$(check "$work/oldyq2")"; st=$?
if [ "$st" -ne 0 ] && grep -q '  - yq' <<<"$out" && grep -q '>= ' <<<"$out"; then ok "old yq: refused, required version printed"; else bad "old yq: expected exit 1 naming yq and a version (got $st): $out"; fi

mkdir -p "$work/foreignyq2"; cp "$work/foreignyq/yq" "$work/foreignyq2/"; cp "$work/good/nickel" "$work/foreignyq2/"
out="$(check "$work/foreignyq2")"; st=$?
if [ "$st" -ne 0 ] && grep -q "  - yq" <<<"$out" && ! grep -q "  - nickel" <<<"$out"; then ok "foreign yq (not mikefarah): refused, yq named"; else bad "foreign yq: expected exit 1 naming only yq (got $st): $out"; fi

out="$(check)"; st=$?
if [ "$st" -ne 0 ] && grep -q '  - yq' <<<"$out" && grep -q '  - nickel' <<<"$out" && grep -q 'mise' <<<"$out"; then ok "both missing: every missing tool listed, provision named"; else bad "both missing: expected both named (got $st): $out"; fi

out="$(check "$work/good")"; st=$?
if [ "$st" -eq 0 ]; then ok "both present: accepted"; else bad "both present: expected exit 0 (got $st): $out"; fi

# 5. The real recipe, with neither tool, must stop with the tree untouched.
cd "$repo" || exit 1
if [ ! -f build/templates/identity.deed.in ]; then
    echo "  NOT RUN  recipe control: this tree is a minted child, not a mintable template"
else
    before="$(git status --porcelain --untracked-files=all)"
    cfg="$work/cfg"; mkdir -p "$cfg"
    out="$(env -i PATH="$base" HOME="$cfg" XDG_CONFIG_HOME="$cfg" RSR_NON_INTERACTIVE=1 \
        PROJECT_NAME="Mint Check" REPO=mint-check OWNER=example-owner \
        AUTHOR="Example Author" AUTHOR_EMAIL=author@example.org CONFIRM=y \
        timeout 120 just repo-init </dev/null 2>&1)"; st=$?
    after="$(git status --porcelain --untracked-files=all)"
    if [ "$st" -ne 0 ] && grep -q 'mint aborted before writing anything — missing tool' <<<"$out"; then
        ok "just repo-init without nickel/yq: refused by the preflight"
    else
        bad "just repo-init without nickel/yq: expected the preflight refusal (exit $st): $(tail -5 <<<"$out")"
    fi
    if [ "$before" = "$after" ]; then ok "just repo-init without nickel/yq: tree unchanged"; else bad "tree changed"; fi
fi

[ "$fails" -eq 0 ] && { echo "mint_tools_preflight_test: all controls hold"; exit 0; }
echo "mint_tools_preflight_test: $fails control(s) failed" >&2; exit 1
