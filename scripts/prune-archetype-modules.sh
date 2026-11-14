#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# prune-archetype-modules.sh — remove the spine modules an archetype does not
# declare, so a mint carries only what its preset can honestly claim.
#
# ── Why this exists ─────────────────────────────────────────────────────────
#
# The spine is polyglot ON PURPOSE: it carries the ABI/FFI seam, the container
# module and the dev container so that SOME repository minted from it can use
# them. Carrying is the spine's job (standards' template-capability-gates calls
# it the `[carrier]` section). A CHILD carrying them without the capability is
# drift, and two of those modules are not harmless:
#
#   * `build/container/` is a deployed artifact. Shipping it to a Julia library
#     makes that library fail `container-images-pinned` from birth until someone
#     pins a digest it does not need; before that it fails with a floating
#     `:latest`, which is how the downstream repos got the defect.
#   * anything Python-adjacent would be a policy violation outright.
#
# So an archetype declares what it drops, as data, in:
#
#     archetypes/<name>/prune.txt      one repository-relative path per line
#
# and this script applies it. Paths are removed only if present; a listed path
# that is absent is not an error (the spine may stop shipping a module), but it
# IS reported, because a stale prune entry means the archetype's record is out
# of date.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   prune-archetype-modules.sh <archetype-dir> [tree-root ...]
#
# Prints the paths it removed, one per line, so the caller can record them in
# the child's provenance ((variant (paths :removed …))).
#
# Exit: 0 = applied (possibly nothing to do); 2 = usage error.

set -uo pipefail

ARCH="${1:-}"
[ -n "$ARCH" ] || { echo "usage: prune-archetype-modules.sh <archetype-dir> [tree-root ...]" >&2; exit 2; }
shift
[ -d "$ARCH" ] || { echo "prune-archetype-modules: not a directory: $ARCH" >&2; exit 2; }

LIST="$ARCH/prune.txt"
[ -f "$LIST" ] || exit 0

[ $# -gt 0 ] || set -- .

for root in "$@"; do
    [ -d "$root" ] || { echo "prune-archetype-modules: not a directory: $root" >&2; exit 2; }
done

while IFS= read -r raw; do
    p="${raw%%#*}"
    p="$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$p" ] || continue
    case "$p" in
        /*|*..*) echo "prune-archetype-modules: refusing non-relative path: $p" >&2; exit 2 ;;
    esac
    found=0
    for root in "$@"; do
        if [ -e "$root/$p" ]; then
            rm -rf "${root:?}/$p"
            found=1
        fi
    done
    if [ "$found" -eq 1 ]; then
        printf '%s\n' "$p"
    else
        printf 'prune-archetype-modules: %s lists %s, which the spine does not ship (stale entry)\n' \
            "$ARCH" "$p" >&2
    fi
done < "$LIST"
exit 0
