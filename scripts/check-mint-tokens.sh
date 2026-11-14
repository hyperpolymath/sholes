#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-mint-tokens.sh — every brace token the template can ship has an answer
# in `just repo-init`, or the file that carries it is not shipped.
#
# ── Why this exists ─────────────────────────────────────────────────────────
#
# A token with no answer is not a reminder, it is a defect that ships. Measured
# downstream: a minted Julia repo carried
#
#     Justfile         project := "sholes"   tier := "{{tier}}"
#     .envrc           PROJECT_NAME="sholes"  RSR_TIER="infrastructure"
#     .reuse/dep5      Upstream-Name: sholes
#     Containerfile    # Copyright (c) ... (hyperpolymath)
#     devcontainer.json, .devcontainer/Containerfile  sholes
#
# because the mint had no answer for those tokens IN THOSE FILES, and nothing
# checked. The repo's own `check-no-placeholders.sh` would have caught it — in
# the child, after the fact, on every push, which trains people to ignore red.
#
# This is the template-side check: it compares the token VOCABULARY the tree
# contains against the token vocabulary `repo-init` can answer, before a mint
# ever runs. A token in the left set and not the right one is a file that cannot
# be minted, and the fix is one of two things, chosen deliberately:
#
#   * teach repo-init an answer (SED_ARGS, or the UNASSIGNED fallback for a
#     judgement token), or
#   * stop shipping the file.
#
# ── What counts ─────────────────────────────────────────────────────────────
#   * scannable: tracked/untracked files, minus .machine_readable/mint-verbatim.txt
#     fixtures, minus Justfiles and *.just (just's own {{ }} interpolation), minus
#     binary/licence text — the same set repo-init's mint_files edits;
#   * tokens: `{{[A-Za-z_][A-Za-z0-9_]*}}` — lowercase included, because the
#     downstream damage included `{{tier}}`, and an uppercase-only scan would
#     have reported full coverage of a tree that still carried it;
#   * exempt: metasyntax ({{PLACEHOLDER}}, {{TOKEN}}, {{ANYTHING}},
#     {{UPPER_SNAKE}}) and the documents whose subject IS the vocabulary.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   check-mint-tokens.sh [--root DIR] [--quiet]
#
# Exit: 0 = every token is answerable; 1 = an unanswerable token; 2 = usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)    ROOT="${2:-}"; shift 2 ;;
        --quiet)   QUIET=1; shift ;;
        -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "check-mint-tokens: unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -d "$ROOT" ] || { echo "check-mint-tokens: not a directory: $ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"

ok()   { [ "$QUIET" -eq 1 ] || printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
note() { [ "$QUIET" -eq 1 ] || printf '        %s\n' "$1"; }
info() { [ "$QUIET" -eq 1 ] || printf '  \033[34minfo\033[0m  %s\n' "$1"; }

RECIPE="$ROOT/build/just/repo-init.just"
MINTED_TREE=0
if [ ! -d "$ROOT/archetypes" ]; then
    # "Minted" is the absence of archetypes/, NOT the absence of the generator.
    # The mint carries build/just/repo-init.just into every child verbatim
    # (.machine_readable/mint-verbatim.txt) and the child's Justfile imports it,
    # so testing for the recipe never fired: children looked like the template,
    # every token they carried counted as "the generator will answer this", and
    # an unfilled sholes passed — in the gate and in
    # survey-template-damage.sh, which reads it.
    #
    # archetypes/ is the marker because the mint deletes it (repo-init's prune
    # step) and nothing else recreates it: a template checkout has it, a minted
    # repository cannot. Where the generator IS present in a child, its answers
    # are listed below but never used, which is the point: nothing can answer a
    # token in a tree that has already been minted.
    MINTED_TREE=1
fi

# ── The answer list, read from the generator itself ─────────────────────────
# Not a copy: a copy drifts, and a drifted copy would pass this gate while the
# mint still failed. Two forms are answered:
#   * SED_ARGS entries:  -e "s|${LB}TOKEN${RB}|value|g"
#   * the UNASSIGNED fallback loop:  for tok in TOKEN TOKEN … ; do
ANSWERS=""
[ "$MINTED_TREE" -eq 0 ] && ANSWERS="$({
    # shellcheck disable=SC2016  # the braces are literal text in the recipe
    sed -n 's/.*s|\${LB}\([A-Za-z_][A-Za-z0-9_]*\)\${RB}|.*/\1/p' "$RECIPE"
    awk '
        /for tok in/ { collecting = 1 }
        collecting {
            line = $0
            gsub(/\$\{LB\}|\$\{RB\}|\\/, " ", line)
            n = split(line, w, /[^A-Z0-9_]+/)
            for (i = 1; i <= n; i++) if (w[i] ~ /^[A-Z][A-Z0-9_]*$/ && length(w[i]) > 2) print w[i]
            if ($0 ~ /;[[:space:]]*do/) collecting = 0
        }' "$RECIPE"
} | sort -u)"
# In memory, not /tmp/mint-tokens-answers.$$: this script is called in nested
# command substitutions (tests, the mint's pre-write gate), where a PID-named
# temp file is shared by the outer and inner shell often enough to hand one of
# them a half-written list — measured as an intermittent "the mint cannot
# answer sholes" on a tree where it demonstrably can.
if [ "$MINTED_TREE" -eq 1 ]; then
    info "no archetypes/ — minted tree; no token has an answer here"
else
    COUNT_ANSWERS=$(printf '%s\n' "$ANSWERS" | grep -c . || true)
    [ "$COUNT_ANSWERS" -gt 0 ] || { bad "could not read any answered token from repo-init"; exit 2; }
    info "repo-init answers $COUNT_ANSWERS token(s)"
fi

# ── What the mint edits ─────────────────────────────────────────────────────
VERBATIM_LIST="$ROOT/.machine_readable/mint-verbatim.txt"
mapfile -t VERBATIM < <(
    [ -f "$VERBATIM_LIST" ] && sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$VERBATIM_LIST" | grep -v '^$' || true
)

is_verbatim() {
    local rel="$1" v
    for v in "${VERBATIM[@]}"; do [ "$rel" = "$v" ] && return 0; done
    return 1
}

# The vocabulary document, the prose about tokens, and the checkers themselves.
EXEMPT=(
    ".machine_readable/ai/PLACEHOLDERS.adoc"
    "PLACEHOLDERS.adoc"          # the same vocabulary doc, at the root
    "EXPLAINME.adoc"
    "scripts/check-mint-tokens.sh"
    "scripts/check-no-placeholders.sh"
    # Generator internals. `src/generator.jl` and `templates/` are the code and
    # the files that DO the substituting: `{{name}}`, `{{summary}}` and
    # `{{uuid}}` there are Julia string interpolation over a generator variable,
    # not mint tokens. They are searched for tokens in the generator's own
    # source, not here.
    "src/generator.jl"
)
is_exempt() {
    local rel="$1" e
    for e in "${EXEMPT[@]}"; do [ "$rel" = "$e" ] && return 0; done
    case "$rel" in
        Justfile|justfile|*/Justfile|*/justfile|*.just) return 0 ;;
        templates/*) return 0 ;;
    esac
    return 1
}

list_files() {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$ROOT" ls-files -z --cached --others --exclude-standard
    else
        find "$ROOT" -type f -print0
    fi | sort -zu | while IFS= read -r -d '' f; do
        rel="${f#"$ROOT"/}"
        [ -f "$ROOT/$rel" ] && [ ! -L "$ROOT/$rel" ] || continue
        case "$rel" in */.git/*) continue ;; esac
        is_verbatim "$rel" && continue
        grep -qIE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$ROOT/$rel" 2>/dev/null || continue
        printf '%s\n' "$rel"
    done
}

META='PLACEHOLDER|PLACEHOLDERS|ANYTHING|TOKEN|UPPER_SNAKE'
UNKNOWN=()
SEEN=()
while IFS= read -r rel; do
    is_exempt "$rel" && continue
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        # Here-strings, not pipes: `grep -q` exits on its first match, which
        # SIGPIPEs the writer, and under `set -o pipefail` that made the
        # pipeline report 141 (no match) for token lists it HAD matched —
        # measured as a different one or two tokens reported unanswerable on
        # every run of the same unchanged tree.
        grep -qxE "$META" <<< "$tok" && continue
        grep -qxF -- "$tok" <<< "$ANSWERS" && continue
        UNKNOWN+=("$rel: {{$tok}}")
        SEEN+=("$tok")
    # Lowercase tokens count too: the downstream damage included {{tier}}, and an
    # uppercase-only scan reported the tree clean while it still carried it.
    done < <(grep -ohE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' "$ROOT/$rel" | tr -d '{}' | sort -u)
done < <(list_files)

if [ ${#UNKNOWN[@]} -eq 0 ]; then
    ok "every shipped brace token has an answer in repo-init"
    exit 0
fi

if [ "$MINTED_TREE" -eq 1 ]; then
    bad "${#UNKNOWN[@]} unfilled token(s) in a minted tree (no archetypes/, so nothing can answer them):"
else
    bad "${#UNKNOWN[@]} token reference(s) the mint cannot answer:"
fi
for u in "${UNKNOWN[@]}"; do printf '        %s\n' "$u"; done
note "Unanswerable token(s): $(printf '%s\n' "${SEEN[@]}" | sort -u | tr '\n' ' ')"
if [ "$MINTED_TREE" -eq 1 ]; then
    note "This repository was minted: the mint substituted what it could and the"
    note "rest stayed literal. Fill them with the values in .machine_readable/ai/PLACEHOLDERS.adoc,"
    note "or delete the lines that need them."
    exit 1
fi
note "Fix one of two ways, deliberately:"
note "  * teach repo-init (SED_ARGS, or the UNASSIGNED list for a judgement token), or"
note "  * stop shipping the file that carries it."
note "A third way — filling it by hand after the mint — is how the downstream repos"
note "got the tokens in the first place."
exit 1
