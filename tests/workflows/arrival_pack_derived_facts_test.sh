#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# arrival_pack_derived_facts_test.sh — controls for the facts the CLAUDE.md
# arrival pack (.machine_readable/arrival-pack/) DERIVES instead of asserting.
#
# The pack once said, in every repo, that there are no `.a2ml` files and that
# ANCHOR, AGENTIC, ECOSYSTEM, STATE, NEUROSYM and PLAYBOOK are deed clauses.
# That holds for the template's own tree. It is false in a child that took the
# deed-reading pack while its remaining A2ML is still waiting for conversion:
# the files exist, and its deed lacks (agentic), (neurosym), (playbook) and
# (bot-directives). extract.sh now reports the tracked .a2ml files and the
# clauses the deed has, and arrival-pack.ncl states only what they show.
#
# Each case BUILDS its tree here (git init, a fixture deed, the .a2ml files
# created and `git add`ed in the temporary tree), so this repository never
# tracks an .a2ml file. A second group controls the whole-file parse: extract.sh
# refuses a deed with content after its closing ")", as deed_lint.js does.
#
# Requires nickel, jq and git. Exit: 0 all controls hold; 1 a control failed.

# The expected texts are Markdown with backticks, in single quotes on purpose.
# shellcheck disable=SC2016
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AP="$REPO_DIR/.machine_readable/arrival-pack"
for tool in nickel jq git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool is required" >&2; exit 1; }
done
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); echo "  PASS  $1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); echo "  FAIL  $1"; shift; for l in "$@"; do echo "        $l"; done; }

# ── Fixture deeds ───────────────────────────────────────────────────────────
# write_deed FILE [with-clauses]: a child deed with identity, status, maturity,
# ecosystem and an anchor. With "with-clauses" it also has (meta), (agentic),
# (neurosym), (playbook) and (bot-directives (methodology) (coverage) (debt)).
write_deed() {
    {
        cat <<'EOF'
;; SPDX-License-Identifier: MPL-2.0
(repo-deed
  :schema-version "1.0.0"
  :canonical-name "Fixture.jl"
  :repo-uuid #uuid"11111111-2222-8333-8444-555555555555"
  (identity :primary-forge github :owner "someone" :prefixed-name "x-fixture")
  (lineage :type standalone :parent "" :born "2026-01-01" :previous-names ())
  (forges :github "someone/Fixture.jl")
  (status :phase active :since "2026-01-01" :present #t)
  (maturity :level beta)
  (ecosystem
    :project "Fixture.jl"
    :purpose "A fixture child."
    :not ("a real repo")
    :pipeline-position "leaf"
    :chain "standards → Fixture.jl"
    :coordination standards)
  (anchor
    (golden-path :smoke-test-command ("just test") :success-criteria ("tests pass")))
EOF
        if [[ "${2:-}" == with-clauses ]]; then
            cat <<'EOF'
  (meta :version "0.1.0" :type library)
  (agentic :version "0.1.0" (integrity :fail-closed #t))
  (neurosym :version "0.1.0")
  (playbook :version "0.1.0")
  (bot-directives (methodology :default-mode hybrid) (coverage) (debt))
EOF
        fi
        echo ")"
    } > "$1"
}

# mk_tree NAME [with-clauses] -> a child tree under $WORK with the pack's own
# files (copied from this repo), a fixture deed, and `git init` (no commit).
mk_tree() {
    local t="$WORK/$1"
    mkdir -p "$t/scripts" "$t/.machine_readable"
    cp "$REPO_DIR/scripts/deed-field.sh" "$t/scripts/"
    cp -r "$AP" "$t/.machine_readable/arrival-pack"
    rm -f "$t/.machine_readable/arrival-pack/claude-md-data.json"
    write_deed "$t/fixture_chora.deed" "${2:-}"
    git -C "$t" init -q
    echo "$t"
}

# add_a2ml TREE PATH [track]: create an .a2ml file; track it unless told not to
add_a2ml() {
    mkdir -p "$(dirname "$1/$2")"
    printf '[legacy]\n' > "$1/$2"
    [[ "${3:-track}" == untracked ]] || git -C "$1" add -- "$2"
}

# render TREE -> the arrival-pack region on stdout (extract.sh, then the engine,
# in a copy so the tree's own claude-md-data.json is untouched)
render() {
    local d="$WORK/render.$CHECKS.$RANDOM"
    mkdir -p "$d"
    cp "$AP/arrival-pack.ncl" "$d/"
    bash "$AP/extract.sh" "$1" > "$d/claude-md-data.json" || return 1
    nickel export --format raw "$d/arrival-pack.ncl"
}

# equal LABEL GOT WANT
equal() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want: $3" "got:  $2"; fi; }
# contains LABEL TEXT NEEDLE / lacks LABEL TEXT NEEDLE (fixed strings)
contains() { if grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1" "missing: $3"; fi; }
lacks()    { if grep -qF -- "$3" <<<"$2"; then fail "$1" "must not appear: $3"; else pass "$1"; fi; }

# The wording a repo with every clause and no .a2ml file has always had.
OLD_SUBSTRATE='ANCHOR, AGENTIC, ECOSYSTEM, STATE, NEUROSYM and PLAYBOOK are clauses of the CHORA deed — `(anchor)`, `(agentic)`, `(ecosystem)`, `(status)` and `(maturity)`, `(neurosym)`, `(playbook)` — not files; STATE'"'"'s journal is `docs/status/ROADMAP.adoc`. There are no `.a2ml` files in this estate.'
OLD_CHORA_ROW='`(meta)` the architecture axes; `(agentic)` *may I act now?*; `(ecosystem)` where it sits and what it is not; `(status)` and `(maturity)` where it is now. Read fields'
OLD_NEUROSYM_ROW='| `(neurosym)` | *Meaning* of operations — proof obligations. |'
OLD_PLAYBOOK_ROW='| `(playbook)` | *How* permitted actions run. |'
OLD_CONSTRAINTS='- **Constraints here** (AGENTIC) — fail-closed; evidence-per-step; no-silent-skip; rerun-after-fix; release-claim-requires-hard-pass. Never: banned langs (above), secrets, state files in repo root, AGPL. Details: the deed'"'"'s `(bot-directives (methodology) (coverage) (debt))` clauses.'

echo "== every clause present, no .a2ml file: the long-standing text, unchanged"
T="$(mk_tree full with-clauses)"
OUT="$(render "$T")" || { fail "full tree renders"; OUT=""; }
contains "substrate sentence and 'no .a2ml' sentence" "$OUT" "$OLD_SUBSTRATE"
contains "CHORA row names every clause"                "$OUT" "$OLD_CHORA_ROW"
contains "neurosym row"                                "$OUT" "$OLD_NEUROSYM_ROW"
contains "playbook row"                                "$OUT" "$OLD_PLAYBOOK_ROW"
contains "constraints line"                            "$OUT" "$OLD_CONSTRAINTS"
contains "state line"                                  "$OUT" '- **State** — phase active; maturity beta. Milestones'
contains "where-it-sits line"                          "$OUT" '- **Where it sits** — pipeline position **leaf**; chain `standards → Fixture.jl`; coordination = `standards`.'

echo "== partly migrated child: tracked .a2ml files, deed without (agentic) (neurosym) (playbook) (bot-directives)"
T="$(mk_tree child)"
add_a2ml "$T" .machine_readable/6a2/AGENTIC.a2ml
add_a2ml "$T" .machine_readable/6a2/NEUROSYM.a2ml
add_a2ml "$T" docs/NOTES.a2ml
add_a2ml "$T" .machine_readable/6a2/PLAYBOOK.a2ml untracked
OUT="$(render "$T")" || { fail "child tree renders"; OUT=""; }
printf '%s\n' "$OUT" | sed -n '/^## The machine-readable substrate/,/^## Canon pointers/p;/^# This repo:/,/^<!-- ARRIVAL-PACK:END/p' | sed 's/^/        | /' > "$WORK/child-block.txt"
# The statements that were false:
lacks "does not say there are no .a2ml files"          "$OUT" 'There are no `.a2ml` files'
lacks "does not call every named thing a deed clause"  "$OUT" "$OLD_SUBSTRATE"
lacks "does not list (agentic) as a clause of this deed" "$OUT" '`(anchor)`, `(agentic)`'
lacks "CHORA row does not claim (agentic)"             "$OUT" '`(agentic)` *may I act now?*'
lacks "CHORA row does not claim (meta)"                "$OUT" '`(meta)` the architecture axes'
lacks "neurosym row carries no bare claim"             "$OUT" "$OLD_NEUROSYM_ROW"
lacks "playbook row carries no bare claim"             "$OUT" "$OLD_PLAYBOOK_ROW"
lacks "no unconditional constraints line"              "$OUT" 'fail-closed; evidence-per-step'
lacks "no pointer to absent (bot-directives) clauses"  "$OUT" '(bot-directives (methodology) (coverage) (debt))'
# What is true instead:
contains "counts the tracked legacy files (3, not the untracked one)" "$OUT" 'This repo still tracks 3 legacy `.a2ml` files, awaiting conversion'
contains "says they are read-only pending conversion"  "$OUT" 'read-only pending that conversion; never create, restore or extend one, and you may only delete content from one.'
contains "names the clauses the deed has"              "$OUT" 'In its deed: `(anchor)`, `(ecosystem)`, `(status)`, `(maturity)`.'
contains "names AGENTIC.a2ml where found"              "$OUT" '`(agentic)` (legacy file `.machine_readable/6a2/AGENTIC.a2ml`, read-only pending conversion); '
contains "names NEUROSYM.a2ml where found"             "$OUT" '`(neurosym)` (legacy file `.machine_readable/6a2/NEUROSYM.a2ml`, read-only pending conversion); '
contains "(playbook) absent, no file named (the only one is untracked)" "$OUT" 'Not yet in its deed: `(agentic)` (legacy file `.machine_readable/6a2/AGENTIC.a2ml`, read-only pending conversion); `(neurosym)` (legacy file `.machine_readable/6a2/NEUROSYM.a2ml`, read-only pending conversion); `(playbook)`. STATE'
lacks "never names a path that was not found"           "$OUT" 'PLAYBOOK.a2ml'
lacks "never names a file that holds no named clause"  "$OUT" 'NOTES.a2ml'
contains "CHORA row names only the clauses present"    "$OUT" '12 shelves; `(ecosystem)` where it sits and what it is not; `(status)` and `(maturity)` where it is now. Read fields'
contains "neurosym row says not yet in the deed"       "$OUT" '| `(neurosym)` | *Meaning* of operations — proof obligations. Not yet in this repo'"'"'s deed; legacy file `.machine_readable/6a2/NEUROSYM.a2ml`, read-only pending conversion. |'
contains "playbook row says not yet in the deed"       "$OUT" '| `(playbook)` | *How* permitted actions run. Not yet in this repo'"'"'s deed. |'
contains "constraints line says (agentic) is absent and names the file" "$OUT" '- **Constraints here** (AGENTIC) — not yet in the deed: no `(agentic)` clause (legacy file `.machine_readable/6a2/AGENTIC.a2ml`, read-only pending conversion). The estate policy above applies. Details: not yet in the deed (`(bot-directives)` has no `(methodology)`, `(coverage)` or `(debt)` clause).'
contains "clauses the deed does have still render"      "$OUT" '- **State** — phase active; maturity beta. Milestones'
contains "golden path still renders"                    "$OUT" '`just test` → tests pass.'
echo "        generated block for the partly migrated child (substrate + per-repo parts):"
cat "$WORK/child-block.txt"

echo "== a deed with no (status), (maturity) or (ecosystem): lines degrade, never empty"
T="$(mk_tree bare)"
# strip status, maturity and ecosystem from the fixture deed
awk '
  /^  \(status /   { next }
  /^  \(maturity / { next }
  /^  \(ecosystem$/ { skip = 1 }
  skip && /^  \(anchor$/ { skip = 0 }
  !skip { print }
' "$T/fixture_chora.deed" > "$T/x" && mv "$T/x" "$T/fixture_chora.deed"
add_a2ml "$T" .machine_readable/descriptiles/STATE.a2ml
add_a2ml "$T" .machine_readable/descriptiles/ECOSYSTEM.a2ml
OUT="$(render "$T")" || { fail "bare tree renders"; OUT=""; }
contains "IS says (ecosystem) is absent and names its legacy file" "$OUT" '- **IS** — not yet in the deed: no `(ecosystem)` clause (legacy file `.machine_readable/descriptiles/ECOSYSTEM.a2ml`, read-only pending conversion)'
contains "IS-NOT says the same"       "$OUT" '- **IS-NOT** — not yet in the deed: no `(ecosystem)` clause'
contains "where-it-sits says the same" "$OUT" '- **Where it sits** — not yet in the deed: no `(ecosystem)` clause'
contains "state line: phase unknown, file named" "$OUT" '- **State** — phase unknown (not yet in the deed: no `(status)` clause; legacy file `.machine_readable/descriptiles/STATE.a2ml`, read-only pending conversion); maturity unknown (not yet in the deed: no `(maturity)` clause; legacy file `.machine_readable/descriptiles/STATE.a2ml`, read-only pending conversion).'
lacks "CHORA row names none of the absent clauses" "$OUT" '`(ecosystem)` where it sits'
contains "CHORA row ends cleanly with no clause to name" "$OUT" 'one of the 12 shelves. Read fields with `scripts/deed-field.sh`. |'
lacks "no empty phase"               "$OUT" 'phase ;'

echo "== every clause present, but .a2ml files tracked: clause text kept, count sentence replaces the 'no .a2ml' one"
T="$(mk_tree fullwith with-clauses)"
add_a2ml "$T" legacy/OTHER.a2ml
OUT="$(render "$T")" || { fail "full tree with an .a2ml renders"; OUT=""; }
contains "clause sentence unchanged"  "$OUT" 'STATE'"'"'s journal is `docs/status/ROADMAP.adoc`. This repo still tracks 1 legacy `.a2ml` file, awaiting conversion to deed clauses (kyX, ruling D313): it is read-only'
contains "clauses all named as present" "$OUT" 'are clauses of the CHORA deed — `(anchor)`, `(agentic)`, `(ecosystem)`, `(status)` and `(maturity)`, `(neurosym)`, `(playbook)` — not files;'
lacks "no false 'no .a2ml'"            "$OUT" 'There are no `.a2ml` files'
contains "constraints line unchanged" "$OUT" "$OLD_CONSTRAINTS"

echo "== outside a git work tree: every .a2ml under the tree (minus .git/) is counted"
T="$WORK/nogit"; mkdir -p "$T/scripts" "$T/.machine_readable"
cp "$REPO_DIR/scripts/deed-field.sh" "$T/scripts/"
write_deed "$T/fixture_chora.deed" with-clauses
mkdir -p "$T/a/b" "$T/.git/objects"
printf 'x\n' > "$T/a/b/ONE.a2ml"; printf 'x\n' > "$T/TWO.a2ml"; printf 'x\n' > "$T/.git/objects/IGNORED.a2ml"
COUNT="$(bash "$AP/extract.sh" "$T" | jq -r '.a2ml_count')"
equal "counts 2 (.git/ is skipped)" "$COUNT" 2
OUT="$(render "$T")" || { fail "tree outside git renders"; OUT=""; }
contains "says 'contains', not 'tracks': nothing is tracked there" "$OUT" 'This repo still contains 2 legacy `.a2ml` files, awaiting conversion'
lacks "does not say 'tracks' outside a git work tree" "$OUT" 'still tracks'
# A backslash or a newline in a name is one path, not a quoted or a split one.
printf 'x\n' > "$T/back\\slash.a2ml"; printf 'x\n' > "$T/"$'new\nline.a2ml'
FILES="$(bash "$AP/extract.sh" "$T" | jq -c '.a2ml_files')"
equal "a backslash and a newline in a name stay one path each (on disk)" "$FILES" '["TWO.a2ml","a/b/ONE.a2ml","back\\slash.a2ml","new\nline.a2ml"]'

echo "== the git index: one count per path, names kept as written"
T="$(mk_tree index with-clauses)"
add_a2ml "$T" 'back\slash.a2ml'
add_a2ml "$T" $'new\nline.a2ml'
FILES="$(bash "$AP/extract.sh" "$T" | jq -c '.a2ml_files')"
equal "a backslash and a newline in a name stay one path each (tracked)" "$FILES" '["back\\slash.a2ml","new\nline.a2ml"]'
# A conflicted path has one index entry per stage; it is still one file.
T="$(mk_tree conflict with-clauses)"
printf '[legacy]\n' > "$T/BOTH.a2ml"
BLOB="$(git -C "$T" hash-object -w "$T/BOTH.a2ml")"
printf '100644 %s 1\tBOTH.a2ml\n100644 %s 2\tBOTH.a2ml\n100644 %s 3\tBOTH.a2ml\n' "$BLOB" "$BLOB" "$BLOB" \
    | git -C "$T" update-index --index-info
equal "the fixture has three index entries for the one path" "$(git -C "$T" ls-files -- '*.a2ml' | grep -c .)" 3
equal "a conflicted path is counted once" "$(bash "$AP/extract.sh" "$T" | jq -c '[.a2ml_count, .a2ml_files]')" '[1,["BOTH.a2ml"]]'
# A pipe in a legacy path would end the table cell it is named in (GFM splits
# cells on a pipe even inside backticks), so it is written escaped.
T="$(mk_tree pipe)"
add_a2ml "$T" 'old|copy/NEUROSYM.a2ml'
OUT="$(render "$T")" || { fail "tree with a pipe in a legacy path renders"; OUT=""; }
contains "a pipe in a legacy path is escaped in the neurosym row" "$OUT" 'deed; legacy file `old\|copy/NEUROSYM.a2ml`, read-only pending conversion. |'
lacks "and never written bare" "$OUT" '`old|copy/NEUROSYM.a2ml`'

echo "== a list value named like a clause is not the clause (deed.abnf: value = … / quoted / list)"
READER="$REPO_DIR/scripts/deed-field.sh"
# has DEED PATH -> the exit status of deed-field.sh --has
has() { local rc=0; bash "$READER" --has "$1" "$2" || rc=$?; echo "$rc"; }
T="$(mk_tree listvalue)"
D="$T/fixture_chora.deed"
sed -i 's/^  (maturity :level beta)$/  :example (agentic)\n  :quoted '"'"'(neurosym)\n&/' "$D"
equal "the fixture holds the two list-valued fields" "$(grep -cE '^  :(example \(agentic\)|quoted .\(neurosym\))$' "$D")" 2
equal ":example (agentic) is no (agentic) clause"     "$(has "$D" agentic)"  1
equal ":quoted '(neurosym) is no (neurosym) clause"   "$(has "$D" neurosym)" 1
equal "the list is still read as the field's value"   "$(bash "$READER" --list "$D" '' example)" agentic
equal "a real clause after the fields is still found" "$(has "$D" maturity)" 0
OUT="$(render "$T")" || { fail "list-value tree renders"; OUT=""; }
contains "the pack reports (agentic) and (neurosym) as absent" "$OUT" 'Not yet in its deed: `(agentic)`; `(neurosym)`; `(playbook)`.'
lacks "the pack prints no AGENTIC constraints for a list value" "$OUT" 'fail-closed; evidence-per-step'
# The same deed with a real (agentic) clause after the list-valued field.
sed -i 's/^  (maturity :level beta)$/&\n  (agentic :version "9.9.9")/' "$D"
equal "a real (agentic) clause beside the list value is found" "$(has "$D" agentic)" 0
equal "and it is the clause that is read, not the list" "$(bash "$READER" "$D" agentic version)" 9.9.9

echo "== a reader failure on a (bot-directives) sub-clause stops the run"
T="$(mk_tree readerfail with-clauses)"
# A stand-in reader: fails (rc 2) on a bot-directives sub-clause, else the real one.
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "$*" in *bot-directives/*) echo "deed-field.sh: no readable deed (stand-in)" >&2; exit 2 ;; esac'
    printf 'exec bash %q "$@"\n' "$READER"
} > "$T/scripts/deed-field.sh"
rc=0; bash "$AP/extract.sh" "$T" >/dev/null 2>&1 || rc=$?
equal "extract.sh fails instead of reporting the sub-clause absent" "$rc" 2

echo "== generate.sh and verify.sh agree on the partly migrated child"
T="$(mk_tree e2e)"
add_a2ml "$T" .machine_readable/6a2/AGENTIC.a2ml
if ( cd "$T" && bash .machine_readable/arrival-pack/generate.sh >/dev/null 2>&1 && bash .machine_readable/arrival-pack/verify.sh >/dev/null 2>&1 ); then
    pass "generate.sh then verify.sh in the child: in sync"
else
    fail "generate.sh then verify.sh in the child: in sync"
fi
if grep -qF 'This repo still tracks 1 legacy `.a2ml` file' "$T/CLAUDE.md"; then pass "CLAUDE.md carries the derived count"; else fail "CLAUDE.md carries the derived count"; fi
rm "$T/.machine_readable/6a2/AGENTIC.a2ml"; git -C "$T" rm -q --cached -- .machine_readable/6a2/AGENTIC.a2ml
# Only the drift verdict counts: exit 1 with the stale-region diagnostic. Any
# other failure of verify.sh (a missing tool, an unreadable deed) is not drift.
rc=0; VOUT="$(cd "$T" && bash .machine_readable/arrival-pack/verify.sh 2>&1)" || rc=$?
if [[ "$rc" -eq 1 ]] && grep -qF 'DRIFT: CLAUDE.md arrival-pack region is stale or hand-edited.' <<<"$VOUT"; then
    pass "verify.sh reports drift once the legacy file is gone (regenerate)"
else
    fail "verify.sh reports drift once the legacy file is gone (regenerate)" "rc=$rc" "$VOUT"
fi

echo "== whole-file parse: content outside the one (repo-deed …) form is refused (deed_lint.js does)"
T="$(mk_tree strict with-clauses)"
extract_rc() { bash "$AP/extract.sh" "$T" >/dev/null 2>"$WORK/err"; echo $?; }
equal "a well-formed deed is read" "$(extract_rc)" 0
printf '\n  \n; a closing comment\n\n' >> "$T/fixture_chora.deed"
equal "trailing whitespace and comments are allowed" "$(extract_rc)" 0
cp "$T/fixture_chora.deed" "$WORK/ok.deed"
printf 'trailing\n' >> "$T/fixture_chora.deed"
rc="$(extract_rc)"
if [[ "$rc" == 2 ]] && grep -q 'not exactly one deed form' "$WORK/err"; then pass "trailing atom is refused"; else fail "trailing atom is refused" "rc=$rc" "$(cat "$WORK/err")"; fi
cp "$WORK/ok.deed" "$T/fixture_chora.deed"; printf '(extra-form :a 1)\n' >> "$T/fixture_chora.deed"
equal "a second form is refused" "$(extract_rc)" 2
cp "$WORK/ok.deed" "$T/fixture_chora.deed"; sed -i 's/^;; SPDX.*$/stray\n&/' "$T/fixture_chora.deed"
equal "content before the form is refused" "$(extract_rc)" 2
write_deed "$T/fixture_chora.deed" with-clauses; sed -i '$d' "$T/fixture_chora.deed"   # drop the closing ")"
rc="$(extract_rc)"
if [[ "$rc" == 2 ]] && grep -q 'never closes' "$WORK/err"; then pass "a form that never closes is refused"; else fail "a form that never closes is refused" "rc=$rc" "$(cat "$WORK/err")"; fi
# deed-field.sh --strict itself
rc=0; bash "$REPO_DIR/scripts/deed-field.sh" --strict "$WORK/ok.deed" || rc=$?
equal "deed-field.sh --strict accepts the well-formed deed" "$rc" 0
printf 'x\n' > "$WORK/bad.deed"; cat "$WORK/ok.deed" >> "$WORK/bad.deed"
rc=0; bash "$REPO_DIR/scripts/deed-field.sh" --strict "$WORK/bad.deed" || rc=$?
equal "deed-field.sh --strict exits 1 on leading content" "$rc" 1
# Byte 0x01 is the reader's record separator: one that ends the file was dropped.
{ cat "$WORK/ok.deed"; printf '\001'; } > "$WORK/soh.deed"
rc=0; bash "$REPO_DIR/scripts/deed-field.sh" --strict "$WORK/soh.deed" || rc=$?
equal "deed-field.sh --strict exits 1 on a trailing 0x01 byte" "$rc" 1

# Where the estate linter is checked out, it must agree with the strict mode.
LINT="${STANDARDS_DIR:-$REPO_DIR/../standards}/1-formats/deed/tools/deed_lint.js"
if command -v bun >/dev/null 2>&1 && [[ -f "$LINT" ]]; then
    cp "$WORK/ok.deed" "$WORK/okcase_chora.deed"
    { cat "$WORK/ok.deed"; printf 'trailing\n'; } > "$WORK/trail_chora.deed"
    rc=0; LOUT="$(bun "$LINT" "$WORK/okcase_chora.deed" 2>&1)" || rc=$?
    equal "deed_lint.js accepts the fixture" "$rc" 0
    # The linter must refuse the variant FOR its trailing content: a linter that
    # could not run, or refused it for another reason, is not agreement.
    rc=0; LOUT="$(bun "$LINT" "$WORK/trail_chora.deed" 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "trailing content after the form's closing ')'" <<<"$LOUT"; then
        pass "deed_lint.js refuses the trailing-content variant, by that diagnostic"
    else
        fail "deed_lint.js refuses the trailing-content variant, by that diagnostic" "rc=$rc" "$LOUT"
    fi
else
    echo "  SKIP  deed_lint.js cross-check (needs bun and a standards checkout: set STANDARDS_DIR, default ../standards)"
fi

echo "$CHECKS controls, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
