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
  '$ARGS.named
   | .anchor_forbidden |= (split("\n") | map(select(. != "")))
   | .anchor_allowed   |= (split("\n") | map(select(. != "")))'
