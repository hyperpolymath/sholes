#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# render-mise.sh — render mise.toml from the languages the repository actually
# carries, instead of inheriting the template's list.
#
# ── Why this exists ─────────────────────────────────────────────────────────
#
# The provisioning standard says mise.toml is MINTED per repository
# (PROVISIONING-STANDARD §1: "the toolchain: latest in mise.toml, made concrete
# and checksummed in mise.lock"). The canon's own template carries
# `__MISE_TOOLS_TOML__` for exactly that reason. `just repo-init` never rendered
# it — so every mint inherited the template's own toolchain verbatim.
#
# The template's list used to be nine runtimes (python, node, rust, go, zig,
# java, bun, denojs, …) plus npm/yarn/pnpm/pip/cargo/go-task, black/ruff/isort/
# prettier/stylua/gofmt/shfmt, cmake/make/ninja, vitest/pytest/jest and an
# [alias] block routing build/test/lint/fmt through Cargo/npm/Go/ruff/black. A
# minted Julia package therefore installed Python (banned estate-wide), Node
# (banned), Go, Java and Cargo, declared no Julia at all, and `just build` ran
# `cargo build`. Fixing that file in one child fixes one child; rendering it at
# mint is what fixes the next N.
#
# The language→tool table is NOT here. It lives in build/just/provision-lib.sh
# (`mise_tools`), the engine `just doctor`, `just setup` and `just dev-shell`
# already read, so this render and the doctor cannot disagree about what a Julia
# repository needs.
#
# ── Behaviour ───────────────────────────────────────────────────────────────
#   * writes mise.toml with [settings] lockfile = true and the [tools] table;
#   * leaves the file untouched (byte-identical) when nothing changed;
#   * PRUNES mise.lock when the tool set changes: pins of tools no longer
#     declared are dropped (a lock pinning a retired toolchain is a false
#     statement that `mise install` would honour); pins of tools still declared
#     are kept. The file is never deleted, because root-allow.txt requires it.
#     Newly declared tools are pinned by `just toolchain-refresh` (needs mise
#     and the network; a mint is often offline); `just doctor` reports PV-W20
#     until then.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   render-mise.sh [--root DIR] [--langs "julia zig"] [--check]
#
#   --check   do not write; exit 1 if mise.toml is not what the tree implies
#
# Exit: 0 = rendered (or already correct); 1 = --check mismatch / render failed;
#       2 = usage or environment error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LANGS=""
CHECK_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)  ROOT="${2:-}"; shift 2 ;;
        --langs) LANGS="${2:-}"; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "render-mise: unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -d "$ROOT" ] || { echo "render-mise: not a directory: $ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"

LIB="$ROOT/build/just/provision-lib.sh"
[ -f "$LIB" ] || { echo "render-mise: $LIB is missing; the language table is not guessable" >&2; exit 2; }

lib() { ( cd "$ROOT" && PROVISION_ROOT="$ROOT" bash "$LIB" "$@" 2>/dev/null ); }
[ -n "$LANGS" ] || LANGS="$(lib langs | tr '\n' ' ')"
LANGS="$(echo "$LANGS" | xargs)"
# Pass the language list explicitly: `mise-tools` without arguments re-detects
# from the tree, which is what made --langs cosmetic — it relabelled the file
# 'the toolchain for this repository (julia)' while installing the docs
# toolchain, so a fixture that asked for julia got just/shellcheck/lychee.
# shellcheck disable=SC2086
TOOLS="$(lib mise-tools $LANGS | tr '\n' ' ' | xargs)"
if [ -z "$TOOLS" ]; then
    echo "render-mise: the engine returned no tools for languages '${LANGS}'" >&2
    exit 2
fi

render() {
    cat <<EOF
# SPDX-License-Identifier: MPL-2.0
#
# The toolchain for this repository (${LANGS}). Rendered at mint by
# scripts/render-mise.sh from the languages the tree declares; the language→tool
# table is build/just/provision-lib.sh's, so this file and \`just doctor\` cannot
# disagree. Specs are \`latest\`; mise.lock records the concrete version and
# per-platform checksum of each. Refresh both with: just toolchain-refresh
# Canon: hyperpolymath/standards 3-practice/provisioning (TRUST-DEFAULTS §toolchain).
# Estate policy: no python, node/npm/yarn, make or nix here. JavaScript runs
# Bun > Deno > pnpm from one package.json (LANGUAGE-POLICY §1.4).
#
# Hand-edited project tools belong below the table's end, never by replacing it:
# \`scripts/check-mise-language.sh\` fails when a tool matches no detected
# language, and when a detected language's tool is missing.

[settings]
lockfile = true

[tools]
EOF
    for t in $TOOLS; do
        case "$t" in
            trivy)    echo "trivy = \"latest\"          # just deps-audit" ;;
            shellcheck) echo "shellcheck = \"latest\"     # the shell scripts" ;;
            yq)       echo "yq = \"latest\"             # scripts/kyaml-format.sh (KYAML configs)" ;;
            just)     echo "just = \"latest\"" ;;
            *)        printf '%s = "latest"\n' "$t" ;;
        esac
    done
}

NEW="$(render)"
CURRENT=""
[ -f "$ROOT/mise.toml" ] && CURRENT="$(cat "$ROOT/mise.toml")"

if [ "$NEW" = "$CURRENT" ]; then
    echo "mise.toml already matches the declared languages (${LANGS}) — unchanged"
    exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    # --check compares the TOOLCHAIN, not the prose. Comparing the whole rendered
    # file made the check impossible to pass on any repository that wrote its own
    # header — the template itself included — so it was a permanently red light
    # rather than a finding, and a permanently red light is not a check.
    # It still fails, which is the part that matters: a missing tool, a foreign
    # tool, or a toolchain rendered for the wrong language all differ as a SET.
    declare_tools() {
        awk '
            /^[[:space:]]*\[tools\][[:space:]]*$/ { t = 1; next }
            /^[[:space:]]*\[/                    { t = 0 }
            t && /^[[:space:]]*("[^"]*"|\047[^\047]*\047|[A-Za-z0-9_.-]+)[[:space:]]*=/ {
                line = $0
                sub(/[[:space:]]*=.*/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                gsub(/^["\047]|["\047]$/, "", line)
                print line
            }' "$1"
    }
    HAVE="$(declare_tools "$ROOT/mise.toml" 2>/dev/null | sort -u | xargs)"
    WANT="$(printf '%s\n' $TOOLS | sort -u | xargs)"
    if [ "$HAVE" = "$WANT" ]; then
        echo "mise.toml declares exactly this tree's toolchain (${LANGS}) — ok"
        exit 0
    fi
    echo "mise.toml does NOT declare this tree's toolchain (${LANGS})" >&2
    echo "  is:   ${HAVE:-<nothing>}" >&2
    echo "  want: ${WANT}" >&2
    echo "  rewrite it with: scripts/render-mise.sh --root ." >&2
    exit 1
fi

# The OLD tool set, before overwriting: needed to decide about mise.lock.
OLD_TOOLS=""
if [ -f "$ROOT/mise.toml" ]; then
    OLD_TOOLS="$(awk '
        /^[[:space:]]*\[tools\][[:space:]]*$/ { t = 1; next }
        /^[[:space:]]*\[/                    { t = 0 }
        t && /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
            line = $0; sub(/[[:space:]]*=.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line
        }' "$ROOT/mise.toml" | sort -u | xargs 2>/dev/null)"
fi

printf '%s\n' "$NEW" > "$ROOT/mise.toml"
echo "mise.toml rendered for: ${LANGS:-?}"
echo "  tools: $(echo "$TOOLS" | xargs)"
OLD_SORTED="$(printf '%s\n' $OLD_TOOLS | sort | xargs 2>/dev/null)"
NEW_SORTED="$(printf '%s\n' $TOOLS | sort | xargs 2>/dev/null)"
if [ -f "$ROOT/mise.lock" ] && [ "$OLD_SORTED" != "$NEW_SORTED" ]; then
    # Prune, do not delete. Each [[tools.X]] block in mise.lock is an independent,
    # checksummed pin, so the pins of tools that are STILL declared remain true
    # statements and are kept; only the pins of tools this repository no longer
    # declares are dropped (a lock that pins a retired tool is the false
    # statement). The file therefore still exists, which root-allow.txt
    # requires of every repository (mise.lock is not '?' optional, and must not
    # become so just because an archetype changes the tool set). A tool that is
    # newly declared and not yet pinned is reported by `just doctor` (PV-W20,
    # "mise.lock does not pin: X") until `just toolchain-refresh` (needs mise and
    # the network; a mint is often offline) pins it. A visible gap, never silent.
    LOCK_TMP="$(mktemp)"
    awk -v keep="$TOOLS" '
        BEGIN { n = split(keep, a, " "); for (i = 1; i <= n; i++) k[a[i]] = 1; on = 1 }
        /^\[/ {
            h = $0
            if (h ~ /^\[\[?tools\./) {
                sub(/^\[\[?tools\./, "", h)
                if (h ~ /^"/) { sub(/^"/, "", h); sub(/".*$/, "", h) }
                else          { sub(/[.\]].*$/, "", h) }
                on = (h in k)
            } else on = 1
        }
        on { print }
    ' "$ROOT/mise.lock" > "$LOCK_TMP" && cat "$LOCK_TMP" > "$ROOT/mise.lock" || {
        echo "render-mise: could not prune mise.lock" >&2; rm -f "$LOCK_TMP"; exit 1
    }
    rm -f "$LOCK_TMP"
    echo "  mise.lock pruned to the tools this repository still declares; pins for"
    echo "  tools it no longer declares were dropped. Pin any newly declared tool with:"
    echo "  just toolchain-refresh (needs mise; just doctor reports PV-W20 until then)."
fi
exit 0
