#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# use_template_mint_test.sh — mint a repository created the way GitHub's
# "Use this template" button creates one, and check what the mint wrote.
#
# Why. On 2026-10-14 metadatastician/lintel was created with that button (one
# root commit whose tree equals rsr-template-repo c9bce25, none of its history)
# and minted in place with RSR_NON_INTERACTIVE=1 just repo-init. Every defect
# below needed a hand correction there, and no test had ever run a full mint:
# tests/e2e/template_instantiation_test.sh runs nowhere in CI, and it mints an
# uncommitted copy, which is not how real children are born.
#
#   (a) provenance named the CHILD's own HEAD as the template commit;
#   (b) the self-name and strip passes rewrote template-machinery tests, and
#       tests/workflows/self_name_pass_test.sh then failed in the child;
#   (c) the strip pass edited git-ignored sibling checkouts under _build/;
#   (d) the closing advice armed a drift gate that a fresh mint cannot pass;
#   plus a repository map generated from the stale index (Estate Rules red).
#
# This test drives the REAL recipe end to end, then asserts each property,
# with a negative control beside each new check so it cannot pass vacuously.
# It needs just, rustc, uuidgen, nickel and file, and fails (never skips)
# without them. Network-free: the template's history is read from a local
# snapshot via RSR_TEMPLATE_URL.
#
# Usage: bash tests/e2e/use_template_mint_test.sh [--keep]
set -euo pipefail
repo=$(git rev-parse --show-toplevel)

# This test mints the TEMPLATE. A minted child has no archetypes/ (the mint
# removes it) and no unfilled tokens to answer, so there is nothing to mint.
# Same guard as tests/e2e/template_instantiation_test.sh.
if [ ! -d "$repo/archetypes" ]; then
    echo "Self-skipping: archetypes/ not found (repo is already instantiated)."
    exit 0
fi

work=$(mktemp -d)
if [ "${1:-}" = "--keep" ]; then echo "keeping $work"; else trap 'rm -rf "$work"' EXIT; fi

fail() {
    echo "FAIL: $*" >&2
    # One annotation per failure, so the reason reaches the check list and the
    # API and not only the raw log.
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        printf '::error title=use-this-template mint::%s\n' "$(printf '%s' "$*" | tr '\n' ' ')"
    fi
    exit 1
}
pass() { echo "PASS: $*"; }
g() { git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false "$@"; }

for tool in just rustc uuidgen nickel file; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "$tool is required to run a real mint (not skipping: a skipped mint test is how this went untested)"
done

# The four tests the lintel mint broke or rewrote.
FIXTURE_TESTS=(
    tests/workflows/self_name_pass_test.sh
    tests/workflows/template_conformance_test.sh
    tests/e2e/template_instantiation_test.sh
    tests/workflows/mint_cleanup_test.sh
)

# ── 1. The template: this checkout's tree, committed or not, on main ────────
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
T_TREE=$(g -C "$T" rev-parse 'HEAD^{tree}')
T_OWNER=$(sed -n -E 's/^OWNER[[:space:]]*:=[[:space:]]*"([^"]+)".*/\1/p' "$T/Justfile" | head -1)
TEMPLATE_REPO=$(sed -n -E 's/^REPO[[:space:]]*:=[[:space:]]*"([^"]+)".*/\1/p' "$T/Justfile" | head -1)
T_SLUG="$T_OWNER/$TEMPLATE_REPO"

# materialize COMMIT DIR — COMMIT's tree written into DIR as a checkout writes
# it. Not git archive: "Use this template" copies the tree, and archive drops
# export-ignore paths and expands export-subst (Codex review of #275).
materialize() {
    GIT_INDEX_FILE="$work/materialize.index" g -C "$T" read-tree "$1"
    GIT_INDEX_FILE="$work/materialize.index" g -C "$T" checkout-index -a -f --prefix="$2/"
    rm -f "$work/materialize.index"
}
# use_template DIR — what "Use this template" creates: one root commit with
# the template's tree, no shared history, origin = the new repository.
use_template() {
    rm -rf "$1"; mkdir -p "$1"
    materialize "$T_COMMIT" "$1"
    g -C "$1" init -q -b main
    # -f: a template copy keeps every tracked file, ignore rules or not.
    g -C "$1" add -f -A
    g -C "$1" commit -q -m "Initial commit"
    g -C "$1" remote add origin git@github.com:example-owner/mint-check.git
}

# The description carries `&` and `|`, which the substitution used to read as
# sed syntax (`&` inserted the token itself). MINT_ENV adds per-call settings.
DESC='Tools & proofs | checked'
MINT_ENV=()
MINT_ARCH=""

# mint DIR LOG — the non-interactive mint, isolated from this host's defaults
# file and global git config (an ORCID or signing key there would leak in).
mint() {
    # The user's global excludesFile ignores *.mine-local (CodeRabbit review of #275).
    local cfg="$work/cfg"; mkdir -p "$cfg"; printf '*.mine-local\n' > "$work/global-excludes"
    printf '[core]\n\texcludesFile = %s\n' "$work/global-excludes" > "$cfg/gitconfig"
    (cd "$1" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        ${RUSTUP_HOME:+RUSTUP_HOME="$RUSTUP_HOME"} ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} \
        XDG_CONFIG_HOME="$cfg" GIT_CONFIG_GLOBAL="$cfg/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        RSR_NON_INTERACTIVE=1 RSR_TEMPLATE_URL="$T" RSR_MINT_TOOL_CACHE="$work/tools" \
        PROJECT_NAME="Mint Check" REPO=mint-check OWNER=example-owner \
        AUTHOR="Example Author" AUTHOR_EMAIL=author@example.org PROJECT_DESCRIPTION="$DESC" \
        "${MINT_ENV[@]}" timeout 900 just repo-init ${MINT_ARCH:+"$MINT_ARCH"} </dev/null) > "$2" 2>&1
}

# ── 2. The child, with an ignored cache and an untracked probe ──────────────
C="$work/child"
use_template "$C"
[ "$(g -C "$C" rev-parse 'HEAD^{tree}')" = "$T_TREE" ] || fail 'fixture: the child tree is not the template tree'
C_HEAD=$(g -C "$C" rev-parse HEAD)
# The probe carries all three things the rewrite passes act on.
LB='{{'; RB='}}'
probe="<!-- TEMPLATE INSTRUCTIONS: delete this block -->
${TEMPLATE_REPO} by ${LB}OWNER${RB}"
# An ignored sibling checkout, like lintel's _build/dependencies/<sibling>/.
mkdir -p "$C/_build/dependencies/sibling"
printf '%s\n' "$probe" > "$C/_build/dependencies/sibling/README.md"
g -C "$C" check-ignore -q _build/dependencies/sibling/README.md || fail 'fixture: _build/ is not ignored'
# Positive twin of the ignored cache: the same content in an untracked,
# not-ignored file IS the repository's and must be rewritten. Without it, an
# untouched cache could mean "the passes never ran" rather than "scoped".
printf '%s\n' "$probe" > "$C/mint-probe.md"
# A pre-mint edit to a template file: the replay starts from the pinned tree,
# so the mint must declare this as the child's own (Codex review of #275).
printf '\nA local support note, written before the mint.\n' >> "$C/SUPPORT.adoc"
# A pre-mint edit to an INPUT of the mint: the docs seed it renders into
# docs/usage.adoc, then deletes. Only a replay sees what that changes (CodeRabbit
# review of #275).
printf '\nA local usage note, added to the seed before the mint.\n' >> "$C/build/docs-seed/usage.adoc"
# A file only the user's global excludesFile ignores: git add -A never commits
# it, so the mint must not declare it (CodeRabbit review of #275).
printf 'mine\n' > "$C/notes.mine-local"
ignored_list() { (cd "$C" && git ls-files -o -i --exclude-standard | LC_ALL=C sort); }
IGN_LIST=$(ignored_list)
IGN_BEFORE=$(cd "$C" && printf '%s\n' "$IGN_LIST" | xargs -d '\n' sha256sum)
[ -n "$IGN_LIST" ] || fail 'fixture: no ignored files to protect'

# ── 3. Negative control for (a): an unrecognisable tree aborts, untouched ───
N="$work/no-match"
use_template "$N"
printf 'edited before minting\n' >> "$N/README.adoc"
g -C "$N" commit -q --amend -am "Initial commit"
if mint "$N" "$work/no-match.log"; then fail 'a tree matching no template commit was minted'; fi
grep -q 'mint aborted before writing anything' "$work/no-match.log" \
    || { cat "$work/no-match.log" >&2; fail 'the no-match abort did not say why'; }
[ -z "$(g -C "$N" status --porcelain)" ] || fail 'the aborted mint wrote to the tree'
pass "(a-) a child whose tree matches no template commit aborts before writing"

# ── 4. Negative control for the manifest: a stale entry aborts, untouched ───
M="$work/stale"
use_template "$M"
printf 'tests/workflows/no_such_test.sh\n' >> "$M/.machine_readable/mint-verbatim.txt"
g -C "$M" commit -q --amend -am "Initial commit"
if mint "$M" "$work/stale.log"; then fail 'a stale mint-verbatim entry was accepted'; fi
grep -q 'stale entry' "$work/stale.log" || { cat "$work/stale.log" >&2; fail 'the stale-entry abort did not say why'; }
[ -z "$(g -C "$M" status --porcelain)" ] || fail 'the stale-manifest mint wrote to the tree'
pass "(b-) a stale mint-verbatim entry stops the mint before it writes"

# ── 4b. Control: a Justfile identity repo-init cannot read, no guess from origin
# The remote of a template-created child is the CHILD; falling back to it
# named the child as its own template (Codex review of #251).
J="$work/no-identity"
use_template "$J"
sed -i -E 's/^(OWNER|REPO)([[:space:]]*:=[[:space:]]*)"([^"]+)"/\1\2env("RSR_\1", "\3")/' "$J/Justfile"
grep -qE '^OWNER[[:space:]]*:=[[:space:]]*env\(' "$J/Justfile" || fail 'fixture: the OWNER declaration was not rewritten'
g -C "$J" commit -q --amend -am "Initial commit"
if mint "$J" "$work/no-identity.log"; then fail 'a Justfile without OWNER/REPO minted from a guessed template'; fi
grep -q 'RSR_TEMPLATE_SLUG' "$work/no-identity.log" \
    || { cat "$work/no-identity.log" >&2; fail 'the missing-identity abort did not say how to fix it'; }
[ -z "$(g -C "$J" status --porcelain)" ] || fail 'the missing-identity mint wrote to the tree'
pass "(a-) a Justfile identity repo-init cannot read stops the mint and names RSR_TEMPLATE_SLUG"

# ── 4c. Control: an answer with a newline is refused before the first write ─
# (Codex review of #274: the refusal used to come after the overlay, the
# prune and the docs seed had already written.)
NL="$work/newline"
use_template "$NL"
MINT_ENV=(PROJECT_DESCRIPTION=$'line one\nline two')
if mint "$NL" "$work/newline.log"; then fail 'an answer with a newline was accepted'; fi
MINT_ENV=()
grep -q 'contains a newline' "$work/newline.log" || { cat "$work/newline.log" >&2; fail 'the newline refusal did not say why'; }
[ -z "$(g -C "$NL" status --porcelain)" ] || { g -C "$NL" status --short | head >&2; fail 'the refused mint wrote to the tree'; }
pass "(a-) an answer containing a newline is refused before anything is written"
# Byte 0x01 is the deed reader's record separator: an answer holding it was
# rendered everywhere and then could not be recorded (Codex review of #275).
SOH="$work/sohanswer"
use_template "$SOH"
MINT_ENV=(PROJECT_DESCRIPTION=$'one\001two')
if mint "$SOH" "$work/sohanswer.log"; then fail 'an answer holding byte 0x01 was accepted'; fi
MINT_ENV=()
grep -q 'contains byte 0x01' "$work/sohanswer.log" || { cat "$work/sohanswer.log" >&2; fail 'the 0x01 refusal did not say why'; }
[ -z "$(g -C "$SOH" status --porcelain)" ] || { g -C "$SOH" status --short | head >&2; fail 'the refused mint wrote to the tree'; }
pass "(a-) an answer holding byte 0x01 is refused before anything is written"

# ── 4d. Control: an asserted pin whose tree this child does not hold ────────
# The difference cannot be listed, so it cannot be declared: refused before
# writing (Codex review of #275), not minted into certain drift.
# The asserted commit is built here, on a side branch of the template, so the
# test does not depend on how much history the checkout has (CI clones shallow).
OLDTREE=$(cd "$T" && GIT_INDEX_FILE="$work/old.index" git read-tree "$T_TREE" \
    && GIT_INDEX_FILE="$work/old.index" git rm -q --cached SUPPORT.adoc \
    && GIT_INDEX_FILE="$work/old.index" git write-tree)
OLD=$(g -C "$T" commit-tree "$OLDTREE" -p "$T_COMMIT" -m "another template tree")
g -C "$T" branch -q another-tree "$OLD"
[ -n "$OLD" ] && [ "$OLDTREE" != "$T_TREE" ] || fail 'fixture: could not build another template tree'
AS="$work/asserted"
use_template "$AS"
MINT_ENV=(RSR_TEMPLATE_COMMIT="$OLD")
if mint "$AS" "$work/asserted.log"; then fail 'a mint against an asserted tree it cannot compare went ahead'; fi
MINT_ENV=()
grep -q 'which this repository does not hold' "$work/asserted.log" || { tail -20 "$work/asserted.log" >&2; fail 'the uncomparable asserted pin was not refused by name'; }
[ -z "$(g -C "$AS" status --porcelain)" ] || fail 'the refused mint wrote to the tree'
pass "(a-) an asserted template tree this child does not hold, and differs from, is refused before writing"

# ── 4e. Control: a pre-mint change the mint would move is refused ───────────
# The mint moves a root .well-known/ into www/.well-known/, so such a path
# could not be declared where it ends up (Codex review of #275).
WK="$work/wellknown"
use_template "$WK"
mkdir -p "$WK/.well-known"; printf 'local\n' > "$WK/.well-known/local.txt"
wk_before=$(g -C "$WK" status --porcelain --untracked-files=all)
if mint "$WK" "$work/wellknown.log"; then fail 'a pre-mint change under .well-known/ was minted'; fi
grep -q 'the mint moves .well-known/ into www/.well-known/' "$work/wellknown.log" || { tail -20 "$work/wellknown.log" >&2; fail 'the .well-known refusal did not say why'; }
[ "$(g -C "$WK" status --porcelain --untracked-files=all)" = "$wk_before" ] || fail 'the refused mint wrote to the tree'
pass "(a-) a pre-mint change under .well-known/, which the mint moves, is refused before writing"

# ── 4f. Control: a pre-mint file at a path the mint itself writes ───────────
# The docs seed writes docs/usage.adoc; a local file there would be
# overwritten, then declared as the child's own (Codex review of #275).
DS="$work/docsseed"
use_template "$DS"
mkdir -p "$DS/docs"; printf 'my own usage notes\n' > "$DS/docs/usage.adoc"
ds_before=$(g -C "$DS" status --porcelain --untracked-files=all)
if mint "$DS" "$work/docsseed.log"; then fail 'a pre-mint file at a path the mint writes was minted over'; fi
grep -q 'the mint writes that path itself' "$work/docsseed.log" && grep -q 'docs/usage.adoc' "$work/docsseed.log" \
    || { tail -20 "$work/docsseed.log" >&2; fail 'the overwrite refusal did not name the file'; }
[ "$(cat "$DS/docs/usage.adoc")" = 'my own usage notes' ] && [ "$(g -C "$DS" status --porcelain --untracked-files=all)" = "$ds_before" ] \
    || fail 'the refused mint wrote to the tree'
pass "(a-) a pre-mint file at a path the mint writes (the docs seed) is refused before writing"
# The same for an edited template file the overlay replaces: julia-library's
# overlay writes .machine_readable/descriptiles/provisioning_praxis.deed
# (Codex review of #275).
JO="$work/juliaoverlay"
use_template "$JO"
printf '; edited before the mint\n' >> "$JO/.machine_readable/descriptiles/provisioning_praxis.deed"
jo_before=$(g -C "$JO" status --porcelain --untracked-files=all)
MINT_ARCH=julia-library
if mint "$JO" "$work/juliaoverlay.log"; then fail 'an edited file the overlay replaces was minted over'; fi
MINT_ARCH=""
grep -q 'provisioning_praxis.deed changed before the mint' "$work/juliaoverlay.log" \
    || { tail -20 "$work/juliaoverlay.log" >&2; fail 'the overlay overwrite was not refused by name'; }
[ "$(g -C "$JO" status --porcelain --untracked-files=all)" = "$jo_before" ] || fail 'the refused mint wrote to the tree'
pass "(a-) an edited template file the archetype overlay replaces is refused before writing"
# And for any file the mint regenerates whole, whatever writes it: a dry run
# of the mint on this tree finds the edit has no effect (Codex review of #275:
# the roadmap is copied over, mise.toml rendered from the languages). Edits the
# mint keeps are not refused: README.adoc is rendered, and a CLAUDE.md note
# outside the arrival pack's markers is preserved by its generator.
RM="$work/roadmap"
use_template "$RM"
printf '\nmy own milestone\n' >> "$RM/docs/status/ROADMAP.adoc"
printf '\nmy own agent note\n' >> "$RM/CLAUDE.md"
printf '\n# my own tool pin\n' >> "$RM/mise.toml"
printf '\nA README note of my own.\n' >> "$RM/README.adoc"
rm_before=$(g -C "$RM" status --porcelain --untracked-files=all)
if mint "$RM" "$work/roadmap.log"; then fail 'an edit to a file the mint regenerates was minted over'; fi
grep -q 'the change would be discarded' "$work/roadmap.log" && grep -qx '         docs/status/ROADMAP.adoc' "$work/roadmap.log" \
    && grep -qx '         mise.toml' "$work/roadmap.log" \
    && ! grep -qx '         README.adoc' "$work/roadmap.log" && ! grep -qx '         CLAUDE.md' "$work/roadmap.log" \
    || { tail -20 "$work/roadmap.log" >&2; fail 'the discarded edits were not refused by name (and only they)'; }
[ "$(g -C "$RM" status --porcelain --untracked-files=all)" = "$rm_before" ] || fail 'the refused mint wrote to the tree'
pass "(a-) an edit the mint would discard (a regenerated file) is refused by name before writing"
# And a change gone from both results: an input the mint never copies (the
# seed's own README), a file in a directory it deletes. Each is checked by
# minting without it; one with an effect (a seed file it copies) is not
# refused (Codex review of #275).
LO="$work/lostinput"
use_template "$LO"
printf '\nmy own seed note\n' >> "$LO/build/docs-seed/README.adoc"
printf 'local\n' > "$LO/archetypes/premint-local.txt"
printf '\nA usage note of my own.\n' >> "$LO/build/docs-seed/usage.adoc"
lo_before=$(g -C "$LO" status --porcelain --untracked-files=all)
if mint "$LO" "$work/lostinput.log"; then fail 'pre-mint changes the mint destroys were minted over'; fi
grep -qx '         build/docs-seed/README.adoc' "$work/lostinput.log" && grep -qx '         archetypes/premint-local.txt' "$work/lostinput.log" \
    && ! grep -qx '         build/docs-seed/usage.adoc' "$work/lostinput.log" \
    || { tail -20 "$work/lostinput.log" >&2; fail 'the destroyed changes were not refused by name (and only they)'; }
[ "$(g -C "$LO" status --porcelain --untracked-files=all)" = "$lo_before" ] || fail 'the refused mint wrote to the tree'
pass "(a-) a pre-mint change the mint would destroy without effect is refused by name before writing"
# A pre-mint path holding byte 0x01 (the deed reader's record separator) or a
# newline cannot be declared: refused by name (Codex review of #277).
SO="$work/sohpath"
use_template "$SO"
printf 'x\n' > "$SO/notes-soh"$'\001'"name.txt"
so_before=$(g -C "$SO" status --porcelain --untracked-files=all)
if mint "$SO" "$work/sohpath.log"; then fail 'a pre-mint path holding byte 0x01 was minted'; fi
grep -q 'a path holding a newline or byte 0x01 cannot be declared' "$work/sohpath.log" \
    || { tail -20 "$work/sohpath.log" >&2; fail 'the 0x01 path was not refused by name'; }
[ "$(g -C "$SO" status --porcelain --untracked-files=all)" = "$so_before" ] || fail 'the refused mint wrote to the tree'
pass "(a-) a pre-mint path holding byte 0x01 is refused before writing"
# A git location naming ANOTHER repository cannot just be cleared: the mint
# would then act on a different repository than the caller named. Refused.
GD="$work/other-gitdir"
use_template "$GD"
gd_before=$(g -C "$GD" status --porcelain --untracked-files=all); gd_head=$(g -C "$T" rev-parse HEAD)
MINT_ENV=(GIT_DIR="$T/.git")
if mint "$GD" "$work/othergd.log"; then fail 'a mint ran with GIT_DIR naming another repository'; fi
MINT_ENV=()
grep -q 'name a repository other than this work tree' "$work/othergd.log" \
    || { tail -20 "$work/othergd.log" >&2; fail 'a foreign GIT_DIR was not refused by name'; }
[ "$(g -C "$GD" status --porcelain --untracked-files=all)" = "$gd_before" ] && [ "$(g -C "$T" rev-parse HEAD)" = "$gd_head" ] \
    || fail 'the refused mint wrote to a tree'
pass "(a-) a git location naming another repository is refused before anything is written"

# ── 5. The mint ─────────────────────────────────────────────────────────────
# The project type is an answer no template file renders: (mint-answers)
# must not record it (Codex review of #275), and the replay must still be green.
# GIT_DIR inherited, as a hook or another git caller leaves it, naming this
# child: the replay the pre-mint changes need must not commit into it
# (CodeRabbit review of #275).
C_HEAD=$(g -C "$C" rev-parse HEAD); C_COUNT=$(g -C "$C" rev-list --count HEAD)
# The project type is a value found only in archetypes/julia-library/
# actions.lock, which this mint (no archetype) deletes: it must not count as
# written into the child (CodeRabbit review of #275). Chosen here, not written
# into this test, which the child keeps.
UNRENDERED=""
for w in $(tr -cs '0-9' '\n' < "$C/archetypes/julia-library/actions.lock" | awk 'length($0) >= 8' | sort -u); do
    if [ "$(g -C "$C" grep -l -F "$w" | tr '\n' ' ')" = 'archetypes/julia-library/actions.lock ' ]; then UNRENDERED=$w; break; fi
done
[ -n "$UNRENDERED" ] || fail 'fixture: no value is found only in archetypes/julia-library/actions.lock'
MINT_ENV=(PROJECT_TYPE="$UNRENDERED" GIT_DIR="$C/.git")
mint "$C" "$work/mint.log" || {
    cat "$work/mint.log" >&2
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        printf '::error title=just repo-init failed::%s\n' \
            "$(tail -n 40 "$work/mint.log" | awk '{printf "%s%%0A", $0}')"
    fi
    fail 'just repo-init failed on a Use-this-template child'
}
MINT_ENV=()
[ "$(g -C "$C" rev-parse HEAD)" = "$C_HEAD" ] && [ "$(g -C "$C" rev-list --count HEAD)" = "$C_COUNT" ] \
    || { g -C "$C" log --oneline -3 >&2; fail 'the replay committed into the child through an inherited GIT_DIR'; }
pass "the non-interactive mint completes on a Use-this-template child"
DEED="$C/mint-check_chora.deed"
[ -f "$DEED" ] || fail 'the child deed was not renamed to mint-check_chora.deed'
field() { bash "$C/scripts/deed-field.sh" "$DEED" "$@"; }

# ── (a) provenance names the template's commit and tree ─────────────────────
[ "$(field provenance template-repo)" = "$T_SLUG" ]     || fail "template-repo is $(field provenance template-repo), want $T_SLUG"
[ "$(field provenance template-commit)" = "$T_COMMIT" ] || fail "template-commit is $(field provenance template-commit), want $T_COMMIT"
[ "$(field provenance template-tree)" = "$T_TREE" ]     || fail "template-tree is $(field provenance template-tree), want $T_TREE"
[ "$(field provenance template-branch)" = main ]        || fail "template-branch is $(field provenance template-branch), want main"
[ "$(field variant parent-pin)" = "$T_COMMIT" ]         || fail "variant parent-pin is $(field variant parent-pin), want $T_COMMIT"
if grep -qF "$C_HEAD" "$DEED"; then fail "the deed records the child's own commit $C_HEAD"; fi
pass "(a) provenance and variant name template commit ${T_COMMIT:0:12} and its tree, never the child's HEAD"
grep -qF -- "$DESC" "$C/README.adoc" \
    || { grep -n 'Tools' "$C/README.adoc" >&2; fail 'the description did not render literally'; }
pass "an answer containing & and | renders literally"

# ── (b) the fixture tests are carried unchanged, and pass in the child ──────
while IFS= read -r v; do
    g -C "$C" diff --quiet HEAD -- "$v" || fail "the mint modified $v, listed in mint-verbatim.txt"
done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$C/.machine_readable/mint-verbatim.txt" | grep -v '^$')
for t in "${FIXTURE_TESTS[@]}"; do
    g -C "$C" diff --quiet HEAD -- "$t" || fail "the mint modified $t"
    (cd "$C" && RSR_MINT_TOOL_CACHE="$work/tools" bash "$t") > "$work/fixture.log" 2>&1 \
        || { cat "$work/fixture.log" >&2; fail "$t fails in the minted child"; }
done
pass "(b) the four template-machinery tests are byte-identical and pass in the child"

# ── (c) nothing outside the repository's own files changed ──────────────────
[ "$(cd "$C" && printf '%s\n' "$IGN_LIST" | xargs -d '\n' sha256sum)" = "$IGN_BEFORE" ] \
    || fail 'the mint changed git-ignored files'
# The one ignored file the mint may CREATE is the arrival pack's declared
# build artefact (.gitignore, arrival-pack/README.adoc), which `just claude-md`
# writes on every run. Any other new ignored file is a write outside the repo.
new_ignored=$(comm -13 <(printf '%s\n' "$IGN_LIST") <(ignored_list) \
    | grep -vxF .machine_readable/arrival-pack/claude-md-data.json || true)
[ -z "$new_ignored" ] || { echo "$new_ignored" >&2; fail 'the mint created files outside the repository'; }
if grep -q 'TEMPLATE INSTRUCTIONS' "$C/mint-probe.md"; then fail 'probe: the strip pass skipped a repository file'; fi
if grep -qF "$TEMPLATE_REPO" "$C/mint-probe.md"; then fail 'probe: the self-name pass skipped a repository file'; fi
if grep -qF "${LB}OWNER${RB}" "$C/mint-probe.md"; then fail 'probe: the substitution pass skipped a repository file'; fi
# The probe stays: it was a repository file at mint, so the map lists it.
pass "(c) ignored files are byte-identical, none created but the arrival-pack artefact; the same content in a repository file was rewritten"

# ── (d) the drift gate replays the mint, and a fresh mint is green ──────────
grep -q 'arm the drift gate' "$work/mint.log" || fail 'repo-init does not recommend arming the drift gate'
grep -q 'scripts/check-template-conformance.sh' "$work/mint.log" || fail 'repo-init does not point at the conformance check'
# The answers are recorded, verbatim (the description carries & and |).
[ "$(field mint-answers description)" = "$DESC" ] || fail "(mint-answers :description) is '$(field mint-answers description)'"
[ "$(field mint-answers repo)" = mint-check ] && [ -n "$(field mint-answers mint-date)" ] \
    || fail '(mint-answers) lacks the repo or the mint date'
# Only values already written into the child are recorded (owner ruling).
if grep -q "$UNRENDERED\|:project-type" "$DEED"; then fail '(mint-answers) recorded an answer that no file renders'; fi
grep -q 'not recorded, written into no file here: project-type' "$work/mint.log" || fail 'the mint did not name the unrecorded answer'
# What the work tree held beyond the pinned tree before the mint (the probe,
# untracked; the SUPPORT.adoc edit) is the child's own: named, and declared
# (Codex review of #275), so the replay from the pin stays exact.
grep -q '^      :added ("mint-probe.md")' "$DEED" || { grep -n ':added' "$DEED" >&2; fail 'the pre-mint addition was not declared added'; }
bash "$C/scripts/deed-field.sh" --list "$DEED" variant/paths diverged | grep -qx SUPPORT.adoc \
    || { grep -n ':diverged' "$DEED" >&2; fail 'the pre-mint edit was not declared diverged'; }
grep -q 'already differ from the template tree' "$work/mint.log" && grep -q '^        SUPPORT.adoc$' "$work/mint.log" \
    || fail 'the mint did not name the pre-mint changes'
bash "$C/scripts/deed-field.sh" --list "$DEED" variant/paths diverged | grep -qx docs/usage.adoc \
    && grep -q 'A local usage note' "$C/docs/usage.adoc" \
    || { grep -n ':diverged' "$DEED" >&2; fail 'a pre-mint edit to the docs seed was not declared where it lands'; }
if grep -q 'notes.mine-local' "$DEED"; then fail 'a file only a global excludesFile ignores was declared'; fi
mv "$C/notes.mine-local" "$work/notes.mine-local"   # this test's own git does not ignore it
g -C "$C" add -A
g -C "$C" commit -q -m "mint"
# Chain minting now supports children with recorded answers (owner ruling
# 2026-11-04; tests/e2e/chain_mint_test.sh). The refusal applies to legacy
# children without those replay inputs. Keep the fresh child intact for the
# conformance and drift checks below, and construct that legacy case explicitly.
LEGACY="$work/legacy-child"
cp -a "$C" "$LEGACY"
bash "$LEGACY/scripts/deed-clause.sh" replace "$LEGACY/$(basename "$DEED")" mint-answers /dev/null
if bash "$LEGACY/scripts/deed-field.sh" --has "$LEGACY/$(basename "$DEED")" mint-answers; then
    fail 'legacy fixture still records mint answers'
fi
g -C "$LEGACY" add -A
g -C "$LEGACY" commit -q -m "legacy child without replay inputs"
if mint "$LEGACY" "$work/remint.log"; then fail 'a legacy child without mint answers was minted again'; fi
grep -q 'already been minted' "$work/remint.log" || { cat "$work/remint.log" >&2; fail 'the re-mint refusal did not say why'; }
grep -qF "records its template as ${T_SLUG}" "$work/remint.log" || fail 'the re-mint refusal does not name the template to use'
[ -z "$(g -C "$LEGACY" status --porcelain)" ] || fail 'the refused re-mint wrote to the tree'
pass "(e-) a legacy child without replay inputs stops before writing and names its template"
(cd "$C" && bash scripts/check-template-conformance.sh --quiet) > "$work/conf.log" 2>&1 \
    || { cat "$work/conf.log" >&2; fail 'the conformance check fails on a fresh mint'; }
# A fresh mint is identical to a replay of itself (the design; checked here).
drift() { (cd "$C" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/drift.log" 2>&1; }
drift || { cat "$work/drift.log" >&2; fail 'the drift gate is red on a fresh mint'; }
grep -q 'identical to a replay of the mint' "$work/drift.log" || fail 'the drift gate did not replay the mint'
# The same file, present, under the same global configuration: not this repo's
# file, so not drift (CodeRabbit review of #275).
mv "$work/notes.mine-local" "$C/notes.mine-local"
(cd "$C" && GIT_CONFIG_GLOBAL="$work/cfg/gitconfig" RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/drift.log" 2>&1 \
    || { cat "$work/drift.log" >&2; fail 'the drift gate counts a file the global excludesFile ignores'; }
rm "$C/notes.mine-local"
pass "(d) the drift gate replays the mint from (provenance) and (mint-answers): green on a fresh mint"
# Negative control: an edit to a file the mint produced, and an undeclared
# addition, are each named. Then restored, and green again.
printf '\nedited after the mint\n' >> "$C/README.adoc"
printf 'stray\n' > "$C/stray.txt"
if drift; then fail 'the drift gate missed an edit and an undeclared addition'; fi
grep -q '^DRIFT: README.adoc differs' "$work/drift.log" || { cat "$work/drift.log" >&2; fail 'the edited README.adoc was not named'; }
grep -q '^DRIFT: stray.txt exists here' "$work/drift.log" || fail 'the undeclared stray.txt was not named'
[ "$(grep -c '^DRIFT:' "$work/drift.log")" -eq 2 ] || { cat "$work/drift.log" >&2; fail 'the drift gate reported more than the two changes'; }
g -C "$C" checkout -q -- README.adoc; rm "$C/stray.txt"
pass "(d-) an edited file and an undeclared addition are named; nothing else is"
# Each declaration is a claim the gate checks (Codex review of #275): a
# mode-only change, a file recreated under a declared-removed directory, and a
# declared addition that is gone are each named.
chmod +x "$C/README.adoc"
mkdir -p "$C/archetypes"; printf 'back\n' > "$C/archetypes/revived.txt"
rm "$C/mint-probe.md"
if drift; then fail 'the drift gate missed a mode change, a revived removal and a missing addition'; fi
grep -q '^DRIFT: README.adoc differs .*mode' "$work/drift.log" || { cat "$work/drift.log" >&2; fail 'the mode-only change was not named'; }
grep -q '^DRIFT: archetypes/revived.txt exists here but is declared removed' "$work/drift.log" || fail 'the revived removal was not named'
grep -q '^DRIFT: declared-added mint-probe.md is missing' "$work/drift.log" || fail 'the missing declared addition was not named'
[ "$(grep -c '^DRIFT:' "$work/drift.log")" -eq 3 ] || { cat "$work/drift.log" >&2; fail 'the drift gate reported more than the three changes'; }
chmod -x "$C/README.adoc"; rm -r "$C/archetypes"; g -C "$C" checkout -q -- mint-probe.md
pass "(d-) a mode change, a revived removal and a missing addition are each named"
# git records only the owner's execute bit: group and other execute bits are
# no change to it, so no drift. (`-x` asked about the caller, and as root it
# is true for such a file: this control bites when run as root, as in a
# container.) (Codex review of #275.)
chmod go+x "$C/README.adoc"
[ -z "$(g -C "$C" status --porcelain -- README.adoc)" ] || fail 'fixture: git sees a group/other execute bit as a change'
drift || { cat "$work/drift.log" >&2; fail 'the drift gate named a group/other execute bit git does not record'; }
chmod go-x "$C/README.adoc"
pass "(d) execute bits git does not record (group, other) are not drift, as root too"
# Membership is the repository file set (Codex review of #275): an ignored
# artefact the replay also generates, force-added here, is still an addition.
AP=.machine_readable/arrival-pack/claude-md-data.json
[ -f "$C/$AP" ] || fail "fixture: the mint did not generate $AP"
g -C "$C" add -f -- "$AP"
if drift; then fail 'the drift gate passed a force-added ignored artefact'; fi
grep -qF "DRIFT: $AP exists here but the mint did not produce it" "$work/drift.log" || { cat "$work/drift.log" >&2; fail 'the force-added artefact was not named'; }
[ "$(grep -c '^DRIFT:' "$work/drift.log")" -eq 1 ] || { cat "$work/drift.log" >&2; fail 'the drift gate reported more than the force-added artefact'; }
g -C "$C" rm -q --cached -- "$AP"
drift || { cat "$work/drift.log" >&2; fail 'the drift gate is not green again after the controls'; }
pass "(d-) a force-added ignored artefact the replay also generates is named; green again once untracked"
# The most specific declaration wins (Codex review of #277): a file the child
# adds, and declares added, under archetypes/ (which the mint declares
# removed) is an addition, not a revived removal.
cp "$DEED" "$work/deed.before-specific"
sed -i 's|^      :added ("mint-probe.md")|      :added ("mint-probe.md" "archetypes/custom.txt")|' "$DEED"
grep -q '"archetypes/custom.txt")' "$DEED" || fail 'fixture: could not declare archetypes/custom.txt'
mkdir -p "$C/archetypes"; printf 'mine\n' > "$C/archetypes/custom.txt"
drift || { cat "$work/drift.log" >&2; fail 'a declared addition under a declared-removed directory was flagged'; }
rm -r "$C/archetypes"; cp "$work/deed.before-specific" "$DEED"
pass "(d) a declared addition under a declared-removed directory is an addition: the most specific declaration wins"
# A path declared diverged must be one the mint produces (Codex review of
# #275): a new file declared diverged is an undeclared addition.
cp "$DEED" "$work/deed.before-div"
sed -i 's|^      :diverged ("|      :diverged ("new-thing.txt" "|' "$DEED"
grep -q ':diverged ("new-thing.txt"' "$DEED" || fail 'fixture: could not declare new-thing.txt diverged'
printf 'new\n' > "$C/new-thing.txt"
if drift; then fail 'the drift gate passed a new file declared diverged'; fi
grep -q '^DRIFT: new-thing.txt is declared diverged, but the mint did not produce it' "$work/drift.log" || { cat "$work/drift.log" >&2; fail 'the new file declared diverged was not named'; }
rm "$C/new-thing.txt"; cp "$work/deed.before-div" "$DEED"
pass "(d-) a new file declared diverged is named as an addition"
# The replay's own git runs isolated from this machine's configuration: a
# global pre-commit hook that rejects every commit changes nothing (Codex
# review of #275).
mkdir -p "$work/hooks"; printf '#!/bin/sh\nexit 1\n' > "$work/hooks/pre-commit"; chmod +x "$work/hooks/pre-commit"
# And a global attributes file that drops README.adoc from every archive: the
# replay must not lose it (Codex review of #277).
printf 'README.adoc export-ignore\n' > "$work/global.attributes"
printf '[core]\n\thooksPath = %s\n\tattributesFile = %s\n' "$work/hooks" "$work/global.attributes" > "$work/hooky.gitconfig"
(cd "$C" && GIT_CONFIG_GLOBAL="$work/hooky.gitconfig" RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/drift.log" 2>&1 \
    || { cat "$work/drift.log" >&2; fail 'a global pre-commit hook broke the replay'; }
pass "(d) the replay is isolated from global git hooks and attributes"
# Inherited git location variables (a hook's GIT_DIR, GIT_INDEX_FILE) cannot
# redirect the gate's git (CodeRabbit review of #275).
g init -q "$work/elsewhere"
(cd "$C" && GIT_DIR="$work/elsewhere/.git" GIT_INDEX_FILE="$work/elsewhere/.git/index" \
    RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/drift.log" 2>&1 \
    || { cat "$work/drift.log" >&2; fail 'an inherited GIT_DIR redirected the drift gate'; }
pass "(d) inherited git location variables do not redirect the gate"
# The last path git lists, deleted, is named like any other: it used to fail
# the file listing itself and stop the gate silently (CodeRabbit review of #275).
LAST=$(g -C "$C" ls-files | tail -n 1)
rm -- "$C/$LAST"
if drift; then fail "the drift gate missed the deletion of $LAST"; fi
grep -qF "DRIFT: $LAST was produced by the mint but is absent here" "$work/drift.log" || { cat "$work/drift.log" >&2; fail "the deleted last path $LAST was not named"; }
g -C "$C" checkout -q -- "$LAST"
pass "(d-) the deletion of the last path git lists is named"
# A path the line-based lists cannot hold is refused by name, not misread.
NLF="$C/two"$'\n'"lines.txt"; printf 'x\n' > "$NLF"
if drift; then fail 'the drift gate passed a path containing a newline'; fi
grep -q 'cannot check a path containing a newline' "$work/drift.log" || { cat "$work/drift.log" >&2; fail 'the newline path was not refused by name'; }
rm -- "$NLF"
pass "(d-) a path containing a newline is refused by name"
# A template commit carrying a submodule (a gitlink: no files to copy) cannot
# be replayed exactly: the gate refuses it by name (Codex review of #277).
GL_TREE=$(cd "$T" && GIT_INDEX_FILE="$work/gl.index" git read-tree "$T_TREE" \
    && GIT_INDEX_FILE="$work/gl.index" git update-index --add --cacheinfo "160000,$T_COMMIT,vendor/sub" \
    && GIT_INDEX_FILE="$work/gl.index" git write-tree)
GL_COMMIT=$(g -C "$T" commit-tree "$GL_TREE" -p "$T_COMMIT" -m "a template carrying a submodule")
g -C "$T" branch -q with-gitlink "$GL_COMMIT"
GLC="$work/gitlinkchild"; cp -a "$C" "$GLC"
sed -i -E "s/(:template-commit \")[0-9a-f]{40}\"/\1${GL_COMMIT}\"/" "$GLC/mint-check_chora.deed"
grep -q ":template-commit \"$GL_COMMIT\"" "$GLC/mint-check_chora.deed" || fail 'fixture: the gitlink pin was not written'
rc=0; (cd "$GLC" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-mint-drift.sh "$T") > "$work/gldrift.log" 2>&1 || rc=$?
[ "$rc" -eq 2 ] && grep -q 'carries a submodule' "$work/gldrift.log" && grep -q 'vendor/sub' "$work/gldrift.log" \
    || { cat "$work/gldrift.log" >&2; fail "a template commit carrying a gitlink was not refused by name (exit $rc)"; }
pass "(d-) a template commit carrying a submodule is refused by name, not replayed inexactly"
# …and the mint refuses such a tree itself, clean or not: its drift gate could
# never pass (Codex review of #275).
GLM="$work/gitlinkmint"
rm -rf "$GLM"; mkdir -p "$GLM"; materialize "$GL_COMMIT" "$GLM"
g -C "$GLM" init -q -b main; g -C "$GLM" add -A
g -C "$GLM" update-index --add --cacheinfo "160000,$T_COMMIT,vendor/sub"; g -C "$GLM" commit -q -m "Initial commit"
g -C "$GLM" remote add origin git@github.com:example-owner/mint-check.git
[ "$(g -C "$GLM" rev-parse 'HEAD^{tree}')" = "$GL_TREE" ] || fail 'fixture: the gitlink child is not the gitlink template tree'
MINT_ENV=(RSR_TEMPLATE_COMMIT="$GL_COMMIT")
if mint "$GLM" "$work/glmint.log"; then fail 'a tree carrying a gitlink was minted'; fi
MINT_ENV=()
grep -q 'carries a submodule' "$work/glmint.log" && grep -q 'vendor/sub' "$work/glmint.log" \
    || { tail -20 "$work/glmint.log" >&2; fail 'the gitlink was not refused by name at mint'; }
[ -z "$(g -C "$GLM" status --porcelain)" ] || fail 'the refused mint wrote to the tree'
pass "(a-) a tree carrying a submodule is refused at mint, clean or not"

# ── A template whose identity needs RSR_TEMPLATE_SLUG, replayed ─────────────
# repo-init supports a template whose Justfile names its identity through
# env(...), given RSR_TEMPLATE_SLUG. The drift gate's replay must pass the
# recorded slug on, or it cannot run at all (Codex review of #275). The same
# template marks SUPPORT.adoc export-ignore: the replay must write the tree as
# a checkout does, not as git archive does (Codex review of #275).
SL_TREE=$(cd "$T" && GIT_INDEX_FILE="$work/slug.index" git read-tree "$T_TREE" && cp Justfile "$work/Justfile.slug" \
    && sed -i -E 's/^(OWNER|REPO)([[:space:]]*:=[[:space:]]*)"([^"]+)"/\1\2env("RSR_\1", "\3")/' "$work/Justfile.slug" \
    && GIT_INDEX_FILE="$work/slug.index" git update-index --add --cacheinfo "100644,$(git hash-object -w "$work/Justfile.slug"),Justfile" \
    && { cat .gitattributes; printf 'SUPPORT.adoc export-ignore\n'; } > "$work/gitattributes.slug" \
    && GIT_INDEX_FILE="$work/slug.index" git update-index --add --cacheinfo "100644,$(git hash-object -w "$work/gitattributes.slug"),.gitattributes" \
    && GIT_INDEX_FILE="$work/slug.index" git update-index --add --cacheinfo "100644,$(printf 'forced\n' | git hash-object -w --stdin),_build/forced.txt" \
    && GIT_INDEX_FILE="$work/slug.index" git update-index --add --cacheinfo "120000,$(printf 'README.adoc' | git hash-object -w --stdin),readme-link" \
    && GIT_INDEX_FILE="$work/slug.index" git write-tree)
SL_COMMIT=$(g -C "$T" commit-tree "$SL_TREE" -p "$T_COMMIT" -m "a template naming itself through env()")
g -C "$T" branch -q env-identity "$SL_COMMIT"
SLC="$work/slugchild"
rm -rf "$SLC"; mkdir -p "$SLC"
materialize "$SL_COMMIT" "$SLC"
[ -f "$SLC/SUPPORT.adoc" ] && ! g -C "$T" archive "$SL_COMMIT" | tar t | grep -qx SUPPORT.adoc \
    || fail 'fixture: SUPPORT.adoc is not export-ignored in the second template commit'
# The same template tracks _build/forced.txt although _build/ is ignored, and
# a symlink: "Use this template" copies both, so the replay must keep them
# (Codex and CodeRabbit review of #277).
g -C "$T" check-ignore -q --no-index _build/forced.txt || fail 'fixture: _build/ is not ignored'
g -C "$SLC" init -q -b main; g -C "$SLC" add -f -A; g -C "$SLC" commit -q -m "Initial commit"
[ "$(g -C "$SLC" rev-parse 'HEAD^{tree}')" = "$SL_TREE" ] || fail 'fixture: the env()-identity child is not its template tree'
g -C "$SLC" remote add origin git@github.com:example-owner/mint-check.git
MINT_ENV=(RSR_TEMPLATE_SLUG="$T_SLUG" RSR_TEMPLATE_COMMIT="$SL_COMMIT")
mint "$SLC" "$work/slug.log" || { tail -30 "$work/slug.log" >&2; fail 'the env()-identity template did not mint with RSR_TEMPLATE_SLUG'; }
MINT_ENV=()
g -C "$SLC" add -A; g -C "$SLC" commit -q -m mint
(cd "$SLC" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/slugdrift.log" 2>&1 \
    || { cat "$work/slugdrift.log" >&2; fail 'the drift gate could not replay a template that needs RSR_TEMPLATE_SLUG'; }
pass "(d) a template naming itself through env(), marking a path export-ignore and force-tracking an ignored file is replayed exactly: green"
# A symlink target differing only by a trailing newline is a different blob
# to git, so drift: command substitution strips it (Codex review of #275).
rm "$SLC/readme-link"; ln -s 'README.adoc
' "$SLC/readme-link"
[ -n "$(g -C "$SLC" status --porcelain -- readme-link)" ] || fail 'fixture: git does not see the retargeted link'
if (cd "$SLC" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/slugdrift.log" 2>&1; then
    fail 'the drift gate missed a symlink target changed by a trailing newline'
fi
grep -q '^DRIFT: readme-link differs' "$work/slugdrift.log" || { cat "$work/slugdrift.log" >&2; fail 'the retargeted link was not named'; }
g -C "$SLC" checkout -q -- readme-link
pass "(d-) a symlink retargeted only by a trailing newline is named"
# A checkout that does not read back as its tree (a CRLF blob under eol=lf:
# add normalises it) cannot be replayed exactly, and says so (the replay's
# commit must BE the pinned tree).
CR_TREE=$(cd "$T" && GIT_INDEX_FILE="$work/crlf.index" git read-tree "$T_TREE" \
    && { cat .gitattributes; printf 'crlf.txt text eol=lf\n'; } > "$work/gitattributes.crlf" \
    && GIT_INDEX_FILE="$work/crlf.index" git update-index --add --cacheinfo "100644,$(git hash-object -w "$work/gitattributes.crlf"),.gitattributes" \
    && GIT_INDEX_FILE="$work/crlf.index" git update-index --add --cacheinfo "100644,$(printf 'a\r\n' | git hash-object -w --stdin),crlf.txt" \
    && GIT_INDEX_FILE="$work/crlf.index" git write-tree)
CR_COMMIT=$(g -C "$T" commit-tree "$CR_TREE" -p "$T_COMMIT" -m "a template whose checkout does not read back")
rc=0; bash "$T/scripts/replay-mint.sh" "$T" "$CR_COMMIT" "$work/crreplay" > "$work/crreplay.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] && grep -q 'does not read back as its own tree' "$work/crreplay.log" \
    || { cat "$work/crreplay.log" >&2; fail "a checkout that does not read back was replayed (exit $rc)"; }
pass "(d-) a template commit whose checkout does not read back as its tree is refused, not replayed inexactly"

# ── The repository map is regenerated last ──────────────────────────────────
# Same check Estate Rules runs, on the committed mint: regenerate from the
# index and require no difference.
(cd "$C" && bash scripts/gen-repo-map.sh . >/dev/null)
g -C "$C" diff --quiet -- docs/architecture/REPOSITORY-MAP.adoc \
    || { g -C "$C" diff -- docs/architecture/REPOSITORY-MAP.adoc | head -20 >&2; fail 'the committed map is stale'; }
# Negative control: index mode, run where the mint runs it (before the first
# commit, after a removal), reproduces the stale map lintel shipped.
SM="$work/stale-map"
use_template "$SM"
# Create the control explicitly: minted descendants no longer carry archetypes/.
# The assertion must test index staleness, not assume a template-only directory.
printf 'map staleness control\n' > "$SM/map-staleness-control.txt"
g -C "$SM" add map-staleness-control.txt
rm "$SM/map-staleness-control.txt"
(cd "$SM" && bash scripts/gen-repo-map.sh . >/dev/null)
grep -qF 'map-staleness-control.txt' "$SM/docs/architecture/REPOSITORY-MAP.adoc" \
    || fail 'control: index mode no longer shows the pre-commit staleness; this check is vacuous'
(cd "$SM" && bash scripts/gen-repo-map.sh --worktree . >/dev/null)
if grep -qF 'map-staleness-control.txt' "$SM/docs/architecture/REPOSITORY-MAP.adoc"; then
    fail 'control: worktree mode retained a deleted source'
fi
pass "the committed map is fresh (the index-mode control reproduces lintel's stale map)"

(cd "$C" && env -u GITHUB_REPOSITORY bash scripts/check-no-placeholders.sh .) > "$work/ph.log" 2>&1 \
    || { cat "$work/ph.log" >&2; fail 'the minted child fails its own placeholder gate'; }
pass "the minted child passes its own placeholder gate"

# The mint removes build/docs-seed/; an exemption left for it is stale, and
# the child's Hypatia exemption gate fails on it (seen minting
# unified-api-adapter, 2026-11-05).
[ ! -e "$C/build/docs-seed" ] || fail 'fixture: the mint kept build/docs-seed/; this check is vacuous'
(cd "$C" && bash scripts/check-hypatia-ignore.sh .) > "$work/hi.log" 2>&1 \
    || { cat "$work/hi.log" >&2; fail 'the minted child fails its own Hypatia exemption gate'; }
pass "the minted child passes its own Hypatia exemption gate"
# The rule-order policy must lose the same module, or it classifies an
# exemption that no longer exists.
(cd "$C" && bash scripts/check-hypatia-rule-order.sh .) > "$work/ro.log" 2>&1 \
    || { cat "$work/ro.log" >&2; fail 'the minted child fails its own Hypatia rule-order gate'; }
pass "the minted child passes its own Hypatia rule-order gate"
if command -v bun >/dev/null 2>&1 || command -v ijson-jcs >/dev/null 2>&1; then
    (cd "$C" && bash scripts/check-ijson-jcs.sh --enforce .machine_readable/policies/hypatia-rule-order.json) > "$work/jcs.log" 2>&1 \
        || { cat "$work/jcs.log" >&2; fail 'the minted rule-order policy is not canonical JSON'; }
    pass "the minted rule-order policy stays canonical JSON"
fi

echo "PASS: Use-this-template mint"
