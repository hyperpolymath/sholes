#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-no-placeholders.sh — no repo may ship an unfilled {{PLACEHOLDER}}.
#
# Estate rule (the deed's (bot-directives (methodology)) reject-if-contains): a token that `just repo-init`
# did not fill is debt, and in .github/settings.yml or SECURITY.md it is a
# defect with consequences — probot/settings applies settings.yml on every push,
# and a security policy that cites a key nobody holds is worse than one that
# says "email us".
#
# This is the single implementation of that rule, called from two places:
#   * .github/workflows/ossf-best-practices.yml (job openssf-compliance) — on the repo as committed
#   * tests/e2e/template_instantiation_test.sh — on a freshly init'd repo,
#     which is where a leak is still cheap to fix
# It exists as a script rather than inline shell in each caller because the
# previous split — a workflow that checked a hand-listed set of files, and an
# e2e test that re-implemented substitution with its own token list — let the
# two drift until the test passed while real instantiation leaked.
#
# Scans every text file and allow-lists the few legitimate carriers, rather
# than checking a list of files someone must remember to extend. The old
# required-files list omitted .github/settings.yml and ANCHOR.a2ml, which is
# precisely where the leaks were.
#
# Matches upper-snake brace tokens only. Justfiles are skipped entirely: an
# ARGS token there is just's own interpolation syntax, not a template token.
# GitHub Actions expressions are ${{ dotted.lower }} and do not match.
#
# Exit codes:
#   0 — no unfilled tokens (or this is a template repo, where tokens are the product)
#   1 — unfilled tokens found
#   2 — usage / setup error

set -euo pipefail

REPO_ROOT="${1:-.}"

if [ ! -d "$REPO_ROOT" ]; then
    echo "usage: $0 [repo-root]" >&2
    exit 2
fi

# ─── settings.yml identity guard — runs EVERYWHERE, template repos included ────
#
# This check deliberately precedes the template exemption below. That exemption
# is why the original incident went unseen: the gate skipped `*-template-repo`
# entirely, so nobody noticed that .github/settings.yml shipped `name: "sholes"`
# — and .github/settings.yml is not inert content in a template. probot/settings
# applies it on every push to the default branch, in the template as much as in
# an instantiation. The template submitted the literal `sholes` as its own
# name; GitHub collapsed the illegal braces to dashes and renamed the repository
# to `-REPO-`, which then read as a deleted repo.
#
# So: in this one file, a placeholder is never "the product". Neither is an
# identity key with a real value — `name`/`private` cannot be inherited by a
# child repo without being wrong (see the header of .github/settings.yml).
SETTINGS="$REPO_ROOT/.github/settings.yml"
if [ -f "$SETTINGS" ]; then
    settings_fail=0

    # Comment-aware: the file's own header documents the incident and has to be
    # able to quote the offending token. Prose about a token is not a token —
    # the same distinction META_TOKENS draws below. Line numbers are preserved
    # by filtering `grep -n` output rather than the file.
    settings_tokens="$(grep -nE '\{\{' "$SETTINGS" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    if [ -n "$settings_tokens" ]; then
        echo "FAIL: .github/settings.yml contains an unrendered {{ token." >&2
        printf '%s\n' "$settings_tokens" | sed 's/^/  /' >&2
        settings_fail=1
    fi

    # Keys of the `repository:` map sit at exactly two spaces of indent. Label
    # and branch entries are list items ("  - name:") and are not matched.
    if grep -qE '^[[:space:]]{2}(name|description|homepage|private):' "$SETTINGS"; then
        echo "FAIL: .github/settings.yml declares repository identity." >&2
        grep -nE '^[[:space:]]{2}(name|description|homepage|private):' "$SETTINGS" \
            | sed 's/^/  /' >&2
        settings_fail=1
    fi

    if [ "$settings_fail" -ne 0 ]; then
        echo "" >&2
        echo "probot/settings applies this file on every push to the default branch," >&2
        echo "so these keys are enforced, not described. Repository identity and" >&2
        echo "visibility are set out of band at creation time — by \`just repo-init\` via" >&2
        echo "\`gh\` for minted repos, and deliberately by the owner for the template." >&2
        exit 1
    fi
fi

# A template repo's placeholders ARE its product — they are what `just repo-init`
# consumes. Any other repo is an instantiation and is checked in full.
#
# Identity comes from the git remote, not the directory name.
#
# This used to be `basename "$(pwd)"`, which is right in CI — GITHUB_REPOSITORY
# is set to `owner/sholes` and matches — but wrong anywhere the
# checkout is not literally named `*-template-repo`. A git worktree is the common
# case: `git worktree add .claude/worktrees/defects` gives basename `defects`,
# the exemption misses, and the gate reports every one of the template's ~85
# deliberate placeholder files as a failure. A clone into `sholes-2`,
# or any renamed directory, does the same.
#
# The remote URL is the repo's actual identity and survives all of that. The
# basename remains as the last fallback for a checkout with no remote.
REPO_NAME="${GITHUB_REPOSITORY:-}"
if [ -z "$REPO_NAME" ]; then
    # `|| true` is load-bearing: a repository with NO origin remote (a fresh
    # `git init` + commit, which is exactly what `just repo-init` produces
    # before the first push) makes `git config` exit 1, and with `set -e` +
    # `pipefail` that killed the whole gate — exit 1, no output, no finding.
    # Measured on a minted tree that had no remote yet: the gate failed silently
    # and looked like a token leak to anyone reading the exit code.
    REPO_NAME="$( { git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null \
                 | sed -E 's#(\.git)?/?$##; s#^.*[:/]([^/]+/[^/]+)$#\1#' ; } || true )"
fi
[ -z "$REPO_NAME" ] && REPO_NAME="$(cd "$REPO_ROOT" && basename "$(pwd)")"
case "$REPO_NAME" in
    *-template-repo)
        echo "PASS: $REPO_NAME is a template repo — unfilled tokens are intentional"
        echo "      (.github/settings.yml identity guard above still applied)"
        exit 0
        ;;
esac

# Files that legitimately contain tokens after instantiation.
ALLOWED=(
    ".machine_readable/ai/PLACEHOLDERS.adoc"   # the token vocabulary itself
    "EXPLAINME.adoc"                           # prose explaining that tokens exist
    "scripts/check-no-placeholders.sh"         # this file (the pattern above)
)
# Template machinery the mint carries unchanged, whose fixtures name tokens on
# purpose (the e2e answer list, the Julia UUID test). One manifest, read by
# repo-init too, so the mint and this gate cannot disagree about what is a
# fixture: see .machine_readable/mint-verbatim.txt.
VERBATIM_LIST="$REPO_ROOT/.machine_readable/mint-verbatim.txt"
if [ -f "$VERBATIM_LIST" ]; then
    while IFS= read -r v; do
        [ -n "$v" ] && ALLOWED+=("$v")
    done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$VERBATIM_LIST")
fi

is_allowed() {
    local rel="$1"
    for a in "${ALLOWED[@]}"; do
        [ "$rel" = "$a" ] && return 0
    done
    # just owns brace tokens inside justfiles — an ARGS token there is
    # interpolation, not a placeholder. Justfiles are not only at the root:
    # the contractiles ship one too.
    case "$rel" in
        Justfile|justfile|*/Justfile|*/justfile|*.just) return 0 ;;
    esac
    return 1
}

# Metasyntactic tokens: prose *about* tokens, not tokens. "Replace all
# {{PLACEHOLDER}} values" names the concept — there is no PLACEHOLDER variable
# for init to fill, so these can never be a leak, and flagging them would only
# teach people that this gate cries wolf. Real tokens name a real init variable.
META_TOKENS='PLACEHOLDER|ANYTHING|TOKEN|UPPER_SNAKE'

# repo_files — every file of the repository holding an upper-snake token, as
# "$REPO_ROOT/<path>". In a git work tree, "of the repository" means tracked or
# untracked-and-not-ignored, the same set `just repo-init` edits: a git-ignored
# cache such as _build/dependencies/ holds OTHER repositories' files, whose
# tokens are not this repo's leak. Outside git, every file is scanned.
repo_files() {
    if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard \
            | while IFS= read -r -d '' rel; do
                [ -f "$REPO_ROOT/$rel" ] && [ ! -L "$REPO_ROOT/$rel" ] || continue
                grep -qIE '\{\{[A-Z][A-Z0-9_]*\}\}' "$REPO_ROOT/$rel" 2>/dev/null \
                    && printf '%s\n' "$REPO_ROOT/$rel"
            done
    else
        grep -rlE '\{\{[A-Z][A-Z0-9_]*\}\}' "$REPO_ROOT" \
            --exclude-dir=.git --binary-files=without-match 2>/dev/null
    fi
    return 0
}

LEAKS=()
while IFS= read -r hit; do
    rel="${hit#"$REPO_ROOT"/}"
    is_allowed "$rel" && continue
    # Re-check the file for at least one non-metasyntactic token.
    if grep -ohE '\{\{[A-Z][A-Z0-9_]*\}\}' "$hit" \
        | grep -qvE "^\{\{($META_TOKENS)\}\}$"; then
        LEAKS+=("$rel")
    fi
done < <(repo_files | sort)

if [ ${#LEAKS[@]} -eq 0 ]; then
    echo "PASS: no unfilled {{PLACEHOLDER}} tokens"
    exit 0
fi

echo "FAIL: ${#LEAKS[@]} file(s) contain unfilled {{PLACEHOLDER}} tokens:" >&2
for leak in "${LEAKS[@]}"; do
    tokens=$(grep -ohE '\{\{[A-Z][A-Z0-9_]*\}\}' "$REPO_ROOT/$leak" \
             | grep -vE "^\{\{($META_TOKENS)\}\}$" | sort -u | tr '\n' ' ')
    echo "  - $leak: $tokens" >&2
done
echo "" >&2
echo "Each token must either be filled by build/just/init.just's SED_ARGS, or" >&2
echo "removed from the shipped file. A token with no possible value (a PGP key" >&2
echo "the estate does not hold) makes this gate unsatisfiable — delete the" >&2
echo "section instead of leaving the gate permanently red." >&2
exit 1
