#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-spdx-headers.sh — the SPDX gate, with the extension set derived from the
# languages the repository actually declares.
#
# ── Why this exists ─────────────────────────────────────────────────────────
#
# The gate this replaces was a fixed glob in every repository:
#
#     find . -name '*.rs' -o -name '*.res' -o -name '*.gleam' | head -20 \
#       | xargs -r grep -L 'SPDX-License-Identifier' | wc -l | grep -q '^0$'
#
# It is wrong three ways, and each wrongness shipped into the repos it was
# copied into:
#
#   1. THE EXTENSIONS ARE ONE LANGUAGE'S. In a Julia, Elixir, Idris2, Zig,
#      OCaml, Haskell or shell repository that find matches NOTHING. It then
#      pipes an empty list to xargs, counts 0, and reports PASS. A check that
#      examines zero files and reports PASS is worse than no check: it reports
#      coverage it does not have.
#   2. `head -20` CAPS THE SCAN at twenty files, so a 400-file repository was
#      surveyed 5% deep and graded on that.
#   3. Its answer does not depend on the repository at all, so it cannot notice
#      the one thing it exists to notice: a new language arriving unscanned.
#
# So the extension set is derived, per repository:
#
#   * the DECLARED languages come from the provisioning engine
#     (`build/just/provision-lib.sh langs`) — the same detection `just doctor`,
#     `just build` and `just fmt-check` use, so no two of them can disagree;
#   * every other KNOWN source extension PRESENT in the tree is scanned too. A
#     file the gate knows how to read but skipped is exactly the defect above,
#     one layer down: the template's own Rust mint tools live in scripts/*.rs
#     with no Cargo.toml, so a language-only derivation would have left them
#     out.
#   * a declared language with ZERO matching files is a FAIL (the declaration
#     lies, or the scan looks in the wrong place);
#   * a repository with no scanned file at all is a FAIL (examined nothing);
#   * a BANNED language's source is a FAIL (LANGUAGE-POLICY: Python, TypeScript,
#     Node, Go, Java; see §Banned Languages);
#   * every matched file is checked — there is no cap.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   check-spdx-headers.sh [--root DIR] [--langs "julia zig"] [--exts "jl,zig"]
#                         [--allow-empty] [--quiet]
#
#   --root DIR       repository to scan (default: this script's repository)
#   --langs LIST     language list to derive from (default: detected via
#                    build/just/provision-lib.sh when present, else by manifest)
#   --exts LIST      skip derivation and scan exactly these extensions
#   --allow-empty    do not fail when nothing matched (test fixtures only; the
#                    shipped gate never runs with it)
#   --quiet          print failures only
#
# Exit: 0 = every matched file carries a header; 1 = findings; 2 = usage error.
#
# Canon: RSR-SPEC §1.3 (licensing); hyperpolymath/standards 0-canon/rsr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ROOT="$REPO_DIR"
LANGS=""
EXTS=""
ALLOW_EMPTY=0
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --root)        ROOT="${2:-}"; shift 2 ;;
        --langs)       LANGS="${2:-}"; shift 2 ;;
        --exts)        EXTS="${2:-}"; shift 2 ;;
        --allow-empty) ALLOW_EMPTY=1; shift ;;
        --quiet)       QUIET=1; shift ;;
        -h|--help)     sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "check-spdx-headers: unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -d "$ROOT" ] || { echo "check-spdx-headers: not a directory: $ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"

ok()   { [ "$QUIET" -eq 1 ] || printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
warn() { [ "$QUIET" -eq 1 ] || printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
note() { [ "$QUIET" -eq 1 ] || printf '        %s\n' "$1"; }
info() { [ "$QUIET" -eq 1 ] || printf '  \033[34minfo\033[0m  %s\n' "$1"; }

# Source extensions of language $1. One table, here, because this gate is the
# only consumer of the mapping; the language LIST is not duplicated — it comes
# from the provisioning engine, so a new language is detected in one place.
exts_for() {
    case "$1" in
        rust)         echo "rs" ;;
        julia)        echo "jl" ;;
        zig)          echo "zig" ;;
        idris2)       echo "idr" ;;
        elixir)       echo "ex exs" ;;
        gleam)        echo "gleam" ;;
        ocaml)        echo "ml mli" ;;
        haskell)      echo "hs" ;;
        bun)          echo "js mjs cjs" ;;
        affinescript) echo "affine" ;;
        docs)         echo "" ;;   # prose repository: its shell scripts are still scanned
        *)            echo "" ;;
    esac
}
# Shell, Nickel (the contracts), jq (the classifiers) and Guile (Guix) are estate
# formats rather than one language's, so they are scanned wherever they appear.
ESTATE_EXTS="sh ncl jq scm"
# Everything this gate can scan.
KNOWN_EXTS="rs jl zig idr ex exs gleam ml mli hs js mjs cjs affine sh ncl jq scm"
# Banned estate-wide (LANGUAGE-POLICY §Banned Languages). Their presence is a
# policy violation in itself, headers or not.
BANNED_EXTS="py pyi pyx ts tsx go java kt kts"

has_ext() { # $1 list, $2 ext
    case " $1 " in *" $2 "*) return 0 ;; esac
    return 1
}

# ── Languages ───────────────────────────────────────────────────────────────
if [ -z "$LANGS" ] && [ -z "$EXTS" ]; then
    LIB="$ROOT/build/just/provision-lib.sh"
    if [ -f "$LIB" ]; then
        LANGS="$(cd "$ROOT" && PROVISION_ROOT="$ROOT" bash "$LIB" langs 2>/dev/null | tr '\n' ' ')"
    fi
fi
if [ -z "$LANGS" ] && [ -z "$EXTS" ]; then
    # No provisioning engine (a fixture, or a repo predating it): detect by the
    # manifests this gate knows, so it still cannot report a vacuous PASS.
    if   [ -f "$ROOT/Cargo.toml" ];   then LANGS="rust"
    elif [ -f "$ROOT/Project.toml" ]; then LANGS="julia"
    elif [ -f "$ROOT/mix.exs" ];      then LANGS="elixir"
    elif [ -f "$ROOT/gleam.toml" ];   then LANGS="gleam"
    elif [ -f "$ROOT/dune-project" ]; then LANGS="ocaml"
    elif [ -f "$ROOT/package.json" ]; then LANGS="bun"
    else LANGS="docs"
    fi
fi

# ── Files ───────────────────────────────────────────────────────────────────
# Tracked (respects .gitignore, never descends into vendored trees) when in a
# work tree; otherwise every file under --root. Same rule as repo-init's
# mint_files, so "the repository" means the same thing to both.
list_files() {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # Paths from `git -C DIR` are relative to DIR, not to the caller's cwd:
        # prefix them, or every `head` below reads a same-named file in whatever
        # directory the gate was invoked from (measured: a fixture that happened
        # to share a path with the template read the TEMPLATE's copy and graded
        # that).
        git -C "$ROOT" ls-files -z --cached --others --exclude-standard \
            | while IFS= read -r -d '' f; do printf '%s\n' "$ROOT/$f"; done | {
                while IFS= read -r f; do
                    case "$f" in
                        */node_modules/*|*/target/*|*/_build/*|*/deps/*|*/vendor/*) continue ;;
                        */tests/controls/*) continue ;;
                    esac
                    [ -f "$f" ] || continue   # tracked but deleted from the work tree
                    printf '%s\n' "$f"
                done
            }
        return 0
    fi
    find "$ROOT" -type f -print0 | while IFS= read -r -d '' f; do
        case "$f" in
            */.git/*|*/node_modules/*|*/target/*|*/_build/*|*/deps/*|*/vendor/*) continue ;;
            # Planted negative controls: their bytes ARE the input a control test
            # asserts on, and one of them is deliberately a file with no header
            # because that is what the control proves is catchable.
            */tests/controls/*) continue ;;
        esac
        [ -f "$f" ] || continue
        printf '%s\n' "$f"
    done
}

mapfile -t ALL_FILES < <(list_files | sort -u)

# Extensions present in the tree, one per line.
present_exts() {
    local f base e
    for f in "${ALL_FILES[@]}"; do
        base="${f##*/}"
        case "$base" in *.*) e="${base##*.}" ;; *) e="" ;; esac
        [ -n "$e" ] && printf '%s\n' "$e"
    done | sort -u
}
mapfile -t PRESENT < <(present_exts)

if [ -n "$EXTS" ]; then
    SCAN_EXTS="$(echo "$EXTS" | tr ',' ' ' | xargs)"
else
    # Derived: declared languages first (and a hole in this table is a finding,
    # not a silent skip), then the estate formats, then any other known source
    # extension that is actually present.
    DERIVED=""
    for l in $LANGS; do
        got="$(exts_for "$l")"
        if [ -z "$got" ] && [ "$l" != docs ]; then
            bad "language '$l' is declared but this gate has no extension for it"
            note "add it to exts_for() in $0 — an unscannable language is not a pass"
            exit 1
        fi
        for e in $got; do has_ext "$DERIVED" "$e" || DERIVED="$DERIVED $e"; done
    done
    SCAN_EXTS="$(echo "$DERIVED" | xargs)"
    for e in $ESTATE_EXTS; do
        has_ext " $SCAN_EXTS " "$e" || SCAN_EXTS="$SCAN_EXTS $e"
    done
    ORPHANS=""
    for e in "${PRESENT[@]}"; do
        has_ext "$KNOWN_EXTS" "$e" || continue
        has_ext " $SCAN_EXTS " "$e" && continue
        SCAN_EXTS="$SCAN_EXTS $e"
        ORPHANS="$ORPHANS .$e"
    done
    SCAN_EXTS="$(echo "$SCAN_EXTS" | xargs)"
    [ -n "$ORPHANS" ] && info "also scanning source present outside the declared languages:$ORPHANS"
fi

# ── Banned languages ────────────────────────────────────────────────────────
BANNED_HITS=()
for f in "${ALL_FILES[@]}"; do
    base="${f##*/}"
    case "$base" in *.*) e="${base##*.}" ;; *) continue ;; esac
    has_ext "$BANNED_EXTS" "$e" && BANNED_HITS+=("${f#"$ROOT"/}")
done

# ── Scan ────────────────────────────────────────────────────────────────────
if [ -z "$SCAN_EXTS" ]; then
    bad "no extensions derived and none given — nothing would be scanned"
    exit 1
fi

info "languages: ${LANGS:-<from --exts>}"
info "scanning extensions: $SCAN_EXTS"

SCANNED=()
declare -A COUNT=()
for f in "${ALL_FILES[@]}"; do
    base="${f##*/}"
    case "$base" in *.*) e="${base##*.}" ;; *) continue ;; esac
    has_ext " $SCAN_EXTS " "$e" || continue
    SCANNED+=("$f")
    COUNT["$e"]=$(( ${COUNT["$e"]:-0} + 1 ))
done

# Declared language, no files: the extension table and the detector disagree, or
# the declaration lies. Name the empty extension rather than leaving it to feel.
# A language is empty only when NO extension of that language matched. Several
# mappings list alternatives (.ex/.exs, .ml/.mli, .js/.mjs/.cjs), so judging each
# extension separately failed perfectly good repositories for the alternative
# they do not use — an Elixir tree with .ex and no .exs was "missing" a language
# it is written in.
EMPTY_DECL=""
for l in $LANGS; do
    total=0
    exts="$(exts_for "$l")"
    [ -n "$exts" ] || continue     # `docs` maps to no extension: nothing to find
    for e in $exts; do
        total=$(( total + ${COUNT["$e"]:-0} ))
    done
    [ "$total" -eq 0 ] && EMPTY_DECL="$EMPTY_DECL $l($(echo "$exts" | sed 's/^ *//; s/  */, ./g; s/^/\./'))"
done
if [ -n "$EMPTY_DECL" ]; then
    bad "declared language source not found:$EMPTY_DECL"
    note "A language is declared but its files are absent. Either the declaration"
    note "is wrong or the scan is looking in the wrong place; both are findings."
    exit 1
fi

TOTAL=${#SCANNED[@]}
if [ "$TOTAL" -eq 0 ]; then
    if [ "$ALLOW_EMPTY" -eq 1 ]; then
        info "matched zero files (--allow-empty)"
        exit 0
    fi
    bad "matched ZERO files with extensions: $SCAN_EXTS"
    note "A gate that examines nothing is not a pass. Either this repository has no"
    note "source in any language it declares, or the scan is looking in the wrong"
    note "place. Both are findings, not a green tick."
    exit 1
fi

MISSING=()
for f in "${SCANNED[@]}"; do
    # No `head | grep -q` pipe: with `set -o pipefail`, `grep -q` exiting on its
    # first match SIGPIPEs `head` and flips a MATCH into a failure. It is a race
    # (measured: a gate reporting different files each run over an unchanged
    # tree), and on a slow filesystem it would be a false finding.
    head10="$(head -10 "$f" 2>/dev/null || true)"
    grep -q 'SPDX-License-Identifier' <<< "$head10" || MISSING+=("${f#"$ROOT"/}")
done

if [ ${#BANNED_HITS[@]} -gt 0 ]; then
    bad "${#BANNED_HITS[@]} banned-language source file(s) present:"
    for f in "${BANNED_HITS[@]}"; do printf '        %s\n' "$f"; done
    note "LANGUAGE-POLICY §Banned Languages: Python, TypeScript, Node, Go, Java."
    note "Delete or port them; a header does not make them permitted."
fi

if [ ${#MISSING[@]} -eq 0 ]; then
    ok "SPDX headers: $TOTAL/$TOTAL files ($SCAN_EXTS)"
    if [ "$QUIET" -eq 0 ]; then
        for e in $SCAN_EXTS; do printf '        %s: %s\n' "$e" "${COUNT["$e"]:-0}"; done
    fi
else
    bad "SPDX headers: $((TOTAL - ${#MISSING[@]}))/$TOTAL files carry a header"
    for f in "${MISSING[@]}"; do printf '        missing: %s\n' "$f"; done
    note "Add the language's comment form in the first 10 lines:"
    note "  C family / rust / zig / js:  // SPDX-License-Identifier: MPL-2.0"
    note "  shell / julia / elixir / hs: # SPDX-License-Identifier: MPL-2.0"
    note "  toml / yaml / ncl:           # SPDX-License-Identifier: MPL-2.0"
fi

# An explicit exit, not a trailing test. A script whose exit status comes from
# its last expression returns whatever that expression happened to be in some
# branch — this one returned 1 in a minted tree while printing PASS, which made
# `just repo-init` abort with "the minted tree fails a gate" and no failing gate
# in the log above it.
if [ ${#MISSING[@]} -eq 0 ] && [ ${#BANNED_HITS[@]} -eq 0 ]; then
    exit 0
fi
exit 1
