#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
#
# Feed the proof-ladder files cited by Actually-Proven tests (from the JSON run
# report) into panic-attack's `aggregate`, which classifies each proof artifact
# (Closed/Holes/Refuted/Indeterminate) and folds it into a trust-tagged report.
#
# Exit contract (proven-tests-and-benches 3-outcome convention):
#   0 = all Actually-Proven ladder files classified Closed (or 0 Actually-Proven
#       entries in a valid report)
#   1 = panic-attack aggregate reported a non-Closed verdict (Holes / Refuted)
#   2 = setup error: missing/unparseable report, missing jq, or missing
#       panic-attack binary when Actually-Proven files require aggregation
#
# Usage: emit-aggregate-inputs.sh <run-report.json> [panic-attack-binary]
set -euo pipefail

REPORT="${1:-build/report/proven-tests-report.json}"
PANIC_ATTACK="${2:-panic-attack}"

if [ ! -f "$REPORT" ]; then
  echo "error: run report not found: $REPORT" >&2
  echo "  run: ./build/exec/proven-tests --report $REPORT" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to filter Actually-Proven entries in $REPORT" >&2
  exit 2
fi

WORK_DIR="$(mktemp -d)"
EXTRACT_TMP="$WORK_DIR/files"
trap 'rm -rf "$WORK_DIR"' EXIT
if ! jq -er '
  if (type != "object") or (.entries | type != "array") then
    error("report must be an object with an entries array")
  else
    [ .entries[]
      | select(.provenance == "Actually-Proven")
      | (.proof_ladder // [])[]
      | .proof_file
      | select(type == "string" and length > 0)
    ] | unique | .[]
  end
' "$REPORT" > "$EXTRACT_TMP" 2>/dev/null; then
  # Note: `jq -e` exits 4 when output is empty (`unique | .[]` produces zero
  # items); distinguish malformed JSON/schema from a valid empty selection.
  if ! jq -e 'type == "object" and (.entries | type == "array")' "$REPORT" >/dev/null 2>&1; then
    echo "error: malformed or invalid run report: $REPORT" >&2
    exit 2
  fi
  : > "$EXTRACT_TMP"
fi

mapfile -t LADDER_FILES < "$EXTRACT_TMP"

if [ "${#LADDER_FILES[@]}" -eq 0 ]; then
  echo "no Actually-Proven proof-ladder files cited in $REPORT — nothing to aggregate"
  exit 0
fi

echo "Actually-Proven proof-ladder files to aggregate:"
printf '  %s\n' "${LADDER_FILES[@]}"

if ! command -v "$PANIC_ATTACK" >/dev/null 2>&1; then
  echo "error: '$PANIC_ATTACK' not on PATH — cannot classify ${#LADDER_FILES[@]} Actually-Proven proof file(s)" >&2
  exit 2
fi

status=0
idx=0
for f in "${LADDER_FILES[@]}"; do
  idx=$((idx + 1))
  output="$WORK_DIR/$idx.json"
  label="$(basename "$f" .idr)-ladder"
  echo "--- aggregate: $f (label=$label) ---"
  if ! "$PANIC_ATTACK" aggregate --proof "$f" --label "$f=$label" --output "$output"; then
    echo "error: aggregate failed for $f" >&2
    status=1
  elif ! jq -e '
    (.aggregated_proofs | type == "array" and length > 0)
    and all(.aggregated_proofs[]; .verdict == "closed")
  ' "$output" >/dev/null 2>&1; then
    echo "error: aggregate reported a non-Closed verdict for $f" >&2
    status=1
  fi
done
exit "$status"
