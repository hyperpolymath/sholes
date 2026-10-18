#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# extract-clauses.sh — the NORMATIVE-side atomiser for Coaptation.
#
# Step 1 of the build path: give each contractile verb a machine-checkable
# clause-list with STABLE IDs. The clauses live as records in the `declaration`
# field of each verb's K9 component (`<verb>/<verb>.k9.ncl`; the A2ML Xfiles they
# came from are retired). This reader lifts them — it invents no semantics. Each
# obligation becomes a stable id `verb.slug` with its description, gate-field and
# whether it carries a runnable probe (`probe`, `injection_probe` or
# `recovery_probe`).
#
# Collections read, per verb (the runner schema's collection name):
#   intend: intents, then wishes   must: invariants     trust: verifications
#   adjust: requirements           dust: removal_candidates   bust: failure_modes
#
# READER only — authors nothing. Deterministic (no timestamps) so the receipt the
# Yard comparator emits can be byte-compared by verify.sh.
#
# Needs: nickel, jq. A K9 file starts with the `K9!` magic line, which is not
# Nickel, so each file is exported from a stripped copy placed next to a copy of
# `_base.ncl` (the k9 files import `../_base.ncl`).
#
# Output (stdout): { "clauses": [ {id,verb,slug,description,severity,status,
#                   tolerance,has_probe,horizon,is_wish} ... ],
#                   "provenance": { <verb>: <hash of <verb>.k9.ncl> } }
set -euo pipefail

DIR="${1:-.machine_readable/contractiles}"
NICKEL="${NICKEL:-nickel}"

ORDER=(intend must trust adjust dust bust)

for v in "${ORDER[@]}"; do
  f="$DIR/$v/$v.k9.ncl"
  [ -f "$f" ] || { echo "extract-clauses.sh: missing contractile K9 file: $f" >&2; exit 2; }
done
[ -f "$DIR/_base.ncl" ] || { echo "extract-clauses.sh: missing $DIR/_base.ncl" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$DIR/_base.ncl" "$WORK/_base.ncl"

# Print a short content hash of file $1 (drift provenance; matches
# arrival-pack extract.sh).
sh() { sha256sum "$1" | cut -c1-12; }

# Print the `declaration` field of verb $1's K9 file as JSON. Strips the `K9!`
# magic line into a scratch copy so `nickel export` can read it.
declaration_json() {
  local verb="$1"
  mkdir -p "$WORK/$verb"
  tail -n +2 "$DIR/$verb/$verb.k9.ncl" > "$WORK/$verb/$verb.k9.ncl"
  "$NICKEL" export --format json --field declaration "$WORK/$verb/$verb.k9.ncl"
}

# Emit one clause object per line (JSON) for verb $1, in declaration order.
# A record is a clause only if its id is a plain slug, as before.
atomise() {
  local verb="$1"
  declaration_json "$verb" | jq -c --arg verb "$verb" '
    def s: if . == null then "" else tostring end;
    (if $verb == "intend" then (.intents // []) + (.wishes // [])
     elif $verb == "must"   then .invariants // []
     elif $verb == "trust"  then .verifications // []
     elif $verb == "adjust" then .requirements // []
     elif $verb == "dust"   then .removal_candidates // []
     elif $verb == "bust"   then .failure_modes // []
     else [] end)[]
    | select(.id | test("^[A-Za-z0-9_-]+$"))
    | {
        verb: $verb,
        slug: .id,
        description: (.description | s | gsub("\t"; " ")),
        severity:  (.severity | s),
        status:    (.status | s),
        tolerance: (.tolerance | s),
        has_probe: (has("probe") or has("injection_probe") or has("recovery_probe")),
        horizon:   (.horizon | s)
      }
  '
}

# Build the clause rows + the provenance object.
rows="$(for v in "${ORDER[@]}"; do atomise "$v"; done)"

prov_args=()
for v in "${ORDER[@]}"; do
  prov_args+=(--arg "$v" "$(sh "$DIR/$v/$v.k9.ncl")")
done

printf '%s\n' "$rows" | jq -s "${prov_args[@]}" '
  {
    clauses: map({
      id:          (.verb + "." + .slug),
      verb:        .verb,
      slug:        .slug,
      description: .description,
      severity:    .severity,
      status:      .status,
      tolerance:   .tolerance,
      has_probe:   .has_probe,
      horizon:     .horizon,
      is_wish:     (.horizon | length > 0)
    }),
    provenance: {
      intend: $intend, must: $must, trust: $trust,
      adjust: $adjust, dust: $dust, bust: $bust
    }
  }
'
