#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# replay-mint.sh — mint a template commit into a fresh directory, from answers.
#
# The one place a mint is replayed. Used by scripts/check-mint-drift.sh (replay
# a child's own mint and diff the child against it) and scripts/chain-mint.sh
# (replay a child's mint and mint the same template commit with new answers,
# then carry the child's own work across). It runs the REAL recipe, from the
# pinned commit, exactly as "Use this template" would have started it.
#
# Usage: replay-mint.sh <template-checkout> <commit> <out-dir> [--answers-from DEED]
# With --answers-from, the answers, date and archetype are the (mint-answers)
# clause of DEED: a replay of that repo's own mint. Without it, they come
# from the environment, under the names repo-init reads (ARCHETYPE too):
#   PROJECT_NAME REPO OWNER AUTHOR AUTHOR_EMAIL AUTHOR_ORG AUTHOR_EMAIL_ALT
#   AUTHOR_ORCID PROJECT_DESCRIPTION FORGE SECURITY_EMAIL CONDUCT_EMAIL
#   PROJECT_TYPE WEBSITE OPENSSF_BP_ID SERVICE_NAME PORT REGISTRY RSR_MINT_DATE
#   RSR_TEMPLATE_SLUG (a template whose Justfile names itself through env())
# With --answers-from, the slug is DEED's (provenance :template-repo) and a
# julia-library package uuid its recorded one; without it, the uuid is derived.
# Nothing else from the caller's environment reaches the mint: no defaults
# file, no global git config (an ORCID or signing key there would leak in).
# Exit: 0 minted into <out-dir>; 1 the mint failed (log tail on stderr); 2 usage.
set -euo pipefail
# This script runs git against other repositories (-C does not override
# these), so an inherited location (a hook, another git caller) cannot redirect
# it (CodeRabbit review of #275).
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE

usage() { echo "usage: replay-mint.sh <template-checkout> <commit> <out-dir> [--answers-from DEED]" >&2; exit 2; }
TDIR="${1:-}"; PIN="${2:-}"; OUT="${3:-}"
{ [ -n "$TDIR" ] && [ -n "$PIN" ] && [ -n "$OUT" ]; } || usage
ARCH="${ARCHETYPE:-}"
if [ $# -gt 3 ]; then
    [ "$4" = "--answers-from" ] && [ -n "${5:-}" ] || usage
    ANS_DEED="$5"
    READ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deed-field.sh"
    bash "$READ" --has "$ANS_DEED" mint-answers \
        || { echo "replay-mint: $ANS_DEED has no (mint-answers) clause; its mint cannot be replayed" >&2; exit 2; }
    ans() { bash "$READ" "$ANS_DEED" mint-answers "$1" 2>/dev/null || true; }
    PROJECT_NAME="$(ans project-name)" REPO="$(ans repo)" OWNER="$(ans owner)"
    AUTHOR="$(ans author)" AUTHOR_EMAIL="$(ans author-email)" AUTHOR_ORG="$(ans author-org)"
    AUTHOR_EMAIL_ALT="$(ans author-email-alt)" AUTHOR_ORCID="$(ans author-orcid)"
    PROJECT_DESCRIPTION="$(ans description)" FORGE="$(ans forge)"
    SECURITY_EMAIL="$(ans security-email)" CONDUCT_EMAIL="$(ans conduct-email)"
    PROJECT_TYPE="$(ans project-type)" WEBSITE="$(ans website)"
    OPENSSF_BP_ID="$(ans openssf-bp-id)" SERVICE_NAME="$(ans service-name)"
    PORT="$(ans port)" REGISTRY="$(ans registry)" RSR_MINT_DATE="$(ans mint-date)"
    RSR_PACKAGE_UUID="$(ans package-uuid)"
    ARCH="$(ans archetype)"
    # The template identity the mint was given, for a template whose Justfile
    # names itself through env() (Codex review of #275).
    RSR_TEMPLATE_SLUG="$(bash "$READ" "$ANS_DEED" provenance template-repo 2>/dev/null || true)"
else
    # A fresh mint (a chain mint's new side) derives its package uuid: only a
    # recorded (mint-answers) may supply one, never the caller's environment.
    RSR_PACKAGE_UUID=""
fi
TDIR="$(cd "$TDIR" && pwd)"
[ ! -e "$OUT" ] || { echo "replay-mint: $OUT already exists" >&2; exit 2; }
git -C "$TDIR" cat-file -e "${PIN}^{commit}" 2>/dev/null \
    || { echo "replay-mint: $TDIR does not contain commit $PIN" >&2; exit 2; }

# g — git with no user or system configuration and no hooks (Codex review of
# #275): the synthetic "Use this template" commit cannot be changed or refused
# by this machine's settings.
g() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=replay -c user.email=replay@example.invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
# Written as a checkout writes it, by git (checkout-index), never git archive,
# whose export-ignore and export-subst attributes change the tree (Codex review
# of #275). Through g: no global core.attributesFile shapes it (Codex review
# of #277).
GIT_INDEX_FILE="$SCRATCH/index" g -C "$TDIR" read-tree "$PIN"
# A gitlink has no files to write, so the copy would lose it: refused by name
# rather than replayed inexactly (Codex review of #277).
GL="$(GIT_INDEX_FILE="$SCRATCH/index" g -C "$TDIR" ls-files -s | awk -F '\t' '$1 ~ /^160000 / { print "  " $2 }')"
if [ -n "$GL" ]; then
    echo "replay-mint: the template commit $PIN carries a submodule (gitlink), which a replay cannot reproduce:" >&2
    printf '%s\n' "$GL" >&2
    exit 2
fi
GIT_INDEX_FILE="$SCRATCH/index" g -C "$TDIR" checkout-index -a -f --prefix="$OUT/"
g -C "$OUT" init -q -b main
# Forced: OUT holds only the pinned tree's files, and a file the template
# tracks although its .gitignore matches it is still one of them ("Use this
# template" copies the tree as it is) (Codex and CodeRabbit review of #277).
# The commit must then BE the pinned tree; a checkout that does not read back
# as it was written (an eol or encoding attribute) is refused, not replayed.
g -C "$OUT" add -f -A
[ "$(g -C "$OUT" write-tree)" = "$(g -C "$TDIR" rev-parse "$PIN^{tree}")" ] || {
    echo "replay-mint: the checkout of $PIN does not read back as its own tree (an attribute rewrites a file); it cannot be replayed exactly" >&2
    exit 1; }
g -C "$OUT" commit -q -m "Initial commit"
g -C "$OUT" remote add origin "git@${FORGE:-github.com}:${OWNER:-}/${REPO:-}.git"

: > "$SCRATCH/gitconfig"
mkdir -p "$SCRATCH/cfg"
if ! (cd "$OUT" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        ${RUSTUP_HOME:+RUSTUP_HOME="$RUSTUP_HOME"} ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} \
        ${RSR_MINT_TOOL_CACHE:+RSR_MINT_TOOL_CACHE="$RSR_MINT_TOOL_CACHE"} \
        ${STANDARDS_UUID_V8_JS:+STANDARDS_UUID_V8_JS="$STANDARDS_UUID_V8_JS"} \
        XDG_CONFIG_HOME="$SCRATCH/cfg" GIT_CONFIG_GLOBAL="$SCRATCH/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        RSR_NON_INTERACTIVE=1 RSR_MINT_REPLAY=1 \
        RSR_TEMPLATE_URL="$TDIR" RSR_TEMPLATE_COMMIT="$PIN" RSR_MINT_DATE="${RSR_MINT_DATE:-}" \
        ${RSR_TEMPLATE_SLUG:+RSR_TEMPLATE_SLUG="$RSR_TEMPLATE_SLUG"} \
        PROJECT_NAME="${PROJECT_NAME:-}" REPO="${REPO:-}" OWNER="${OWNER:-}" \
        AUTHOR="${AUTHOR:-}" AUTHOR_EMAIL="${AUTHOR_EMAIL:-}" AUTHOR_ORG="${AUTHOR_ORG:-}" \
        AUTHOR_EMAIL_ALT="${AUTHOR_EMAIL_ALT:-}" AUTHOR_ORCID="${AUTHOR_ORCID:-}" \
        PROJECT_DESCRIPTION="${PROJECT_DESCRIPTION:-}" FORGE="${FORGE:-}" \
        SECURITY_EMAIL="${SECURITY_EMAIL:-}" CONDUCT_EMAIL="${CONDUCT_EMAIL:-}" \
        PROJECT_TYPE="${PROJECT_TYPE:-}" WEBSITE="${WEBSITE:-}" \
        OPENSSF_BP_ID="${OPENSSF_BP_ID:-}" SERVICE_NAME="${SERVICE_NAME:-}" \
        PORT="${PORT:-}" REGISTRY="${REGISTRY:-}" RSR_PACKAGE_UUID="${RSR_PACKAGE_UUID:-}" \
        just repo-init ${ARCH:+"$ARCH"} </dev/null) > "$SCRATCH/replay.log" 2>&1; then
    tail -n 30 "$SCRATCH/replay.log" >&2
    echo "replay-mint: the mint of $PIN failed (above)" >&2
    exit 1
fi
