#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# deed_clause_test.sh — controls for scripts/deed-clause.sh, the one writer of
# deed clauses. Every mint and setup recipe writes the deed through it, so a
# write that touches the wrong clause or leaves the form unreadable would
# corrupt every child's deed. Each control below names the defect it catches.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="$here/scripts/deed-clause.sh"
R="$here/scripts/deed-field.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fails=0

# ok MSG — record a control that held.
ok() { echo "ok   $*"; }
# bad MSG — record a control that failed and count it.
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# fresh — write the fixture deed and print its path.
fresh() {
  cat > "$scratch/t_chora.deed" <<'DEED'
; SPDX-License-Identifier: MPL-2.0
(repo-deed
  :schema-version "1.0.0"
  :canonical-name "t"
  ; groove rationale, belongs to the clause below
  (integrations
    (groove
      :port 0
      :health "/health"))
  (status
    :phase "active"))
DEED
  echo "$scratch/t_chora.deed"
}

# 1. set rewrites exactly one scalar and nothing else.
d=$(fresh)
bash "$W" set "$d" integrations/groove port 7421
[ "$(bash "$R" "$d" integrations/groove port)" = 7421 ] && ok "set writes the scalar" || bad "set did not write :port"
[ "$(bash "$R" "$d" status phase)" = active ] && ok "set leaves sibling clauses alone" || bad "set disturbed (status)"
[ "$(bash "$R" "$d" integrations/groove health)" = /health ] && ok "set leaves sibling keys alone" || bad "set disturbed :health"

# 2. An absent clause or key exits 1 and leaves the deed byte-identical.
d=$(fresh); before=$(sha256sum < "$d")
rc=0; bash "$W" set "$d" integrations/nope port 1 2>/dev/null || rc=$?
[ "$rc" -eq 1 ] && [ "$(sha256sum < "$d")" = "$before" ] && ok "absent clause: rc=1, deed untouched" || bad "absent clause: rc=$rc or deed changed"
rc=0; bash "$W" set "$d" status nope '"x"' 2>/dev/null || rc=$?
[ "$rc" -eq 1 ] && [ "$(sha256sum < "$d")" = "$before" ] && ok "absent key: rc=1, deed untouched" || bad "absent key: rc=$rc or deed changed"

# 3. A value that is not a deed scalar literal is refused (usage error 2).
rc=0; bash "$W" set "$d" status phase 'two words' 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] && ok "non-literal value refused" || bad "non-literal value accepted (rc=$rc)"

# 4. replace swaps the clause together with its leading comment.
d=$(fresh)
printf '  (integrations\n    (groove :port 9))' | bash "$W" replace "$d" integrations -
grep -q 'groove rationale' "$d" && bad "replace kept the old leading comment" || ok "replace drops the clause's leading comment"
[ "$(bash "$R" "$d" integrations/groove port)" = 9 ] && ok "replace installs the new clause" || bad "replace did not install the clause"

# 5. A write that would unbalance the form is refused and the deed kept.
d=$(fresh); before=$(sha256sum < "$d")
rc=0; printf '  (status :phase "x"' | bash "$W" replace "$d" status - 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] && [ "$(sha256sum < "$d")" = "$before" ] && ok "unbalanced replace refused, deed untouched" || bad "unbalanced replace: rc=$rc or deed changed"

# 6. append adds a last child that reads back.
d=$(fresh)
printf '  (provenance :template "rsr")' | bash "$W" append "$d" "" -
[ "$(bash "$R" "$d" provenance template)" = rsr ] && ok "append adds a readable clause" || bad "append did not add (provenance)"

if [ "$fails" -eq 0 ]; then
  echo "PASS: deed-clause.sh controls"
else
  echo "FAIL: $fails deed-clause.sh control(s)"
  exit 1
fi
