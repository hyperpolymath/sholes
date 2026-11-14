#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-mint-drift.sh — the exact drift gate for a minted repo.
#
# A minted repo differs from its template by design: the mint renders tokens,
# strips instruction blocks, prunes dependabot, splices the identity, seeds
# docs/, regenerates CLAUDE.md and the map. Diffing it against the template
# reported 101 rendered files on a fresh mint (2026-10-20), and no set of
# (normalise) rules could fold that without re-implementing the mint. So this
# gate does not compare against the template. It replays the mint:
#
#     child  ≡  repo-init(template @ :template-commit, (mint-answers))
#
# modulo the paths the child declares in its (variant (paths …)) clause. The
# replay runs the REAL recipe from the pinned template commit, with the answers
# and date the child recorded, so a fresh mint is designed to replay to
# itself (tested end to end on fixtures by tests/e2e/use_template_mint_test.sh,
# not proven), and every later edit to a file the mint produced shows up, by
# name.
#
# Usage: check-mint-drift.sh <template-checkout> [child-dir]
#   <template-checkout>  a clone of the template that contains :template-commit
#   [child-dir]          the minted repo (default .)
# Needs what a mint needs: just, rustc, nickel, and sha1sum, shasum or openssl
# (uuidgen too, to replay a template commit older than scripts/uuid5-url.sh).
# Exit: 0 no undeclared drift; 1 drift (listed); 2 usage or cannot replay.
set -euo pipefail
# This script runs git against other repositories (-C does not override
# these), so an inherited location (a hook, another git caller) cannot redirect
# it (CodeRabbit review of #275).
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE

TDIR="${1:?usage: check-mint-drift.sh <template-checkout> [child-dir]}"
CDIR="${2:-.}"
TDIR="$(cd "$TDIR" && pwd)"; CDIR="$(cd "$CDIR" && pwd)"
READ="$CDIR/scripts/deed-field.sh"
die() { echo "check-mint-drift: $*" >&2; exit 2; }

DEED="$(bash "$READ" --find "$CDIR")" || die "no single *_chora.deed in $CDIR"
bash "$READ" --has "$DEED" mint-answers \
    || die "$(basename "$DEED") has no (mint-answers) clause: this repo was minted before answers were recorded, so its mint cannot be replayed"
ans() { bash "$READ" "$DEED" mint-answers "$1" 2>/dev/null || true; }
PIN="$(bash "$READ" "$DEED" provenance template-commit 2>/dev/null || true)"
SLUG="$(bash "$READ" "$DEED" provenance template-repo 2>/dev/null || true)"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || die "(provenance :template-commit) is '${PIN}', not a commit"
git -C "$TDIR" cat-file -e "${PIN}^{commit}" 2>/dev/null \
    || die "$TDIR does not contain template commit $PIN (fetch ${SLUG:-the template}'s history)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# g — git with no user or system configuration and no hooks, so the replay's
# synthetic commit and file set cannot be changed by this machine's settings (a
# global core.hooksPath, init.templateDir, excludesFile or autocrlf) (Codex
# review of #275). The child's own file set is its own git's (files … own).
g() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=replay -c user.email=replay@example.invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

# The child as "Use this template" made it: the pinned tree, one root commit.
R="$WORK/replay"
mkdir -p "$R"
# Written as a checkout writes it, by git (checkout-index), never git archive,
# whose export-ignore and export-subst attributes change the tree (Codex review
# of #275). Through g: no global core.attributesFile shapes it (Codex review
# of #277).
GIT_INDEX_FILE="$WORK/replay.index" g -C "$TDIR" read-tree "$PIN"
# A gitlink has no files to write, so the copy would lose it: refused by name
# rather than compared inexactly (Codex review of #277).
GL="$(GIT_INDEX_FILE="$WORK/replay.index" g -C "$TDIR" ls-files -s | awk -F '\t' '$1 ~ /^160000 / { print "  " $2 }')"
[ -z "$GL" ] || die "the template commit carries a submodule (gitlink), which a replay cannot reproduce:
$GL"
GIT_INDEX_FILE="$WORK/replay.index" g -C "$TDIR" checkout-index -a -f --prefix="$R/"
g -C "$R" init -q -b main
# Forced, and then checked to BE the pinned tree, as in scripts/replay-mint.sh:
# a template file its own .gitignore matches is still tracked (Codex and
# CodeRabbit review of #277).
g -C "$R" add -f -A
[ "$(g -C "$R" write-tree)" = "$(g -C "$TDIR" rev-parse "$PIN^{tree}")" ] \
    || die "the checkout of $PIN does not read back as its own tree (an attribute rewrites a file), so the mint cannot be replayed exactly"
g -C "$R" commit -q -m "Initial commit"
g -C "$R" remote add origin "git@$(ans forge):$(ans owner)/$(ans repo).git"

ARCH="$(ans archetype)"
: > "$WORK/gitconfig"
mkdir -p "$WORK/cfg"
if ! (cd "$R" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        ${RUSTUP_HOME:+RUSTUP_HOME="$RUSTUP_HOME"} ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} \
        ${RSR_MINT_TOOL_CACHE:+RSR_MINT_TOOL_CACHE="$RSR_MINT_TOOL_CACHE"} \
        XDG_CONFIG_HOME="$WORK/cfg" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        RSR_NON_INTERACTIVE=1 RSR_MINT_REPLAY=1 \
        RSR_TEMPLATE_URL="$TDIR" RSR_TEMPLATE_COMMIT="$PIN" RSR_MINT_DATE="$(ans mint-date)" \
        ${SLUG:+RSR_TEMPLATE_SLUG="$SLUG"} \
        PROJECT_NAME="$(ans project-name)" REPO="$(ans repo)" OWNER="$(ans owner)" \
        AUTHOR="$(ans author)" AUTHOR_EMAIL="$(ans author-email)" AUTHOR_ORG="$(ans author-org)" \
        AUTHOR_EMAIL_ALT="$(ans author-email-alt)" AUTHOR_ORCID="$(ans author-orcid)" \
        PROJECT_DESCRIPTION="$(ans description)" FORGE="$(ans forge)" \
        SECURITY_EMAIL="$(ans security-email)" CONDUCT_EMAIL="$(ans conduct-email)" \
        PROJECT_TYPE="$(ans project-type)" WEBSITE="$(ans website)" \
        OPENSSF_BP_ID="$(ans openssf-bp-id)" SERVICE_NAME="$(ans service-name)" \
        PORT="$(ans port)" REGISTRY="$(ans registry)" RSR_PACKAGE_UUID="$(ans package-uuid)" \
        just repo-init ${ARCH:+"$ARCH"} </dev/null) > "$WORK/replay.log" 2>&1; then
    tail -n 30 "$WORK/replay.log" >&2
    die "the replay of the mint failed (above); nothing was compared"
fi

# Declared divergence, from the CHILD's (variant (paths …)) clause, kept by
# category: each one is a claim the gate checks, not a blanket exemption
# (Codex review of #275). An entry ending in / covers a directory.
#   added     must exist here, and must NOT be something the mint produces;
#   removed   must be absent here;
#   diverged  (and -pending-upstream) may differ in content, but must still
#             exist here, and must be something the mint produces;
#   operational-state  excluded from comparison altogether (ADR-0002).
section() { bash "$READ" --list "$DEED" variant/paths "$1" 2>/dev/null || true; }
ADDED="$(section added)"
REMOVED="$(section removed)"
DIVERGED="$(section diverged; section diverged-pending-upstream)"
OPSTATE="$(section operational-state)"
# match_len P LIST — the length of the longest entry in LIST covering P (0:
# none); an exact path outranks any directory that holds it.
match_len() {
    local p="$1" e best=0 n
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        case "$e" in
            */) case "$p" in "$e"*) n=${#e} ;; *) continue ;; esac ;;
            *) [ "$p" = "$e" ] || continue; n=$(( ${#e} + 1 )) ;;
        esac
        [ "$n" -gt "$best" ] && best=$n
    done <<< "$2"
    echo "$best"
}
# declared P — the category of the MOST SPECIFIC declaration covering P, so a
# file added under a directory the mint removes is an addition, not a revived
# removal (Codex review of #277). Ties keep removed > added > diverged >
# operational-state.
declared() {
    local r a d o
    r=$(match_len "$1" "$REMOVED"); a=$(match_len "$1" "$ADDED")
    d=$(match_len "$1" "$DIVERGED"); o=$(match_len "$1" "$OPSTATE")
    if [ $((r + a + d + o)) -eq 0 ]; then echo none
    elif [ "$r" -ge "$a" ] && [ "$r" -ge "$d" ] && [ "$r" -ge "$o" ]; then echo removed
    elif [ "$a" -ge "$d" ] && [ "$a" -ge "$o" ]; then echo added
    elif [ "$d" -ge "$o" ]; then echo diverged
    else echo opstate
    fi
}
# files DIR [own] — the repository's own files: tracked, or untracked and not
# ignored. With "own", DIR is listed under its own git configuration, as
# `git add -A` there would commit it (a file only a global excludesFile ignores
# is not this repo's); the replay is listed under none (CodeRabbit review of
# #275). The lists below are line-based, so a path holding a newline is
# refused, loudly.
files() {
    local gx=g; [ "${2:-}" = own ] && gx=git
    "$gx" -C "$1" -c core.hooksPath=/dev/null ls-files -z --cached --others --exclude-standard \
        | while IFS= read -r -d '' f; do
            case "$f" in *$'\n'*) echo "check-mint-drift: cannot check a path containing a newline: $(printf '%q' "$f")" >&2; exit 2 ;; esac
            # if, not &&: an absent last path must not fail the pipeline (CodeRabbit).
            if [ -e "$1/$f" ] || [ -L "$1/$f" ]; then printf '%s\n' "$f"; fi
        done \
        | LC_ALL=C sort -u
}
# Membership is the repository file set on each side, not bare existence: an
# ignored artifact the replay also generates (arrival-pack output) is not a
# file the mint produced, even if a child force-adds it (Codex review of #275).
CLIST="$WORK/child.files"; RLIST="$WORK/replay.files"
files "$CDIR" own > "$CLIST"
files "$R" > "$RLIST"
in_child() { grep -qxF -- "$1" "$CLIST"; }
in_replay() { grep -qxF -- "$1" "$RLIST"; }
# same A B — identical as git would record them: content, the executable bit,
# and for a symlink its target (cmp alone follows links and ignores modes).
# The target is read with a trailing sentinel, because command substitution
# strips trailing newlines and "foo\n" would equal "foo" (Codex review of
# #275). The executable bit is git's: the OWNER's execute bit (0100), not
# `-x`, which asks whether the caller may execute and, as root, is true for a
# file only its group or others may execute (Codex review of #275).
ux() { [ -n "$(find "$1" -prune -perm -0100 2>/dev/null)" ]; }
same() {
    if [ -L "$1" ] || [ -L "$2" ]; then
        [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1"; echo .)" = "$(readlink "$2"; echo .)" ]
        return
    fi
    { ux "$1" && ux "$2"; } || { ! ux "$1" && ! ux "$2"; } || return 1
    cmp -s "$1" "$2"
}

DRIFT=0
report() { DRIFT=1; echo "DRIFT: $*"; }
while IFS= read -r f; do
    kind="$(declared "$f")"
    if [ "$kind" = removed ]; then
        report "$f exists here but is declared removed"
    elif [ "$kind" = added ]; then
        if in_replay "$f"; then report "$f is declared added, but the mint produces it (declare it diverged)"; fi
    elif [ "$kind" = diverged ]; then
        # A diverged path is one the mint produces and this repo changed; a new
        # path declared diverged is an undeclared addition (Codex review of #275).
        if ! in_replay "$f"; then report "$f is declared diverged, but the mint did not produce it (declare in paths.added)"; fi
    elif [ "$kind" = opstate ]; then
        :
    elif ! in_replay "$f"; then
        report "$f exists here but the mint did not produce it (declare in paths.added)"
    elif ! same "$R/$f" "$CDIR/$f"; then
        report "$f differs from what the mint produced, in content or mode (declare in paths.diverged, or restore it)"
    fi
done < "$CLIST"
while IFS= read -r f; do
    in_child "$f" && continue
    kind="$(declared "$f")"
    [ "$kind" = removed ] || [ "$kind" = opstate ] && continue
    if [ "$kind" = diverged ]; then
        report "$f is declared diverged but is absent here (declare it removed)"
    else
        report "$f was produced by the mint but is absent here (declare in paths.removed)"
    fi
done < "$RLIST"
# Every declared addition must actually be here.
while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in
        */) P="$e" awk 'index($0, ENVIRON["P"]) == 1 { f = 1; exit } END { exit !f }' "$CLIST" \
               || report "declared-added directory $e has no files here" ;;
        *) in_child "$e" || report "declared-added $e is missing" ;;
    esac
done <<< "$ADDED"

if [ "$DRIFT" -eq 0 ]; then
    echo "PASS: identical to a replay of the mint (${SLUG}@${PIN:0:12}, $(ans mint-date)), modulo declared variant paths"
else
    echo "FAIL: undeclared drift from a replay of the mint (${SLUG}@${PIN:0:12}) — declare it in the deed's (variant (paths …)) clause, or restore it"
    exit 1
fi
