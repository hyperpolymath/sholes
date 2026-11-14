#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# chain_mint_test.sh — mint a repository made from a MINTED repository.
#
# Codex (review of #251) showed that minting a minted repo inherited the
# parent's author, contacts and identity, because the parent's tokens were
# already filled. The owner chose to support chains properly (2026-11-04):
# scripts/chain-mint.sh replays the parent's mint, mints the same template
# commit with the new answers, and carries the parent's own work across by a
# three-way merge. This mints parent -> grandchild end to end and checks:
#   * nothing of the parent's identity or contacts survives in the grandchild;
#   * the parent's own work (an edit, an addition, a removal) is carried, with
#     its name rewritten, and declared in the grandchild's (variant (paths));
#   * provenance names the root template commit and the parent;
#   * the grandchild's drift gate (a replay of ITS mint) is green;
# and, as negative controls, that a conflicting parent edit stops the chain
# before it writes, and that a parent without (mint-answers) is refused.
# Needs just, rustc, uuidgen, nickel, file. Network-free (RSR_TEMPLATE_URL).
#
# Usage: bash tests/e2e/chain_mint_test.sh [--keep]
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
if [ "${1:-}" = "--keep" ]; then echo "keeping $work"; else trap 'rm -rf "$work"' EXIT; fi
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
g() { git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false "$@"; }
for tool in just rustc uuidgen nickel file; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required to run a real mint (not skipping)"
done

# A legacy minted repository (minted before #275 recorded (mint-answers), so
# it has no build/templates/identity.deed.in and no answers to replay) cannot
# be minted again: repo-init refuses before it asks or writes anything (#277).
# The rest of this test needs a mintable tree, so in such a child it checks
# that refusal, by name, and stops. It does not skip silently: a legacy child
# that could be minted again would fail here.
legacy_deed="$(bash "$repo/scripts/deed-field.sh" --find "$repo" 2>/dev/null || true)"
if [[ ! -f "$repo/build/templates/identity.deed.in" ]] \
   && ! { [[ -n "$legacy_deed" ]] && bash "$repo/scripts/deed-field.sh" --has "$legacy_deed" mint-answers; }; then
    legacy_cfg=$(mktemp -d)
    if legacy_out=$(cd "$repo" && env -i PATH="$PATH" HOME="$legacy_cfg" XDG_CONFIG_HOME="$legacy_cfg" \
        RSR_NON_INTERACTIVE=1 PROJECT_NAME="Mint Check" REPO=mint-check OWNER=example-owner \
        AUTHOR="Example Author" AUTHOR_EMAIL=author@example.org CONFIRM=n \
        timeout 120 just repo-init </dev/null 2>&1); then
        rm -rf "$legacy_cfg"
        echo "$legacy_out" >&2
        echo "FAIL: a legacy minted tree (no (mint-answers)) was allowed to mint again" >&2; exit 1
    fi
    rm -rf "$legacy_cfg"
    grep -q 'cannot be minted again' <<<"$legacy_out" \
        || { echo "$legacy_out" >&2; echo "FAIL: the legacy minted tree was refused for the wrong reason" >&2; exit 1; }
    echo "PASS: a legacy minted tree refuses to mint again, by name; the mint checks below need a mintable tree"
    exit 0
fi

# A minted repository that recorded its answers ((mint-answers) in the deed,
# but no build/templates/identity.deed.in) is a child, not a template. This
# test mints "this checkout's tree" as the template, and a chain mint of a
# child needs the ROOT template commit its deed pins. So in such a child the
# test checks that boundary, by name, and stops. It snapshots the work tree
# into a fresh repository with no history, so the pin is absent whatever the
# child's own history holds, and deleted files stay deleted. A chain mint
# against that source must be refused before anything is written. It does
# not skip silently: a chain mint that went ahead, or failed for another
# reason, fails here.
if [[ ! -f "$repo/build/templates/identity.deed.in" ]]; then
    child="$work/minted-child"
    g init -q "$child"
    (cd "$repo" && git ls-files -z --cached --others --exclude-standard \
        | while IFS= read -r -d '' f; do [[ -e "$f" || -L "$f" ]] && printf '%s\0' "$f"; done \
        | tar --null -T - -cf -) | (cd "$child" && tar xf -)
    g -C "$child" add -A; g -C "$child" commit -q --allow-empty -m "minted child under test"
    child_cfg="$work/child-cfg"; mkdir -p "$child_cfg"; : > "$child_cfg/gitconfig"
    if child_out=$(cd "$child" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        XDG_CONFIG_HOME="$child_cfg" GIT_CONFIG_GLOBAL="$child_cfg/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        RSR_NON_INTERACTIVE=1 RSR_TEMPLATE_URL="$child" RSR_MINT_TOOL_CACHE="$work/tools" \
        PROJECT_NAME=grand-check REPO=grand-check OWNER=other-owner AUTHOR="Other Author" \
        AUTHOR_EMAIL=other@example.org PROJECT_DESCRIPTION="Grand tools" \
        timeout 600 just repo-init </dev/null 2>&1); then
        echo "$child_out" >&2
        fail "a minted child was chain-minted from a source that lacks its pinned template commit"
    fi
    grep -q "does not contain the parent's template commit" <<<"$child_out" \
        || { echo "$child_out" | tail -30 >&2; fail "the chain mint of a minted child was refused for the wrong reason"; }
    [[ -z "$(g -C "$child" status --porcelain)" ]] || fail "the refused chain mint wrote to the child"
    pass "a minted child refuses a chain mint from a source without its pinned template commit, by name, and writes nothing; the mint checks below need the template"
    exit 0
fi

# ── The template: this checkout's tree, committed or not, on main ───────────
T="$work/template"
g clone -q --no-local "$repo" "$T"
g -C "$T" checkout -q -B main
(cd "$repo" && git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) > "$work/tree.tar"
(cd "$T" && git ls-files -z | xargs -0 rm -f && tar xf "$work/tree.tar")
g -C "$T" add -A
g -C "$T" commit -q --allow-empty -m "template under test"
T_COMMIT=$(g -C "$T" rev-parse HEAD)
T_SLUG="$(sed -n -E 's/^OWNER[[:space:]]*:=[[:space:]]*"([^"]+)".*/\1/p' "$T/Justfile" | head -1)/$(sed -n -E 's/^REPO[[:space:]]*:=[[:space:]]*"([^"]+)".*/\1/p' "$T/Justfile" | head -1)"

# use_template FROM COMMITISH DIR ORIGIN — what "Use this template" makes.
use_template() {
    rm -rf "$3"; mkdir -p "$3"
    # The tree as a checkout writes it: GitHub copies the tree, it does not
    # git archive it (export-ignore, export-subst).
    GIT_INDEX_FILE="$work/use_template.index" g -C "$1" read-tree "$2"
    GIT_INDEX_FILE="$work/use_template.index" g -C "$1" checkout-index -a -f --prefix="$3/"
    rm -f "$work/use_template.index"
    # -f: a template copy keeps every tracked file, ignore rules or not.
    g -C "$3" init -q -b main; g -C "$3" add -f -A; g -C "$3" commit -q -m "Initial commit"
    g -C "$3" remote add origin "$4"
}
# mint DIR LOG REPO OWNER AUTHOR EMAIL DESC [ARCHETYPE [PROJECT_NAME]] — a
# non-interactive mint, isolated. The project name defaults to the repo name.
mint() {
    local cfg="$work/cfg"; mkdir -p "$cfg"; printf '%s' "${MINT_GITCONFIG:-}" > "$cfg/gitconfig"
    (cd "$1" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        ${RUSTUP_HOME:+RUSTUP_HOME="$RUSTUP_HOME"} ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} \
        XDG_CONFIG_HOME="$cfg" GIT_CONFIG_GLOBAL="$cfg/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        RSR_NON_INTERACTIVE=1 RSR_TEMPLATE_URL="${MINT_TEMPLATE_URL:-$T}" RSR_MINT_TOOL_CACHE="$work/tools" \
        PROJECT_NAME="${9:-$3}" REPO="$3" OWNER="$4" AUTHOR="$5" AUTHOR_EMAIL="$6" \
        PROJECT_DESCRIPTION="$7" timeout 1200 just repo-init ${8:+"$8"} </dev/null) > "$2" 2>&1
}

# ── The parent: a minted repo, then its own work ────────────────────────────
P="$work/parent"
use_template "$T" HEAD "$P" git@github.com:elder-owner/elder-proj.git
mint "$P" "$work/parent.log" elder-proj elder-owner "Eldra Author" elder@example.org "Elder tools" \
    || { tail -30 "$work/parent.log" >&2; fail 'the parent mint failed'; }
g -C "$P" add -A; g -C "$P" commit -q -m mint
printf '\nNotes for elder-proj users.\n' >> "$P/README.adoc"
mkdir -p "$P/notes"; printf 'elder-proj notes, see https://github.com/elder-owner/elder-proj\n' > "$P/notes/elder-proj-notes.md"
g -C "$P" rm -q .machine_readable/ai/PLACEHOLDERS.adoc
# A path holding characters special to sed and to deed strings, and a type
# change (a file the parent replaced with a symlink) (Codex review of #277).
printf 'odd name\n' > "$P/notes/R&D | \"q\".md"
rm "$P/SUPPORT.adoc"; ln -s README.adoc "$P/SUPPORT.adoc"
# A file listed in mint-verbatim.txt, deleted: the template's own preflights
# must not stop a chain mint over the parent's choices (Codex review of #277).
g -C "$P" rm -q tests/e2e/template_instantiation_test.sh
# Path bytes tar's line mode would mangle: a backslash and a leading dash; a
# file under archetypes/, which the mint declares removed; and an identity
# setting naming the parent's owner (all Codex review of #277).
printf 'slash\n' > "$P/notes/back\\slash.txt"
printf 'dash\n' > "$P/-lead.txt"
mkdir -p "$P/archetypes"; printf 'mine\n' > "$P/archetypes/custom.txt"
printf 'sonar.organization=elder-owner\nsonar.projectKey=elder-owner_elder-proj\n' > "$P/notes/extra-sonar.properties"
# A carried generator that writes one more file when it runs: its output is
# measured after it runs, and declared (Codex review of #277).
sed -i 's|^set -euo pipefail$|&\nprintf '"'"'extra\\n'"'"' > "$(git rev-parse --show-toplevel)/generated-extra.txt"|' "$P/.machine_readable/arrival-pack/generate.sh"
grep -q 'generated-extra.txt' "$P/.machine_readable/arrival-pack/generate.sh" || fail 'fixture: the generator was not changed'
# The same generator recreates a mint-produced file the parent deleted, with
# other content: its category moves from removed to diverged, and the
# declaration must follow it (Codex review of #277).
[ -f "$P/docs/usage.adoc" ] || fail 'fixture: the mint produced no docs/usage.adoc'
g -C "$P" rm -q docs/usage.adoc
sed -i 's|^set -euo pipefail$|&\nprintf '"'"'regenerated usage\\n'"'"' > "$(git rev-parse --show-toplevel)/docs/usage.adoc"|' "$P/.machine_readable/arrival-pack/generate.sh"
grep -q 'regenerated usage' "$P/.machine_readable/arrival-pack/generate.sh" || fail 'fixture: the usage generator was not added'
# The generator's intermediate data, force-added: an artefact, never carried
# or declared (Codex review of #277).
[ -f "$P/.machine_readable/arrival-pack/claude-md-data.json" ] || fail 'fixture: the mint left no claude-md-data.json'
g -C "$P" add -f .machine_readable/arrival-pack/claude-md-data.json
# A file the grandchild's checkout will turn into a directory (below).
printf 'plain\n' > "$P/notes/to-become-dir.txt"
# A file the parent tracks although an ignore rule matches it: still its own.
mkdir -p "$P/_build"; printf 'kept\n' > "$P/_build/keep.txt"
g -C "$P" check-ignore -q _build/keep.txt || fail 'fixture: _build/ is not ignored'
g -C "$P" add -f _build/keep.txt
# A file under a filter the grandchild's checkout configures (below), whose
# content the rename pass changes, so the write-back must check it out.
printf 'elder-proj filtered note\n' > "$P/notes/elder.bad"
# A carried gate with a side effect: what it writes while the gates run is
# not part of the result (Codex review of #277).
sed -i '1a printf "side\\n" > gate-output.txt' "$P/scripts/check-container-pins.sh"
grep -q 'gate-output.txt' "$P/scripts/check-container-pins.sh" || fail 'fixture: the gate side effect was not added'
# The identity template's path, added back as the parent's own file: the
# deed's (mint-answers) still marks the parent as minted, so the grandchild is
# chain-minted and the file carried as its work (Codex review of #277).
mkdir -p "$P/build/templates"; printf 'my own identity notes\n' > "$P/build/templates/identity.deed.in"
g -C "$P" add -A; g -C "$P" commit -q -m "the parent's own work"
pass "fixture: a minted parent with its own edit, addition and removal"

# ── The grandchild: "Use this template" on the parent, then a chain mint ────
G="$work/grandchild"
use_template "$P" HEAD "$G" git@github.com:other-owner/grand-check.git
# Uncommitted work in the checkout is carried too, and :derived-from-tree must
# name the snapshot actually used, not HEAD^{tree} (Codex review of #277).
printf 'local\n' > "$G/notes/local.txt"
# A tracked file turned into a directory holding an ignored file: the ignored
# file must not be read into the chain (Codex review of #277: tar recursed into
# the directory and carried it).
rm "$G/notes/to-become-dir.txt"; mkdir "$G/notes/to-become-dir.txt"
printf 'not for the chain\n' > "$G/notes/to-become-dir.txt/secret.txt"
printf '/notes/to-become-dir.txt/secret.txt\n' >> "$G/.git/info/exclude"
HEAD_TREE=$(g -C "$G" rev-parse 'HEAD^{tree}')
cp "$G/.git/index" "$work/snap.index"   # tracked files stay, ignore rules or not
P_TREE=$(cd "$G" && GIT_INDEX_FILE="$work/snap.index" git add -A . && GIT_INDEX_FILE="$work/snap.index" git write-tree)
[ "$P_TREE" != "$HEAD_TREE" ] || fail 'fixture: the uncommitted file did not change the tree'
# Under a global init.templateDir whose info/attributes would re-encode the
# template clone's checkouts: the chain's clone must not take it (Codex review
# of #277).
mkdir -p "$work/inittpl/info"; printf 'README.adoc working-tree-encoding=UTF-16\n' > "$work/inittpl/info/attributes"
MINT_GITCONFIG="$(printf '[init]\n\ttemplateDir = %s\n' "$work/inittpl")"
mint "$G" "$work/chain.log" grand-check other-owner "Other Author" other@example.org "Grand tools" \
    || { tail -40 "$work/chain.log" >&2; fail 'the chain mint failed'; }
MINT_GITCONFIG=""
grep -q 'minted as a chain' "$work/chain.log" || fail 'repo-init did not take the chain path'
pass "a minted repo is minted again, as a chain"

DEED="$G/grand-check_chora.deed"
[ -f "$DEED" ] && [ ! -e "$G/elder-proj_chora.deed" ] || fail 'the deed is not the grandchild'"'"'s alone'
field() { bash "$G/scripts/deed-field.sh" "$DEED" "$@"; }
[ "$(field provenance template-repo)" = "$T_SLUG" ] && [ "$(field provenance template-commit)" = "$T_COMMIT" ] \
    || fail "provenance names $(field provenance template-repo)@$(field provenance template-commit), not the root template"
[ "$(field provenance derived-from)" = elder-owner/elder-proj ] || fail 'provenance does not name the parent'
[ "$(field provenance derived-from-tree)" = "$P_TREE" ] || fail 'provenance does not name the parent tree'
[ "$(field mint-answers author)" = "Other Author" ] && [ "$(field mint-answers description)" = "Grand tools" ] \
    || fail '(mint-answers) are not the grandchild'"'"'s'
pass "provenance names the root template commit and the parent; the answers are the grandchild's"

# Nothing of the parent's identity or contacts survives (the Codex finding).
# A file identical to the template's own copy is template text, not a leak
# (this test and the recipe name these fixtures on purpose).
leak=$(cd "$G" && git ls-files -co --exclude-standard | grep -vxF grand-check_chora.deed \
       | while IFS= read -r f; do
             [ -f "$f" ] || continue
             g -C "$T" show "$T_COMMIT:$f" 2>/dev/null | cmp -s -- - "$f" && continue
             grep -lIE 'elder-proj|Eldra Author|elder@example\.org|Elder tools' -- "$f"
         done || true)
[ -z "$leak" ] || { echo "$leak" >&2; fail 'the parent'"'"'s identity or contacts survive in the files above'; }
grep -q 'Eldra Author\|elder@example.org' "$DEED" && fail 'the deed carries the parent'"'"'s author'
grep -qF 'Grand tools' "$G/README.adoc" && grep -qF 'other@example.org' "$G/.github/SECURITY.adoc" 2>/dev/null \
    || grep -rqF 'other@example.org' "$G/.github" || fail 'the new contacts were not rendered'
pass "nothing of the parent's identity, author or contacts survives; the new answers are rendered"

# The parent's own work is carried, renamed, and declared. The rename is the
# self-name rule: the repo name and the owner/repo slug, never a bare owner
# (an owner is shared with real estate repos, the same reason the template's
# owner pass is narrow).
tail -n 1 "$G/README.adoc" | grep -qx 'Notes for grand-check users.' || fail 'the parent'"'"'s README edit was not carried and renamed'
grep -qx 'grand-check notes, see https://github.com/other-owner/grand-check' "$G/notes/elder-proj-notes.md" \
    || fail 'the parent'"'"'s added file was not carried and renamed'
[ ! -e "$G/.machine_readable/ai/PLACEHOLDERS.adoc" ] || fail 'the parent'"'"'s removal was not carried'
[ ! -e "$G/tests/e2e/template_instantiation_test.sh" ] || fail 'the deletion of a verbatim-listed file was not carried'
[ -f "$G/notes/local.txt" ] || fail 'uncommitted work in the checkout was not carried'
bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths added | grep -qx notes/elder-proj-notes.md \
    && bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths diverged | grep -qx README.adoc \
    && bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths removed | grep -qx .machine_readable/ai/PLACEHOLDERS.adoc \
    || { grep -n ':added\|:removed\|:diverged' "$DEED" >&2; fail 'the carried work is not declared in (variant (paths))'; }
bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths added | grep -qxF 'notes/R&D | "q".md' \
    || { grep -n ':added' "$DEED" >&2; fail 'a path with & | and quotes was not declared intact'; }
[ -L "$G/SUPPORT.adoc" ] && bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths diverged | grep -qx SUPPORT.adoc \
    || fail 'the type change (file to symlink) was not carried and declared'
added() { bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths added; }
[ -f "$G/notes/back\\slash.txt" ] && [ -f "$G/-lead.txt" ] \
    && added | grep -qxF 'notes/back\slash.txt' && added | grep -qxF -- '-lead.txt' \
    || { grep -n ':added' "$DEED" >&2; fail 'a path holding a backslash or a leading dash was not carried and declared intact'; }
[ -f "$G/archetypes/custom.txt" ] && added | grep -qx archetypes/custom.txt \
 && added | grep -qx _build/keep.txt && [ -n "$(g -C "$G" ls-files -- _build/keep.txt)" ] \
    || fail 'a tracked file an ignore rule matches was not carried, tracked and declared'
[ "$(cat "$G/notes/extra-sonar.properties")" = "$(printf 'sonar.organization=other-owner\nsonar.projectKey=other-owner_grand-check')" ] \
    || { cat "$G/notes/extra-sonar.properties" >&2; fail 'a carried identity setting kept the parent'"'"'s owner'; }
pass "the parent's edit, addition and removal are carried, renamed, and declared"
pass "odd path bytes, an addition under a removed directory and a carried owner setting are handled"
[ "$(cat "$G/generated-extra.txt" 2>/dev/null)" = extra ] && added | grep -qx generated-extra.txt \
    || { grep -n ':added' "$DEED" >&2; fail 'a file written by a carried generator was not measured and declared'; }
diverged() { bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths diverged; }
removed() { bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths removed; }
[ "$(cat "$G/docs/usage.adoc" 2>/dev/null)" = 'regenerated usage' ] && diverged | grep -qx docs/usage.adoc \
    && ! removed | grep -qx docs/usage.adoc \
    || { grep -n ':removed\|:diverged' "$DEED" >&2; fail 'a deleted file a carried generator recreated is not declared diverged'; }
if grep -qF 'claude-md-data.json' "$DEED"; then fail 'the generator'"'"'s force-added intermediate data was declared'; fi
if grep -qF 'to-become-dir.txt/secret' "$DEED" || g -C "$G" ls-files -co --exclude-standard | grep -qF 'to-become-dir.txt/secret'; then
    fail 'an ignored file inside a path that became a directory was carried'
fi
[ "$(cat "$G/notes/to-become-dir.txt/secret.txt")" = 'not for the chain' ] || fail 'the ignored file was changed'
pass "a carried generator's output is declared; an ignored file is never read into the chain"
[ "$(cat "$G/build/templates/identity.deed.in" 2>/dev/null)" = 'my own identity notes' ] \
    && added | grep -qx build/templates/identity.deed.in \
    || { grep -n ':added' "$DEED" >&2; fail 'a parent that added the identity template back was not chain-minted with it carried'; }
pass "a minted parent carrying build/templates/identity.deed.in is still chain-minted"
[ ! -e "$G/gate-output.txt" ] && ! grep -q 'gate-output.txt' "$DEED" \
    || fail 'a file a gate wrote while the gates ran was carried into the result'
pass "what the gates write while they run is not part of the result"

# The grandchild's drift gate replays ITS mint: green, carried work declared.
g -C "$G" add -A; g -C "$G" commit -q -m "chain mint"
(cd "$G" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/drift.log" 2>&1 \
    || { cat "$work/drift.log" >&2; fail 'the grandchild'"'"'s drift gate is red'; }
(cd "$G" && bash scripts/gen-repo-map.sh . >/dev/null) && g -C "$G" diff --quiet -- docs/architecture/REPOSITORY-MAP.adoc \
    || fail 'the grandchild'"'"'s map is stale'
pass "the grandchild's drift gate (a replay of its own mint) is green; its map is fresh"

# ── Negative control: a parent edit that conflicts with the new rendering ───
# The parent rewrote the rendered description line; the new mint renders a
# different description on that line. That is a real conflict: stop, write
# nothing, name the file.
P2="$work/parent2"
g clone -q --no-local "$P" "$P2"
sed -i 's/^Elder tools$/Elder tools, rewritten by hand/' "$P2/README.adoc"
grep -qx 'Elder tools, rewritten by hand' "$P2/README.adoc" || fail 'fixture: the description line was not found'
g -C "$P2" commit -q -am "hand edit of a rendered line"
G2="$work/grandchild2"
use_template "$P2" HEAD "$G2" git@github.com:other-owner/grand-check.git
if mint "$G2" "$work/conflict.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a conflicting parent edit was merged silently'
fi
grep -q 'conflict' "$work/conflict.log" && grep -q 'README.adoc' "$work/conflict.log" \
    || { tail -20 "$work/conflict.log" >&2; fail 'the conflict was not reported with its file'; }
[ -z "$(g -C "$G2" status --porcelain)" ] || fail 'the refused chain mint wrote to the tree'
pass "(-) a conflicting parent edit stops the chain before it writes, and names the file"

# ── Negative control: a parent minted before (mint-answers) is refused ──────
G3="$work/grandchild3"
use_template "$P" HEAD "$G3" git@github.com:other-owner/grand-check.git
bash "$G3/scripts/deed-clause.sh" replace "$G3/elder-proj_chora.deed" mint-answers /dev/null
! bash "$G3/scripts/deed-field.sh" --has "$G3/elder-proj_chora.deed" mint-answers || fail 'fixture: (mint-answers) still present'
# Nor the identity template the main parent added back: an old child has neither.
g -C "$G3" rm -q build/templates/identity.deed.in
g -C "$G3" commit -q -am "an old child"
if mint "$G3" "$work/old.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a parent without (mint-answers) was minted'
fi
grep -q 'records no (mint-answers)' "$work/old.log" || { tail -10 "$work/old.log" >&2; fail 'the refusal did not say why'; }
[ -z "$(g -C "$G3" status --porcelain)" ] || fail 'the refused mint wrote to the tree'
pass "(-) a parent minted before (mint-answers) is refused before anything is written"

# ── Negative control: a failure after the merge writes nothing ──────────────
# The parent carries a broken arrival-pack source: both replays pass (they use
# the pinned template), the merge succeeds, then regenerating CLAUDE.md from
# the merged tree fails. Every step runs in a scratch copy first, so the
# grandchild is untouched (Codex review of #277: the checkout used to be
# replaced before the later steps ran). (A carried unfilled token is refused
# even earlier, by check-mint-tokens.sh, before anything is written.)
P4="$work/parent4"
g clone -q --no-local "$P" "$P4"
printf 'this is not nickel\n' >> "$P4/.machine_readable/arrival-pack/arrival-pack.ncl"
g -C "$P4" commit -q -am "a broken arrival-pack source"
G4="$work/grandchild4"
use_template "$P4" HEAD "$G4" git@github.com:other-owner/grand-check.git
if mint "$G4" "$work/late.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint carrying a broken arrival-pack source succeeded'
fi
grep -q 'arrival pack could not be regenerated; nothing was written' "$work/late.log" || { tail -20 "$work/late.log" >&2; fail 'the late failure did not say why'; }
[ -z "$(g -C "$G4" status --porcelain)" ] || { g -C "$G4" status --short | head >&2; fail 'a failure after the merge wrote to the tree'; }
pass "(-) a failure after the merge (a broken carried source) leaves the tree untouched"

# ── Negative control: a chain mint keeps the parent's archetype ─────────────
# `just repo-init <archetype>` on a chain must not die on the absent
# archetypes/ (Codex review of #277); naming a different archetype is refused.
G5="$work/grandchild5"
use_template "$P" HEAD "$G5" git@github.com:other-owner/grand-check.git
if (cd "$G5" && env -i PATH="$PATH" HOME="$HOME" RSR_NON_INTERACTIVE=1 just repo-init julia-library </dev/null) > "$work/arch.log" 2>&1; then
    fail 'a chain mint accepted a different archetype'
fi
grep -q "was minted as archetype 'none'; a chain mint keeps it" "$work/arch.log" || { cat "$work/arch.log" >&2; fail 'the archetype refusal did not say why'; }
[ -z "$(g -C "$G5" status --porcelain)" ] || fail 'the refused archetype wrote to the tree'
pass "(-) a chain mint refuses an archetype other than the parent's, before writing"

# ── Negative control: parent-controlled symlinks never redirect a write ─────
# The parent makes its identity file CLAUDE.md, and a path the mint writes
# (the arrival pack's generated data), symlinks to files outside the chain's
# scratch copy (Codex review of #277). The identity file is held in git's
# index, so its link is never written through; the generated path is refused
# by name before anything is written. Neither target changes.
P6="$work/parent6"
g clone -q --no-local "$P" "$P6"
printf 'untouched\n' > "$work/sentinel-identity"; printf 'untouched\n' > "$work/sentinel-output"
rm "$P6/CLAUDE.md"; ln -s "$work/sentinel-identity" "$P6/CLAUDE.md"
rm -f "$P6/.machine_readable/arrival-pack/claude-md-data.json"   # the parent force-tracks it
ln -s "$work/sentinel-output" "$P6/.machine_readable/arrival-pack/claude-md-data.json"
g -C "$P6" add -f -A; g -C "$P6" commit -q -m "symlinks out"
G6="$work/grandchild6"
use_template "$P6" HEAD "$G6" git@github.com:other-owner/grand-check.git
if mint "$G6" "$work/links.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint wrote through a carried symlink'
fi
grep -q 'symlink at .machine_readable/arrival-pack/claude-md-data.json' "$work/links.log" || { tail -20 "$work/links.log" >&2; fail 'the carried output symlink was not refused by name'; }
[ "$(cat "$work/sentinel-identity")" = untouched ] && [ "$(cat "$work/sentinel-output")" = untouched ] \
    || fail 'a chain mint wrote through a parent-controlled symlink'
[ -z "$(g -C "$G6" status --porcelain)" ] || fail 'the refused chain mint wrote to the tree'
pass "(-) parent-controlled symlinks are never written through; one at a written path is refused"
# The arrival-pack generator writes temporary files too: a carried symlink at
# one is refused by name (Codex review of #277).
P8="$work/parent8"
g clone -q --no-local "$P" "$P8"
printf 'untouched\n' > "$work/sentinel-region"
ln -s "$work/sentinel-region" "$P8/.machine_readable/arrival-pack/.region.tmp"
g -C "$P8" add -f .machine_readable/arrival-pack/.region.tmp; g -C "$P8" commit -q -m "a symlink at a temporary path"
G8="$work/grandchild8"
use_template "$P8" HEAD "$G8" git@github.com:other-owner/grand-check.git
if mint "$G8" "$work/region.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint ran with a symlink at the generator'"'"'s temporary path'
fi
grep -q 'symlink at .machine_readable/arrival-pack/.region.tmp' "$work/region.log" \
    || { tail -20 "$work/region.log" >&2; fail 'the symlink at the temporary path was not refused by name'; }
[ "$(cat "$work/sentinel-region")" = untouched ] && [ -z "$(g -C "$G8" status --porcelain)" ] \
    || fail 'the refused chain mint wrote through the symlink or to the tree'
pass "(-) a symlink at the generator's temporary path is refused before anything is written"

# The baselines replay the mint with the wrapper at the pin: a parent that
# edited its own copy cannot change what counts as its own work (Codex review
# of #277). This one removes README.adoc after every replay.
P11="$work/parent11"
g clone -q --no-local "$P" "$P11"
g -C "$P11" reset -q --hard HEAD~1   # the parent's mint, before its own work
printf 'rm -f "$OUT/README.adoc"\n' >> "$P11/scripts/replay-mint.sh"
g -C "$P11" commit -q -am "an edited replay wrapper"
G11="$work/grandchild11"
use_template "$P11" HEAD "$G11" git@github.com:other-owner/grand-check.git
mint "$G11" "$work/wrapper.log" grand-check other-owner "Other Author" other@example.org "Grand tools" \
    || { tail -40 "$work/wrapper.log" >&2; fail 'the chain mint of a parent with an edited replay wrapper failed'; }
if grep -qE 'elder-proj|Elder tools|Eldra Author' "$G11/README.adoc" \
   || bash "$G11/scripts/deed-field.sh" --list "$G11/grand-check_chora.deed" variant/paths added | grep -qx README.adoc; then
    fail 'the parent'"'"'s edited replay wrapper redefined the baseline: its README was carried as its own work'
fi
grep -qF 'Grand tools' "$G11/README.adoc" || fail 'the README was not rendered for the grandchild'
# The grandchild carries the edited wrapper (its parent's work, declared), and
# its own drift gate replays with the wrapper at the pin too (Codex review of
# #277): green.
g -C "$G11" add -A; g -C "$G11" commit -q -m "chain mint"
(cd "$G11" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/wrapperdrift.log" 2>&1 \
    || { cat "$work/wrapperdrift.log" >&2; fail 'the drift gate replayed with the carried, edited wrapper'; }
pass "the baselines replay with the wrapper at the pin, not the parent's edited copy; so does the drift gate"

# A path holding byte 0x01, the deed reader's record separator, cannot be
# declared: refused by name, before anything is written (Codex review of #277).
P12="$work/parent12"
g clone -q --no-local "$P" "$P12"
printf 'x\n' > "$P12/notes/soh"$'\001'"name.txt"
g -C "$P12" add -A; g -C "$P12" commit -q -m "a path holding 0x01"
G12="$work/grandchild12"
use_template "$P12" HEAD "$G12" git@github.com:other-owner/grand-check.git
if mint "$G12" "$work/soh.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint declared a path holding byte 0x01'
fi
grep -q 'newline or byte 0x01' "$work/soh.log" || { tail -20 "$work/soh.log" >&2; fail 'the 0x01 path was not refused by name'; }
[ -z "$(g -C "$G12" status --porcelain)" ] || fail 'the refused chain mint wrote to the tree'
pass "(-) a carried path holding byte 0x01 is refused before anything is written"

# A smudge filter that fails during the write-back stops the chain before the
# checkout is touched: read-tree -u is not atomic (Codex review of #277).
G10="$work/grandchild10"
use_template "$P" HEAD "$G10" git@github.com:other-owner/grand-check.git
g -C "$G10" config filter.bad.clean cat; g -C "$G10" config filter.bad.smudge false; g -C "$G10" config filter.bad.required true
printf '*.bad filter=bad\n' >> "$G10/.gitattributes"
g10_before=$(g -C "$G10" status --porcelain --untracked-files=all); g10_readme=$(sha256sum < "$G10/README.adoc")
if mint "$G10" "$work/filter.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint went ahead with a smudge filter that fails'
fi
grep -q 'a filter failed' "$work/filter.log" || { tail -20 "$work/filter.log" >&2; fail 'the failing filter was not reported'; }
[ "$(g -C "$G10" status --porcelain --untracked-files=all)" = "$g10_before" ] \
    && [ "$(sha256sum < "$G10/README.adoc")" = "$g10_readme" ] && [ "$(cat "$G10/notes/elder.bad")" = 'elder-proj filtered note' ] \
    || { g -C "$G10" status --porcelain >&2; fail 'the chain mint wrote part of the result before the filter failed'; }
pass "(-) a smudge filter that fails is found before anything is written"

# ── A declaration that changes only in category ─────────────────────────────
# A parent, just minted, deletes .clinerules and changes its carried generator
# to recreate it: measured before the generator runs, the path is removed;
# after, it is diverged, beside the generator itself. Both measures list the
# same paths in the same order, so only the categories tell them apart (Codex
# review of #277): the deed must declare it diverged, and the drift gate agree.
P7="$work/parent7"
g clone -q --no-local "$P" "$P7"
g -C "$P7" reset -q --hard HEAD~1   # the parent's mint, before its own work
[ -f "$P7/.clinerules" ] || fail 'fixture: the mint produced no .clinerules'
g -C "$P7" rm -q .clinerules
sed -i 's|^set -euo pipefail$|&\nprintf '"'"'regenerated rules\\n'"'"' > "$(git rev-parse --show-toplevel)/.clinerules"|' "$P7/.machine_readable/arrival-pack/generate.sh"
g -C "$P7" commit -q -am "the generator owns .clinerules"
G7="$work/grandchild7"
use_template "$P7" HEAD "$G7" git@github.com:other-owner/grand-check.git
mint "$G7" "$work/category.log" grand-check other-owner "Other Author" other@example.org "Grand tools" \
    || { tail -40 "$work/category.log" >&2; fail 'the category-only chain mint failed'; }
D7="$G7/grand-check_chora.deed"
[ "$(cat "$G7/.clinerules")" = 'regenerated rules' ] \
    && bash "$G7/scripts/deed-field.sh" --list "$D7" variant/paths diverged | grep -qx .clinerules \
    && ! bash "$G7/scripts/deed-field.sh" --list "$D7" variant/paths removed | grep -qx .clinerules \
    || { grep -n ':removed\|:diverged' "$D7" >&2; fail 'a path whose category alone changed was declared by its first measure'; }
g -C "$G7" add -A; g -C "$G7" commit -q -m "chain mint"
(cd "$G7" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/catdrift.log" 2>&1 \
    || { cat "$work/catdrift.log" >&2; fail 'the drift gate is red after a category-only change'; }
pass "a path whose category alone changes after the generators run is declared by its final category"

# ── Negative control: a sparse checkout is refused ──────────────────────────
# Its absent paths would read as deletions of most of the repository (Codex
# review of #277).
G7="$work/grandchild7"
use_template "$P" HEAD "$G7" git@github.com:other-owner/grand-check.git
# The mint machinery stays checked out; docs/ and tests/ do not.
g -C "$G7" sparse-checkout set scripts build .machine_readable notes
[ ! -e "$G7/docs" ] && [ -e "$G7/scripts/chain-mint.sh" ] || fail 'fixture: the checkout is not sparse'
if mint "$G7" "$work/sparse.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint ran in a sparse checkout'
fi
grep -q 'this checkout is sparse' "$work/sparse.log" || { tail -20 "$work/sparse.log" >&2; fail 'the sparse refusal did not say why'; }
[ -z "$(g -C "$G7" status --porcelain)" ] || fail 'the refused sparse chain mint wrote to the tree'
pass "(-) a chain mint in a sparse checkout is refused before anything is written"

# ── Negative controls: a checkout a chain mint cannot read faithfully ───────
# An unresolved merge, and a tracked path beneath a symlink, are refused before
# anything is read or written (Codex review of #277).
GU="$work/grandchild-unmerged"
use_template "$P" HEAD "$GU" git@github.com:other-owner/grand-check.git
g -C "$GU" checkout -q -b side; printf 'side\n' >> "$GU/README.adoc"; g -C "$GU" commit -q -am side
g -C "$GU" checkout -q main; printf 'main\n' >> "$GU/README.adoc"; g -C "$GU" commit -q -am main
if g -C "$GU" merge -q side >/dev/null 2>&1; then fail 'fixture: the merge did not conflict'; fi
gu_before=$(g -C "$GU" status --porcelain)
if mint "$GU" "$work/unmerged.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint ran over an unresolved merge'
fi
grep -q 'unresolved merge' "$work/unmerged.log" || { tail -20 "$work/unmerged.log" >&2; fail 'the unresolved merge was not refused by name'; }
[ "$(g -C "$GU" status --porcelain)" = "$gu_before" ] || fail 'the refused chain mint wrote to the tree'
GL="$work/grandchild-link"
use_template "$P" HEAD "$GL" git@github.com:other-owner/grand-check.git
mv "$GL/notes" "$work/outside-notes"; ln -s "$work/outside-notes" "$GL/notes"
gl_before=$(g -C "$GL" status --porcelain)
if mint "$GL" "$work/linkdir.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint read tracked paths through a symlink'
fi
grep -q 'lies beneath the symlink notes' "$work/linkdir.log" || { tail -20 "$work/linkdir.log" >&2; fail 'the symlinked directory was not refused by name'; }
[ "$(g -C "$GL" status --porcelain)" = "$gl_before" ] || fail 'the refused chain mint wrote to the tree'
pass "(-) an unresolved merge, and tracked paths beneath a symlink, are refused before anything is read"

# ── Negative control: the result must pass the child's own gates ────────────
# A carried shell script without an SPDX header fails check-spdx-headers, as a
# normal mint would; the chain stops before writing (Codex review of #277).
P9="$work/parent9"
g clone -q --no-local "$P" "$P9"
printf '#!/bin/sh\necho hi\n' > "$P9/notes/tool.sh"
g -C "$P9" add -A; g -C "$P9" commit -q -m "a script without a header"
G9="$work/grandchild9"
use_template "$P9" HEAD "$G9" git@github.com:other-owner/grand-check.git
if mint "$G9" "$work/gates.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint wrote a tree that fails its own gates'
fi
grep -q 'fails check-spdx-headers' "$work/gates.log" && grep -q 'notes/tool.sh' "$work/gates.log" \
    || { tail -30 "$work/gates.log" >&2; fail 'the gate failure was not named'; }
[ -z "$(g -C "$G9" status --porcelain)" ] || fail 'the gate-refused chain mint wrote to the tree'
pass "(-) a result that fails the child's own gates is refused before writing"

# ── An answer-dependent rename: a Julia package's entry point ───────────────
# The mint names src/<Package>.jl after the project, so a parent's edit to its
# entry point lives at another path in the grandchild. The merge carries the
# edit across that rename; the declaration must name where it now lives
# (Codex review of #277), which the grandchild's drift gate checks.
JP="$work/jparent"
use_template "$T" HEAD "$JP" git@github.com:elder-owner/ElderPkg.jl.git
mint "$JP" "$work/jparent.log" ElderPkg.jl elder-owner "Eldra Author" elder@example.org "Elder tools" julia-library ElderPkg \
    || { tail -30 "$work/jparent.log" >&2; fail 'the Julia parent mint failed'; }
[ -f "$JP/src/ElderPkg.jl" ] || fail 'fixture: the Julia parent has no src/ElderPkg.jl'
g -C "$JP" add -A; g -C "$JP" commit -q -m mint
sed -i 's/^# --- implementation .*/&\nanswer() = 42/' "$JP/src/ElderPkg.jl"
grep -qx 'answer() = 42' "$JP/src/ElderPkg.jl" || fail 'fixture: the entry-point edit did not apply'
g -C "$JP" commit -q -am "the parent's own code"
JG="$work/jgrandchild"
use_template "$JP" HEAD "$JG" git@github.com:other-owner/GrandPkg.jl.git
mint "$JG" "$work/jchain.log" GrandPkg.jl other-owner "Other Author" other@example.org "Grand tools" julia-library GrandPkg \
    || { tail -40 "$work/jchain.log" >&2; fail 'the Julia chain mint failed'; }
[ -f "$JG/src/GrandPkg.jl" ] && [ ! -e "$JG/src/ElderPkg.jl" ] && grep -qx 'answer() = 42' "$JG/src/GrandPkg.jl" \
    || { ls "$JG/src" >&2; fail 'the entry-point edit was not carried across the rename'; }
JDEED="$JG/GrandPkg.jl_chora.deed"
bash "$JG/scripts/deed-field.sh" --list "$JDEED" variant/paths diverged | grep -qx src/GrandPkg.jl \
    || { grep -n ':added\|:removed\|:diverged' "$JDEED" >&2; fail 'the renamed entry point is not declared where it now lives'; }
if bash "$JG/scripts/deed-field.sh" --list "$JDEED" variant/paths diverged | grep -qx src/ElderPkg.jl; then
    fail 'the deed declares the parent'"'"'s entry-point path'
fi
g -C "$JG" add -A; g -C "$JG" commit -q -m "chain mint"
(cd "$JG" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/jdrift.log" 2>&1 \
    || { cat "$work/jdrift.log" >&2; fail 'the Julia grandchild'"'"'s drift gate is red'; }
pass "an edit carried across an answer-dependent rename is declared where it lives; the drift gate is green"
# A path the result writes must be free, before anything is written: here an
# ignored directory at the grandchild's future entry point (Codex review of
# #277: the checkout used to be emptied before the copy found it). Ignored
# through this checkout's info/exclude, and through a .gitignore, where git's
# own check sees the rule and treats the directory as expendable.
for how in exclude gitignore; do
    JG2="$work/jgrandchild2-$how"
    use_template "$JP" HEAD "$JG2" git@github.com:other-owner/GrandPkg.jl.git
    mkdir -p "$JG2/src/GrandPkg.jl"; printf 'mine\n' > "$JG2/src/GrandPkg.jl/notes.txt"
    case "$how" in
        exclude) printf '/src/GrandPkg.jl/\n' >> "$JG2/.git/info/exclude" ;;
        gitignore) printf '/src/GrandPkg.jl/\n' >> "$JG2/.gitignore" ;;
    esac
    g -C "$JG2" check-ignore -q src/GrandPkg.jl/notes.txt || fail "fixture ($how): the directory is not ignored"
    jg2_before=$(g -C "$JG2" status --porcelain --untracked-files=all --ignored)
    if mint "$JG2" "$work/collide-$how.log" GrandPkg.jl other-owner "Other Author" other@example.org "Grand tools" julia-library GrandPkg; then
        fail "a chain mint overwrote an ignored directory ($how)"
    fi
    grep -q 'without overwriting' "$work/collide-$how.log" && grep -qx '    src/GrandPkg.jl/' "$work/collide-$how.log" \
        || { tail -20 "$work/collide-$how.log" >&2; fail "the collision was not refused by name ($how)"; }
    [ "$(cat "$JG2/src/GrandPkg.jl/notes.txt")" = mine ] \
        && [ "$(g -C "$JG2" status --porcelain --untracked-files=all --ignored)" = "$jg2_before" ] \
        && [ -f "$JG2/src/ElderPkg.jl" ] || fail "the refused chain mint wrote to the tree ($how)"
done
pass "(-) an ignored entry where the result writes is refused by name before anything is written (info/exclude and .gitignore)"
# A parent that deleted its entry point: the deletion wins across the rename
# too, where the fresh mint has src/GrandPkg.jl, not a rename/delete conflict
# (Codex review of #277).
g -C "$JP" checkout -q -b drop-entry
g -C "$JP" rm -q src/ElderPkg.jl; g -C "$JP" commit -q -m "drop the entry point"
JG3="$work/jgrandchild3"
use_template "$JP" drop-entry "$JG3" git@github.com:other-owner/GrandPkg.jl.git
mint "$JG3" "$work/jdrop.log" GrandPkg.jl other-owner "Other Author" other@example.org "Grand tools" julia-library GrandPkg \
    || { tail -40 "$work/jdrop.log" >&2; fail 'a parent deletion across an answer-dependent rename stopped the chain'; }
[ ! -e "$JG3/src/GrandPkg.jl" ] && [ ! -e "$JG3/src/ElderPkg.jl" ] || { ls "$JG3/src" >&2; fail 'the deleted entry point came back'; }
bash "$JG3/scripts/deed-field.sh" --list "$JG3/GrandPkg.jl_chora.deed" variant/paths removed | grep -qx src/GrandPkg.jl \
    || { grep -n ':removed' "$JG3/GrandPkg.jl_chora.deed" >&2; fail 'the deletion is not declared where the fresh mint has the file'; }
g -C "$JG3" add -A; g -C "$JG3" commit -q -m "chain mint"
(cd "$JG3" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/jdropdrift.log" 2>&1 \
    || { cat "$work/jdropdrift.log" >&2; fail 'the grandchild of a parent without its entry point has a red drift gate'; }
pass "a parent deletion is carried across an answer-dependent rename and declared; the drift gate is green"

# A parent that changed its entry point's type (a file to a symlink): the
# fresh mint puts that file elsewhere, so the change cannot be carried there.
# Refused by name, not carried beside the fresh file (Codex review of #277).
g -C "$JP" checkout -q -b retype-entry main 2>/dev/null || g -C "$JP" checkout -q -b retype-entry master
g -C "$JP" rm -q src/ElderPkg.jl; ln -s ../README.adoc "$JP/src/ElderPkg.jl"; g -C "$JP" add src/ElderPkg.jl
g -C "$JP" commit -q -m "the entry point becomes a symlink"
JG4="$work/jgrandchild4"
use_template "$JP" retype-entry "$JG4" git@github.com:other-owner/GrandPkg.jl.git
if mint "$JG4" "$work/jretype.log" GrandPkg.jl other-owner "Other Author" other@example.org "Grand tools" julia-library GrandPkg; then
    fail 'a type change across an answer-dependent rename was carried'
fi
grep -q 'changed the type of src/ElderPkg.jl, which this mint renames to src/GrandPkg.jl' "$work/jretype.log" \
    || { tail -20 "$work/jretype.log" >&2; fail 'the type change across the rename was not refused by name'; }
[ -z "$(g -C "$JG4" status --porcelain)" ] || fail 'the refused chain mint wrote to the tree'
pass "(-) a type change across an answer-dependent rename is refused before anything is written"

# ── A parent that renamed its deed, from a template reached as a user would ─
# The replayed base still has the deed's old name: it is identity, held like
# the live name, not a deletion that takes the fresh deed with it (Codex
# review of #277). The template is fetched as a partial clone through a URL
# only this user's git configuration resolves (insteadOf, as credentials
# would be): its blobs must be fetched while that configuration applies, not
# later by replays that run without it (CodeRabbit review of #277).
# The served template must not be shallow, as a real one is not: T is a clone
# of this (often shallow) checkout, and git cannot serve a shallow partial
# clone onward. TN is T's tree as a root commit.
TN="$work/template-full"
g init -q -b main "$TN"
(cd "$T" && git ls-files -z | tar --null -T - -cf -) | (cd "$TN" && tar xf -)
g -C "$TN" add -f -A; g -C "$TN" commit -q -m "template under test (unshallow)"
[ "$(g -C "$TN" rev-parse 'HEAD^{tree}')" = "$(g -C "$T" rev-parse "$T_COMMIT^{tree}")" ] \
    && [ "$(g -C "$TN" rev-parse --is-shallow-repository)" = false ] || fail 'fixture: the unshallow template is not the template under test'
g -C "$TN" config uploadpack.allowFilter true
g -C "$TN" config uploadpack.allowAnySHA1InWant true
PR="$work/parent-renamed"
use_template "$TN" HEAD "$PR" git@github.com:elder-owner/elder-proj.git
MINT_TEMPLATE_URL="$TN" mint "$PR" "$work/parent-renamed.log" elder-proj elder-owner "Eldra Author" elder@example.org "Elder tools" \
    || { tail -30 "$work/parent-renamed.log" >&2; fail 'the unshallow parent mint failed'; }
g -C "$PR" add -A; g -C "$PR" commit -q -m mint
g -C "$PR" mv elder-proj_chora.deed elder-renamed_chora.deed
g -C "$PR" commit -q -m "the parent renames its deed"
GR="$work/grandchild-renamed"
use_template "$PR" HEAD "$GR" git@github.com:other-owner/grand-check.git
MINT_TEMPLATE_URL="https://template.invalid/rsr-template-repo.git" \
MINT_GITCONFIG="[url \"file://$TN\"]
	insteadOf = https://template.invalid/rsr-template-repo.git
" mint "$GR" "$work/renamed.log" grand-check other-owner "Other Author" other@example.org "Grand tools" \
    || { tail -40 "$work/renamed.log" >&2; fail 'a chain mint from a parent that renamed its deed, through a private-style URL, failed'; }
[ -f "$GR/grand-check_chora.deed" ] && [ ! -e "$GR/elder-renamed_chora.deed" ] && [ ! -e "$GR/elder-proj_chora.deed" ] \
    || { ls "$GR"/*_chora.deed >&2; fail 'the grandchild does not hold exactly its own deed'; }
g -C "$GR" add -A; g -C "$GR" commit -q -m "chain mint"
(cd "$GR" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$TN") > "$work/renameddrift.log" 2>&1 \
    || { cat "$work/renameddrift.log" >&2; fail 'the grandchild of a parent that renamed its deed has a red drift gate'; }
pass "a parent's renamed deed is identity, not carried; a private-style template URL is read under the user's configuration; drift gate green"

# ── Negative control: a carried generator that edits the deed ───────────────
# The deed is owned, so the measurement skips it: an edit there would reach
# the result unseen (Codex review of #277). Refused before anything is written.
PD="$work/parent-deededit"
g clone -q --no-local "$P" "$PD"
sed -i 's|^set -euo pipefail$|&\nsed -i "s/:description \\"/:description \\"edited /" "$(git rev-parse --show-toplevel)"/*_chora.deed|' "$PD/.machine_readable/arrival-pack/generate.sh"
grep -q ':description' "$PD/.machine_readable/arrival-pack/generate.sh" || fail 'fixture: the deed-editing generator was not added'
g -C "$PD" commit -q -am "a generator that edits the deed"
GD="$work/grandchild-deededit"
use_template "$PD" HEAD "$GD" git@github.com:other-owner/grand-check.git
if mint "$GD" "$work/deededit.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint kept a deed its carried generator edited'
fi
grep -q 'a carried generator edited grand-check_chora.deed' "$work/deededit.log" \
    || { tail -20 "$work/deededit.log" >&2; fail 'the deed edit was not refused by name'; }
[ -z "$(g -C "$GD" status --porcelain)" ] || fail 'the refused chain mint wrote to the tree'
pass "(-) a carried generator that edits the deed is refused before anything is written"

# ── Negative control: a minted parent without the chain script ──────────────
# Its deed records (mint-answers), so it is minted, whatever else it holds (it
# also carries build/templates/identity.deed.in): never minted as a template,
# which would keep its author and contacts (Codex review of #277).
PL="$work/parent-nochain"
g clone -q --no-local "$P" "$PL"
g -C "$PL" rm -q scripts/chain-mint.sh; g -C "$PL" commit -q -m "drop the chain script"
[ -f "$PL/build/templates/identity.deed.in" ] || fail 'fixture: the parent does not carry identity.deed.in'
GL2="$work/grandchild-nochain"
use_template "$PL" HEAD "$GL2" git@github.com:other-owner/grand-check.git
if mint "$GL2" "$work/nochain.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a minted repo without scripts/chain-mint.sh was minted'
fi
grep -q 'scripts/chain-mint.sh, which mints a minted repo again, is absent' "$work/nochain.log" \
    || { tail -20 "$work/nochain.log" >&2; fail 'the missing chain script was not refused by name'; }
[ -z "$(g -C "$GL2" status --porcelain)" ] || fail 'the refused mint wrote to the tree'
pass "(-) a minted repo without the chain script is refused, not minted as a template"

echo "PASS: chain mint"
