#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# survey-template-damage.sh — which already-scaffolded repositories carry the
# damage this template shipped?
#
# A template defect is not one repository's problem. Every repository minted from
# the template while it shipped a nine-runtime `mise.toml`, a floating
# `Containerfile` and unfilled `{{TOKEN}}`s carries the same damage, permanently
# — the mint copies the files once and nothing goes back to fix them.
#
# This script takes repository names, clones each shallowly, and runs THIS
# template's gates against the clone. It is deliberately not a grep: the gates
# are the same code that a minted repository runs, so a repository reported
# clean here is clean by the same standard the next mint will be held to.
#
# Usage:
#   scripts/survey-template-damage.sh hyperpolymath/A.jl hyperpolymath/B.jl …
#   scripts/survey-template-damage.sh --from-search 'org:hyperpolymath filename:Justfile "sholes"'
#   options: --keep (leave the clones), --tsv (machine-readable table only)
#
# Exit: 0 survey completed (whatever it found); 1 could not complete; 2 usage.
# This is a survey: it never edits a repository.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATES_DIR="$SELF_DIR"
KEEP=0
TSV=0
QUERY=""
REPOS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        --tsv) TSV=1; shift ;;
        --from-search) QUERY="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "survey-template-damage: unknown option: $1" >&2; exit 2 ;;
        *) REPOS+=("$1"); shift ;;
    esac
done

if [ -n "$QUERY" ]; then
    command -v gh >/dev/null 2>&1 || { echo "survey: --from-search needs gh" >&2; exit 2; }
    # Code search caps at 100 items per page and 1000 results; that is enough for
    # an inventory, and the count printed below says when it is not.
    mapfile -t FOUND < <(gh api -X GET search/code -f q="$QUERY" -f per_page=100 \
        --jq '[.items[].repository.full_name] | unique | .[]' 2>/dev/null)
    TOTAL="$(gh api -X GET search/code -f q="$QUERY" --jq '.total_count' 2>/dev/null || echo '?')"
    echo "# search: $QUERY"
    echo "# search hits (files): $TOTAL; repositories listed: ${#FOUND[@]}"
    REPOS+=("${FOUND[@]}")
fi

if [ "${#REPOS[@]}" -eq 0 ]; then
    echo "survey-template-damage: no repositories given" >&2
    echo "  pass owner/name arguments, or --from-search '<github code search query>'" >&2
    exit 2
fi

WORK="$(mktemp -d)"
[ "$KEEP" -eq 1 ] && echo "# clones kept in $WORK" || trap 'rm -rf "$WORK"' EXIT

gate() { # $1 gate script, $2 repo dir, rest: extra gate args
    local script="$1" dir="$2"; shift 2
    local out st
    out="$(bash "$GATES_DIR/$script" --root "$dir" "$@" 2>&1)"; st=$?
    if [ "$st" -eq 0 ]; then printf 'CLEAN'; return; fi
    printf '%s' "$(printf '%s\n' "$out" \
        | sed -E 's/\x1b\[[0-9;]*m//g' \
        | grep -m1 -E '^ *FAIL' \
        | sed -E 's/^ *FAIL *//' | tr '\t' ' ')"
}

printf 'repo\tmise\tspdx\tpins\ttokens\n' 
for repo in "${REPOS[@]}"; do
    dir="$WORK/$(printf '%s' "$repo" | tr '/' '_')"
    if ! git clone --depth 1 --quiet "https://github.com/$repo.git" "$dir" 2>/dev/null; then
        printf '%s\tCLONE-FAILED\t-\t-\t-\n' "$repo"
        continue
    fi
    # --detect: these repositories were minted before the provisioning engine
    # shipped with them, so the gate detects the languages from markers.
    m="$(gate check-mise-language.sh "$dir" --detect)"
    s="$(gate check-spdx-headers.sh "$dir")"
    c="$(gate check-container-pins.sh "$dir")"
    t="$(gate check-mint-tokens.sh "$dir")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$m" "$s" "$c" "$t"
    # --keep exists so an operator can open the checkout behind a verdict. This
    # line deleted it anyway, leaving an empty directory and no way to reproduce
    # what the gate saw.
    [ "$KEEP" -eq 1 ] || rm -rf "$dir"
done
