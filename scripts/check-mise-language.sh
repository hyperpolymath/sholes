#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-mise-language.sh — the declared toolchain matches the repository's
# languages: nothing banned, nothing foreign, nothing missing.
#
# ── Why this exists ─────────────────────────────────────────────────────────
#
# The template's mise.toml declared nine runtimes:
#
#     node python rust go zig java bun denojs
#     npm yarn pnpm pip cargo go-task
#     gofmt black isort ruff prettier shfmt stylua
#     cmake make ninja git gnu-sed gnu-tar gnu-grep
#     vitest pytest jest
#     [alias] build/test/lint/fmt = a chain of Cargo, Node, Go and Ruff commands
#
# for every repository it seeded, including a Julia package. Two of those
# declarations are policy violations on their own (Python and Node are banned
# estate-wide), the alias block routed `just build` through Cargo/npm/Go, and
# the one runtime the repo actually needed was absent. The file was correct for
# no repository in particular and wrong for all of them.
#
# The fix is not to delete the polyglot list — it is to render the toolchain
# from the languages the repo declares, which `just repo-init` now does through
# `provision-lib.sh mise-tools`. This gate is the INVERSE check: it reads the
# shipped mise.toml back and fails when it and the tree disagree.
#
# ── Rules ───────────────────────────────────────────────────────────────────
#   1. mise.toml exists (doctor PV-E20 is the runtime form of this).
#   2. No banned tool (LANGUAGE-POLICY §Banned Languages + no make/nix).
#   3. Every declared tool is needed by a detected language or is shared.
#   4. Every tool a detected language needs is declared.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   check-mise-language.sh [--root DIR] [--langs "julia"] [--tools "julia just"]
#                          [--quiet]
#
#   --langs LIST  language list to check against (default: provisioning engine)
#   --tools LIST  expected tool set (default: provisioning engine `mise-tools`)
#                 — for a fixture, so the gate can be driven without an engine.
#   --detect      when the repo ships no build/just/provision-lib.sh, detect the
#                 languages from the same marker files the engine uses. Audits
#                 repositories minted before the engine existed; a repo WITH the
#                 engine ignores this flag.
#
# Exit: 0 = consistent; 1 = findings; 2 = usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LANGS=""
TOOLS=""
QUIET=0
DETECT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)   ROOT="${2:-}"; shift 2 ;;
        --langs)  LANGS="${2:-}"; shift 2 ;;
        --tools)  TOOLS="${2:-}"; shift 2 ;;
        --quiet)  QUIET=1; shift ;;
        --detect) DETECT=1; shift ;;
        -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "check-mise-language: unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -d "$ROOT" ] || { echo "check-mise-language: not a directory: $ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"

ok()   { [ "$QUIET" -eq 1 ] || printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
note() { [ "$QUIET" -eq 1 ] || printf '        %s\n' "$1"; }
info() { [ "$QUIET" -eq 1 ] || printf '  \033[34minfo\033[0m  %s\n' "$1"; }

LIB="$ROOT/build/just/provision-lib.sh"
lib() { ( cd "$ROOT" && PROVISION_ROOT="$ROOT" bash "$LIB" "$@" 2>/dev/null ); }

if [ -z "$LANGS" ] && [ -f "$LIB" ]; then
    LANGS="$(lib langs | tr '\n' ' ')"
fi
if [ -z "$TOOLS" ] && [ -f "$LIB" ]; then
    TOOLS="$(lib mise-tools | tr '\n' ' ')"
fi
# --detect: a reduced mirror of build/just/provision-lib.sh's detectors, for
# repositories minted before this engine existed (or before it shipped them).
# Those repositories have a mise.toml but no provision-lib.sh, so the gate
# cannot read its answer — and refusing to run leaves them unaudited forever.
# The mirror is deliberately narrow: same marker files, same MISE_BASE, same
# per-language binaries. It is NOT the source of truth; when provision-lib.sh is
# present its answer wins, and a disagreement is a bug in the mirror.
if [ -z "$LANGS" ] && [ "$DETECT" -eq 1 ]; then
    # Same depths as provision-lib.sh's `first`, not root-only: the template's own
    # seam puts Idris2 at src/interface/abi.ipkg and Zig at
    # src/interface/ffi/build.zig, so a root-only mirror called those trees
    # `docs` and graded them against the wrong toolchain. Depths are copied from
    # detect_langs(), including its defaults (2 for the unmarked ones).
    _find() { find "$ROOT" -maxdepth "${2:-2}" -not -path '*/.git/*' \
                -not -path '*/node_modules/*' -not -path '*/target/*' \
                -name "$1" -print -quit 2>/dev/null; }
    _l=()
    [ -n "$(_find Cargo.toml)" ]      && _l+=(rust)
    [ -n "$(_find '*.ipkg' 3)" ]      && _l+=(idris2)
    [ -n "$(_find Project.toml 3)" ]  && _l+=(julia)
    [ -n "$(_find build.zig 4)" ]     && _l+=(zig)
    [ -n "$(_find mix.exs)" ]         && _l+=(elixir)
    [ -n "$(_find gleam.toml)" ]      && _l+=(gleam)
    [ -n "$(_find dune-project)" ]    && _l+=(ocaml)
    { [ -n "$(_find '*.cabal')" ] || [ -n "$(_find stack.yaml 1)" ]; } && _l+=(haskell)
    [ -n "$(_find package.json)" ]    && _l+=(bun)
    [ "${#_l[@]}" -eq 0 ] && _l+=(docs)
    LANGS="${_l[*]}"
    info "languages (detected from markers; provision-lib.sh absent): $LANGS"
fi
if [ -z "$TOOLS" ] && [ "$DETECT" -eq 1 ]; then
    # MISE_BASE + RECIPE_TOOLS + lang_mise(), copied from provision-lib.sh. The
    # mirror used to list each language's BINARIES instead (`mix erl`, `ghc cabal`,
    # `dune`), which is lang_tools()'s answer, not the mise.mise table's: a tree
    # declaring `erlang elixir` was failed for not declaring `mix`/`erl`, and a
    # Rust tree declaring `rust` was failed for declaring a tool the engine
    # installs. A mirror that disagrees with the engine is a bug in the mirror.
    _t="just shellcheck yq trivy"
    for l in $LANGS; do
        case "$l" in
            rust)              _t="$_t rust" ;;
            zig)               _t="$_t zig" ;;
            julia)             _t="$_t julia" ;;
            idris2)            _t="$_t idris2" ;;
            elixir)            _t="$_t erlang elixir" ;;
            gleam)             _t="$_t erlang gleam" ;;
            ocaml)             _t="$_t opam" ;;
            bun)               _t="$_t bun deno pnpm" ;;
            docs)              _t="$_t lychee" ;;
        esac
    done
    TOOLS="$_t"
fi

if [ -z "$LANGS" ] || [ -z "$TOOLS" ]; then
    bad "cannot determine the expected toolchain"
    note "no build/just/provision-lib.sh in $ROOT, and --langs/--tools were not given."
    note "For a repository minted before the engine existed, pass --detect."
    note "This gate will not guess: a guessed toolchain set is how the template shipped one."
    exit 2
fi
LANGS="$(echo "$LANGS" | xargs)"
TOOLS="$(echo "$TOOLS" | xargs)"
info "languages: $LANGS"
info "expected tools: $TOOLS"

MISE="$ROOT/mise.toml"
if [ ! -f "$MISE" ]; then
    bad "mise.toml is missing — the toolchain is undeclared"
    note "doctor's PV-E20 says the same; render it, do not hand-write nine runtimes."
    exit 1
fi

# [tools] keys, quotes and comments stripped, one per line. Only the [tools]
# table: [env] and [alias] are not tool declarations.
declared() {
    awk '
        /^[[:space:]]*\[tools\][[:space:]]*$/ { t = 1; next }
        /^[[:space:]]*\[/                    { t = 0 }
        t && /^[[:space:]]*("[^"]*"|\047[^\047]*\047|[A-Za-z0-9_.-]+)[[:space:]]*=/ {
            # Quoted keys are not decoration: TOML REQUIRES them for
            # backend-qualified tools ("npm:prettier" = "latest"), so a parser
            # that only saw bare keys never declared them — and a file declaring
            # the banned tool passed this gate while the backend check below
            # could not be reached for the syntax it exists to inspect.
            line = $0
            sub(/[[:space:]]*=.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            gsub(/^["\047]|["\047]$/, "", line)
            print line
        }' "$MISE"
}

mapfile -t DECLARED < <(declared | sort -u)
if [ ${#DECLARED[@]} -eq 0 ]; then
    bad "mise.toml declares no tools — an empty [tools] table installs nothing"
    exit 1
fi

# Banned estate-wide. `make` and `nix` are in LANGUAGE-POLICY's toolchain rules;
# deno/pnpm are permitted (2026-10-14 ruling) so they are not here.
BANNED='python|python3|pip|pip3|poetry|black|ruff|isort|pytest|node|nodejs|npm|yarn|typescript|rescript|make|nix|go|golang|java|kotlin|gradle|maven|ruby|gem|vitest|jest|prettier|eslint'
FAILS=0

BANNED_HIT=""
for t in "${DECLARED[@]}"; do
    # a backend-qualified name (cargo:foo) is judged on its backend
    base="${t%%:*}"
    if grep -qE "^($BANNED)$" <<< "$base"; then
        BANNED_HIT="$BANNED_HIT $t"
    fi
done
if [ -n "$BANNED_HIT" ]; then
    bad "banned tool(s) declared:$BANNED_HIT"
    note "LANGUAGE-POLICY §Banned Languages / JS-RUNTIME-POLICY. Python is banned"
    note "estate-wide; JavaScript runs Bun > Deno > pnpm from one package.json."
    FAILS=$((FAILS + 1))
fi

FOREIGN=""
MISSING=""
for t in "${DECLARED[@]}"; do
    case " $TOOLS " in *" $t "*) continue ;; esac
    FOREIGN="$FOREIGN $t"
done
for t in $TOOLS; do
    case " ${DECLARED[*]} " in *" $t "*) continue ;; esac
    MISSING="$MISSING $t"
done

if [ -n "$FOREIGN" ]; then
    bad "declared for no detected language:$FOREIGN"
    note "languages: $LANGS. A tool for a language this repo does not carry is"
    note "installed on every checkout and audits as a foreign dependency."
    FAILS=$((FAILS + 1))
fi
if [ -n "$MISSING" ]; then
    bad "needed by a detected language but not declared:$MISSING"
    note "the repo carries the language; its toolchain must be declared for it."
    FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then
    ok "mise.toml matches the declared languages ($LANGS): ${DECLARED[*]}"
    exit 0
fi
exit 1
