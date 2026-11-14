#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# coaptation_families_test.sh — controls for the descriptile families of
# Coaptation. The Idris2 core (core/Coaptation.idr) declares `Family`; the
# fact extractor (extract-facts.sh) emits facts whose ID prefix names a
# family. If the two lists drift apart, a deed clause is either read and
# untyped, or typed and never read. Each control below names the defect it
# catches.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CO="$here/.machine_readable/coaptation"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fails=0

# ok MSG — record a control that held.
ok() { echo "ok   $*"; }
# bad MSG — record a control that failed and count it.
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# families -> the Family constructors of the Idris2 core, lower-cased, sorted
families() {
  grep -E '^data Family = ' "$CO/core/Coaptation.idr" \
    | sed -E 's/^data Family = //' | tr '|' '\n' | tr -d ' ' \
    | tr '[:upper:]' '[:lower:]' | grep -v '^$' | LC_ALL=C sort
}

# 1. The real deed: the extractor runs and reads both new clauses.
bash "$CO/extract-facts.sh" "$here" > "$scratch/facts.json" \
  || { bad "extract-facts.sh fails on this repo's deed"; exit 1; }
ok "extract-facts.sh reads this repo's deed"

for id in neurosym.scan-enabled neurosym.scan-depth neurosym.report-format \
          playbook.skeleton-version playbook.authority-allowlist playbook.enforcement-workflow; do
  if jq -e --arg id "$id" '.facts | any(.id == $id and .present)' "$scratch/facts.json" >/dev/null; then
    ok "$id is read from the deed"
  else
    bad "$id is missing or empty: the (neurosym)/(playbook) clause is not read"
  fi
done

# 2. Every fact family is a Family constructor, and every constructor has facts.
fam="$(families)"
pre="$(jq -r '.facts[].family' "$scratch/facts.json" | LC_ALL=C sort -u)"
if [ -n "$fam" ] && [ "$fam" = "$pre" ]; then
  ok "fact prefixes match the Family constructors ($(printf '%s' "$fam" | tr '\n' ' '))"
else
  bad "fact prefixes and Family constructors differ"
  diff <(printf '%s\n' "$fam") <(printf '%s\n' "$pre") || true
fi

# 3. A deed without (neurosym)/(playbook): a repo minted before those clauses
#    still extracts; the facts read absent instead of failing the run.
mkdir -p "$scratch/old/scripts"
cp "$here/scripts/deed-field.sh" "$scratch/old/scripts/"
cat > "$scratch/old/old_chora.deed" <<'DEED'
; SPDX-License-Identifier: MPL-2.0
(repo-deed
  :schema-version "1.0.0"
  :canonical-name "old"
  :repo-uuid #u5"github.com/example/old"
  (agentic
    (integrity :fail-closed #t))
  (anchor
    :authority "old"))
DEED
if bash "$CO/extract-facts.sh" "$scratch/old" > "$scratch/old.json" 2>"$scratch/old.err"; then
  if jq -e '[.facts[] | select(.family == "neurosym" or .family == "playbook") | .present] | length > 0 and all(. == false)' \
       "$scratch/old.json" >/dev/null; then
    ok "a deed without (neurosym)/(playbook) extracts with those facts absent"
  else
    bad "a deed without (neurosym)/(playbook) reports those facts present"
  fi
else
  bad "extract-facts.sh fails on a deed without (neurosym)/(playbook): $(cat "$scratch/old.err")"
fi

[ "$fails" -eq 0 ] || { echo "$fails control(s) failed"; exit 1; }
echo "all coaptation family controls held"
