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

# hash12 -> short content hash of stdin (drift provenance)
hash12() { sha256sum | cut -c1-12; }

# The identity is the deed's own TYPED literal (#u5"<name>", later #u8"<domain:name>"),
# never a computed hex uuid. The uuid is derived from that name and never
# stored (deed.abnf); printing its hex form put a version-5 literal in
# CLAUDE.md, which ADR-008's strict gate (owner ruling D320, standards
# governance job uuid-v7-conformance) rejects in every minted repo. The
# typed literal says what the identifier is, as ADR-008 asks of legacy ids,
# and follows the deed when it moves to version 8.
uuid_name="$(field '' repo-uuid)"
uuid=""
[ -z "$uuid_name" ] || uuid="$(sed -n -E 's/^[[:space:]]*:repo-uuid[[:space:]]+(#u[0-9]+"[^"]*").*/\1/p' "$DEED" | head -1)"
[ -z "$uuid_name" ] || [ -n "$uuid" ] \
  || { echo "extract.sh: $(basename "$DEED") :repo-uuid is not a typed #u<n>\"...\" literal" >&2; exit 2; }

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
prefixed_name="$(field identity prefixed-name)"
clade_primary="$(field clade primary)"
clade_secondary="$(items clade secondary ', ')"
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
anchor_clause="$(bash "$READ" --clause "$DEED" anchor)"
h_deed="$(read_clauses | hash12)"
h_anchor="$(printf '%s\n' "$anchor_clause" | hash12)"

jq -n \
  --arg canonical_name "$canonical_name" \
  --arg prefixed_name  "$prefixed_name" \
  --arg uuid           "$uuid" \
  --arg clade_primary  "$clade_primary" \
  --arg clade_secondary "$clade_secondary" \
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
  '$ARGS.named'
