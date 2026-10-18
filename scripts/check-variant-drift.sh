#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-variant-drift.sh — verify the shared RSR spine of this variant
# template stays convergent with its parent at the pinned commit.
#
# Reads the contract from the repo deed's (variant) clause
# (<repo>_chora.deed, read with scripts/deed-field.sh):
#   - every tracked file NOT declared added/removed/diverged/pending/operational
#     must be identical to the parent's copy at parent-pin, modulo the
#     (normalise) rules (action-pin SHAs, self-name substitution);
#   - declared additions must exist here and not in the parent;
#   - declared removals must exist in the parent and not here.
#
# Usage: check-variant-drift.sh <parent-checkout-dir> [self-dir]
# Exit:  0 = spine convergent; 1 = undeclared drift (listed on stdout).

set -euo pipefail

PARENT_DIR="${1:?usage: check-variant-drift.sh <parent-checkout-dir> [self-dir]}"
SELF_DIR="${2:-.}"
READ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deed-field.sh"

# The retired VARIANT.a2ml is not read: a repo still carrying one must be
# migrated to the (variant) clause, and saying so beats guessing at it.
if [ -f "$SELF_DIR/.machine_readable/descriptiles/VARIANT.a2ml" ]; then
  echo "FAIL: $SELF_DIR carries the retired VARIANT.a2ml — move its contract into the deed's (variant) clause"
  exit 1
fi
DEED=$(bash "$READ" --find "$SELF_DIR") || { echo "FAIL: no single *_chora.deed in $SELF_DIR"; exit 1; }
bash "$READ" --has "$DEED" variant || { echo "FAIL: $DEED has no (variant) clause"; exit 1; }

SELF_NAME=$(bash "$READ" "$DEED" variant project || true)
PARENT_SLUG=$(bash "$READ" "$DEED" variant parent || true)
PARENT_NAME="${PARENT_SLUG##*/}"
PIN=$(bash "$READ" "$DEED" variant parent-pin || true)
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || PIN=""

# section_paths SECTION — the path list :SECTION of the (variant (paths …))
# clause, one per line; nothing when the key is absent.
section_paths() {
  bash "$READ" --list "$DEED" variant/paths "$1" 2>/dev/null || true
}

ADDED=$(section_paths added)
REMOVED=$(section_paths removed)
SKIP=$(printf '%s\n' "$(section_paths diverged)" \
                     "$(section_paths diverged-pending-upstream)" \
                     "$(section_paths operational-state)")

# in_list PATH LIST — 0 when PATH is in the newline-separated LIST; an entry
# ending in / matches as a directory prefix.
in_list() {
  local p="$1" e
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    case "$e" in
      */) case "$p" in "$e"*) return 0;; esac ;;
      *)  [ "$p" = "$e" ] && return 0 ;;
    esac
  done <<< "$2"
  return 1
}

# normalise FILE — print FILE with operational state folded out before comparison: action-pin SHAs,
# then BOTH repo names → SELF (variant name first — it does not contain the
# parent name as a substring, so order is safe). Folding both names on both
# sides keeps inherited files that legitimately mention the parent by name
# convergent, while still matching self-identity substitutions.
normalise() {
  sed -E -e 's/@[0-9a-f]{40}[^ ]*( # v[^ ]*)?/@PIN/g' \
         -e "s/$SELF_NAME/SELF/g" -e "s/$PARENT_NAME/SELF/g" "$1"
}

DRIFT=0
# report MSG — record one drift finding and mark the run failed.
report() { DRIFT=1; echo "DRIFT: $*"; }

if [ -n "$PIN" ] && [ -d "$PARENT_DIR/.git" ]; then
  ACTUAL=$(git -C "$PARENT_DIR" rev-parse HEAD)
  [ "$ACTUAL" = "$PIN" ] || echo "WARN: parent checkout is $ACTUAL, contract pins $PIN"
fi

# 1. Spine files must match, modulo normalisation.
while IFS= read -r f; do
  in_list "$f" "$ADDED" && continue
  in_list "$f" "$SKIP" && continue
  if [ ! -f "$PARENT_DIR/$f" ]; then
    report "$f exists here but not in parent (declare in paths.added or remove)"
    continue
  fi
  if ! diff -q <(normalise "$PARENT_DIR/$f") \
               <(normalise "$SELF_DIR/$f") >/dev/null 2>&1; then
    report "$f differs from parent (declare in paths.diverged or re-converge)"
  fi
done < <(git -C "$SELF_DIR" ls-files)

# 2. Parent files absent here must be declared removed.
while IFS= read -r f; do
  [ -f "$SELF_DIR/$f" ] && continue
  in_list "$f" "$REMOVED" && continue
  in_list "$f" "$SKIP" && continue
  report "parent has $f but it is absent here (declare in paths.removed)"
done < <(git -C "$PARENT_DIR" ls-files)

# 3. Declared additions must exist (and not silently exist in parent).
while IFS= read -r e; do
  [ -z "$e" ] && continue
  case "$e" in
    */) [ -d "$SELF_DIR/$e" ] || report "declared-added directory $e is missing" ;;
    *)  [ -f "$SELF_DIR/$e" ] || report "declared-added file $e is missing"
        [ -e "$PARENT_DIR/$e" ] && report "declared-added $e also exists in parent (not an addition)" ;;
  esac
done <<< "$ADDED"

# 4. Declared removals must still exist in the parent.
while IFS= read -r e; do
  [ -z "$e" ] && continue
  [ -e "$PARENT_DIR/$e" ] || report "declared-removed $e no longer exists in parent (stale entry)"
done <<< "$REMOVED"

if [ "$DRIFT" -eq 0 ]; then
  echo "PASS: spine convergent with $PARENT_SLUG@${PIN:0:12} (modulo declared variant paths)"
else
  echo "FAIL: undeclared drift against $PARENT_SLUG@${PIN:0:12} — update the deed's (variant) clause or re-converge"
  exit 1
fi
