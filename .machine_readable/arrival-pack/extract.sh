#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# extract.sh — the thin *reader* for the arrival-pack compiler.
#
# Projects the fields the CLAUDE.md arrival pack needs out of this repo's deed
# (<repo>_chora.deed: identity, clade, lineage, status, maturity, ecosystem,
# agentic, and the golden path in its (anchor) clause) into a single
# deterministic JSON document on stdout. Every deed read goes through
# scripts/deed-field.sh; there are no .a2ml inputs (rsr-template-repo#209).
#
# Besides the deed's fields it reports two facts about the tree, so the pack
# states them instead of asserting them: which of the clauses the pack names
# are in the deed (`has`), and the tracked legacy .a2ml files (`a2ml_files`,
# `a2ml_count`, `a2ml_source` saying where they were found, and `legacy`, the
# ones that carry the name of an absent clause).
#
# This is a READER only — it authors nothing. The deed remains the single
# source of truth; arrival-pack.ncl renders this JSON into the CLAUDE.md region.
# Determinism (no timestamps) is required so the k9 drift check can byte-compare.
set -euo pipefail
# A failed $(…) inside a function or assignment must stop the run, not read as "".
shopt -s inherit_errexit

ROOT="${1:-.}"
READ="$ROOT/scripts/deed-field.sh"

DEED="$(bash "$READ" --find "$ROOT")" \
  || { echo "extract.sh: need exactly one *_chora.deed in $ROOT" >&2; exit 2; }
# The pack's contract says the deed parses, and deed_lint.js refuses content
# outside the one form; deed-field.sh alone reads the first form and ignores
# the rest, so the whole-file check is made here, before anything is read.
rc=0
bash "$READ" --strict "$DEED" || rc=$?
case "$rc" in
  0) ;;
  1) echo "extract.sh: $(basename "$DEED") is not exactly one deed form: content outside the (repo-deed …) form (deed_lint.js: trailing content after the form's closing ')')" >&2; exit 2 ;;
  *) echo "extract.sh: $(basename "$DEED") does not parse: its (repo-deed …) form never closes" >&2; exit 2 ;;
esac
bash "$READ" --has "$DEED" anchor/golden-path \
  || { echo "extract.sh: $(basename "$DEED") has no (anchor (golden-path)) clause" >&2; exit 2; }

# field PATH KEY -> the deed value, or "" when the clause or key is absent
# (rc 1); an unreadable deed or a usage error (rc 2) fails the run instead
field() {
  local rc=0
  bash "$READ" "$DEED" "$1" "$2" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
}

# items PATH KEY SEP -> the deed list :KEY ( … ) joined by the literal SEP,
# "" when absent; fails like field() when the deed cannot be read
items() {
  local out="" item first=1 list rc=0
  list="$(bash "$READ" --list "$DEED" "$1" "$2")" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    if [ "$first" -eq 1 ]; then out="$item"; first=0; else out="$out$3$item"; fi
  done <<< "$list"
  printf '%s' "$out"
}

# lines PATH KEY -> the deed list :KEY ( … ), one item per line, "" when absent
lines() {
  local out rc=0
  out="$(bash "$READ" --list "$DEED" "$1" "$2")" || rc=$?
  [[ "$rc" -le 1 ]] || return "$rc"
  printf '%s' "$out"
}

# has_clause PATH -> "true" or "false": whether the deed has that clause
# (rc 2 from the reader, an unreadable deed, fails the run like field() does)
has_clause() {
  local rc=0
  bash "$READ" --has "$DEED" "$1" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
  if [ "$rc" -eq 0 ]; then echo true; else echo false; fi
}

# The tracked legacy .a2ml files are read from the git index. Outside a git
# work tree nothing is tracked, so every .a2ml file under ROOT (minus .git/)
# stands in for them, and the pack says "contains", not "tracks".
a2ml_source=filesystem
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then a2ml_source=git-index; fi

# a2ml_list -> those paths, NUL-delimited, each once. NUL-delimited end to end,
# so git quotes nothing and a backslash or a newline in a name stays one path.
# A conflicted path has one index entry per stage: `sort -u` counts it once.
# Sorted bytewise, so the order (and the drift check's byte-compare) does not
# depend on the locale.
a2ml_list() {
  if [ "$a2ml_source" = git-index ]; then
    git -C "$ROOT" ls-files -z -- '*.a2ml'
  else
    (cd "$ROOT" && find . -path ./.git -prune -o -type f -name '*.a2ml' -print0)
  fi | LC_ALL=C sort -zu
}

# hash12 -> short content hash of stdin (drift provenance)
hash12() { sha256sum | cut -c1-12; }

# The identity is the deed's own TYPED literal, printed as written:
# #uuid"<v8 id>" (minted once, A7 J11), or the computed #u8"<domain:name>".
# The pack never prints a derived hex form of a name literal: that once put a
# version 5 id in CLAUDE.md, which ADR-008's strict gate (owner ruling D320)
# rejects in every minted repo. The typed literal says what the identifier is,
# as ADR-008 asks.
uuid_name="$(field '' repo-uuid)"
uuid=""
if [[ -n "$uuid_name" ]]; then
  # --typed keeps the tag and quotes, and reads the literal wherever the layout puts it
  rc=0
  uuid="$(bash "$READ" --typed "$DEED" '' repo-uuid)" || rc=$?
  [[ "$rc" -le 1 ]] || exit "$rc"
  [[ "$uuid" =~ ^#u(uid|[0-9]+)\"[^\"]*\"$ ]] || uuid=""
fi
[ -z "$uuid_name" ] || [ -n "$uuid" ] \
  || { echo "extract.sh: $(basename "$DEED") :repo-uuid is not a typed #uuid\"...\" or #u<n>\"...\" literal" >&2; exit 2; }
# A version 5 identity is reported, not refused, here: this is the arrival-pack
# reader, not the gate. Standards A1 v0.4.5 C10 and T30 (ruling Q2) make
# v5-identity and u5-identity errors in every mode, and `just validate-rsr`
# and estate-rules (scripts/check-identity.sh) refuse them. The chora id is the
# v8 id of the birth path.
case "$uuid" in
  '#u5"'*|'#uuid"'????????-????-5*)
    echo "extract.sh: v5-identity: $(basename "$DEED") :repo-uuid $uuid is a version 5 id; the chora id is #uuid\"<v8 id of the birth path>\" (standards A1 V8)" >&2 ;;
  *) ;;  # any other identity is printed as written, with nothing to report
esac

# read_clauses -> the clauses this pack reads, one token per line. Hashing only
# these keeps an unrelated deed edit (say a canon-pin bump) from reading as drift.
read_clauses() {
  local c
  bash "$READ" "$DEED" '' canonical-name
  printf '%s\n' "$uuid_name"
  for c in identity clade lineage forges status maturity ecosystem agentic; do
    bash "$READ" --clause "$DEED" "$c" || [ "$?" -eq 1 ] || return 2
  done
}

isnot="$(items ecosystem not ' · ')"
[ -n "$isnot" ] || isnot="(not yet declared — add (ecosystem :not (…)) to the deed)"

# Each value is its own assignment so that a failed deed read stops the run;
# as a bare `--arg x "$(…)"` its exit status would be discarded.
canonical_name="$(field '' canonical-name)"
[ -n "$canonical_name" ] \
  || { echo "extract.sh: $(basename "$DEED") has no :canonical-name" >&2; exit 2; }
# Clade placements are identity facts about where the repo sits, never its id
# and never an edict; chora-registry is authoritative for them (standards A1
# §11, ruling W10). The clause is optional.
clade_primary="$(field clade primary)"
clade_secondary="$(items clade secondary ', ')"
if [[ -z "$clade_primary" ]]; then
  clade_aid="none declared (optional placement)"
elif [[ -n "$clade_secondary" ]]; then
  clade_aid="$clade_primary (secondary $clade_secondary; placement)"
else
  clade_aid="$clade_primary (placement)"
fi
born="$(field lineage born)"
forge_gh="$(field forges github)"
purpose="$(field ecosystem purpose)"
pipeline_pos="$(field ecosystem pipeline-position)"
chain="$(field ecosystem chain)"
coordination="$(field ecosystem coordination)"
phase="$(field status phase)"
maturity="$(field maturity level)"
golden_smoke="$(items anchor/golden-path smoke-test-command ' && ')"
golden_crit="$(items anchor/golden-path success-criteria '; ')"
# The anchor may override the estate language policy for this repo only.
anchor_forbidden="$(lines anchor/implementation-policy forbidden)"
anchor_allowed="$(lines anchor/implementation-policy allowed)"
anchor_clause="$(bash "$READ" --clause "$DEED" anchor)"
h_deed="$(read_clauses | hash12)"
h_anchor="$(printf '%s\n' "$anchor_clause" | hash12)"

# Which of the clauses the pack names the deed has, and which legacy files are
# tracked. An absent clause renders as absent (arrival-pack.ncl), never as an
# empty value or as the clause's usual text.
has_anchor="$(has_clause anchor)"
has_agentic="$(has_clause agentic)"
has_ecosystem="$(has_clause ecosystem)"
has_status="$(has_clause status)"
has_maturity="$(has_clause maturity)"
has_neurosym="$(has_clause neurosym)"
has_playbook="$(has_clause playbook)"
has_meta="$(has_clause meta)"
# bot-directives is named by its three sub-clauses, so those are reported.
bd_present=""
for c in methodology coverage debt; do
  # Assigned first: inside the test, a reader failure (rc 2) would be lost.
  has_bd="$(has_clause "bot-directives/$c")"
  if [ "$has_bd" = true ]; then bd_present="$bd_present$c"$'\n'; fi
done
# A JSON array; find's leading "./" is dropped so both sources name paths alike.
a2ml_files="$(a2ml_list | jq -Rsc 'split("\u0000") | map(select(. != "") | ltrimstr("./"))')"

jq -cnS \
  --arg canonical_name "$canonical_name" \
  --arg clade_aid      "$clade_aid" \
  --arg uuid           "$uuid" \
  --arg born           "$born" \
  --arg forge_gh       "$forge_gh" \
  --arg purpose        "$purpose" \
  --arg isnot          "$isnot" \
  --arg pipeline_pos   "$pipeline_pos" \
  --arg chain          "$chain" \
  --arg coordination   "$coordination" \
  --arg phase          "$phase" \
  --arg maturity       "$maturity" \
  --arg deed           "$(basename "$DEED")" \
  --arg golden_smoke   "$golden_smoke" \
  --arg golden_crit    "$golden_crit" \
  --arg h_deed         "$h_deed" \
  --arg h_anchor       "$h_anchor" \
  --arg anchor_forbidden "$anchor_forbidden" \
  --arg anchor_allowed   "$anchor_allowed" \
  --argjson a2ml_files   "$a2ml_files" \
  --arg a2ml_source      "$a2ml_source" \
  --arg bd_present       "$bd_present" \
  --argjson has_anchor    "$has_anchor" \
  --argjson has_agentic   "$has_agentic" \
  --argjson has_ecosystem "$has_ecosystem" \
  --argjson has_status    "$has_status" \
  --argjson has_maturity  "$has_maturity" \
  --argjson has_neurosym  "$has_neurosym" \
  --argjson has_playbook  "$has_playbook" \
  --argjson has_meta      "$has_meta" \
  '$a2ml_files as $f
   | def named($n): [$f[] | select((split("/") | last | ascii_downcase) == $n)];
   ($ARGS.named
    | del(.bd_present, .has_anchor, .has_agentic, .has_ecosystem,
          .has_status, .has_maturity, .has_neurosym, .has_playbook, .has_meta))
   | .anchor_forbidden |= (split("\n") | map(select(. != "")))
   | .anchor_allowed   |= (split("\n") | map(select(. != "")))
   | .a2ml_count = ($f | length)
   | .has = {anchor: $has_anchor, agentic: $has_agentic, ecosystem: $has_ecosystem,
             status: $has_status, maturity: $has_maturity, neurosym: $has_neurosym,
             playbook: $has_playbook, meta: $has_meta,
             bot_directives: ($bd_present | split("\n") | map(select(. != "")))}
   | .legacy = {anchor: named("anchor.a2ml"), agentic: named("agentic.a2ml"),
                ecosystem: named("ecosystem.a2ml"), state: named("state.a2ml"),
                neurosym: named("neurosym.a2ml"), playbook: named("playbook.a2ml"),
                bot_directives: [$f[] | select(test("(^|/)bot_directives/"; "i"))]}'
