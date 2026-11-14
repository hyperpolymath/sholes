#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Stage-2 trial of standards A7 (8.1, section 11 M2): does an edict find a
# violation from identity? One Mustfile.deed edict is run against this
# template's real chora deed and against a fork's, with a STATE.deed that
# holds, one that breaks the edict and one that lacks the fact.
#
# The edict: a standalone repo declares an active phase and a known maturity.
# It must apply to the template (lineage :type standalone) and stay silent
# for a fork, without the fork listing anything (A7 YE03).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The trial runs against this template's own deed, so it only means something in
# the template tree. A repo minted from the template has its own deed: skip there.
if ! bash "$repo_root/scripts/is-template-tree.sh" "$repo_root"; then
  echo "SKIP: edict trial (not the template tree; is-template-tree.sh says no)"
  exit 0
fi
work="$(mktemp -d)"
cleanup() {
  case "$work" in
    /*) [[ -d "$work" ]] && rm -rf -- "$work" ;;
    *) echo "refusing unsafe cleanup target: $work" >&2 ;;
  esac
}
trap cleanup EXIT

run() { bash "$repo_root/scripts/rust-tool.sh" edict-run "$@"; }
fail=0
expect() { # expect NAME WANT_EXIT WANT_LINE CHORA STATE
  local name="$1" want="$2" line="$3" out rc=0
  out="$(run "$4" "$work/Mustfile.deed" "$5")" || rc=$?
  if [[ "$rc" -ne "$want" ]] || ! grep -qF -- "$line" <<<"$out"; then
    echo "FAIL $name: exit $rc (wanted $want); output: $out" >&2
    fail=1
  else
    echo "ok   $name: $out"
  fi
}

cat > "$work/Mustfile.deed" <<'DEED'
;; SPDX-License-Identifier: MPL-2.0
(contractile-deed
  :schema-version "1.0.0"
  :canonical-name "edict-trial"
  :verb must
  (rule :id "standalone-declares-state"
    :text "A standalone repo declares an active phase and a known maturity in STATE.deed."
    (applies-when (chora (lineage :type standalone)))
    (requires (state (status :phase active)
                     (maturity :level (:one-of experimental alpha beta production))))))
DEED

state() { # state FILE BODY
  local file="$1" body="$2"
  printf ';; SPDX-License-Identifier: MPL-2.0\n(descriptile-deed\n  :schema-version "1.0.0"\n  :canonical-name "edict-trial"\n%s)\n' "$body" > "$file"
}
state "$work/STATE-holds.deed"   '  (status :phase active :since "2026-03-16")
  (maturity :level production)'
state "$work/STATE-broken.deed"  '  (status :phase active :since "2026-03-16")
  (maturity :level unknown)'
state "$work/STATE-missing.deed" '  (status :phase active :since "2026-03-16")'

cat > "$work/fork_chora.deed" <<'DEED'
;; SPDX-License-Identifier: MPL-2.0
(repo-deed
  :schema-version "1.0.0"
  :canonical-name "some-fork"
  (identity :primary-forge github :owner "example")
  (lineage :type fork :parent "example/upstream"))
DEED

chora="$repo_root/rsr-template-repo_chora.deed"
expect template-holds    0 "must/standalone-declares-state: holds"          "$chora" "$work/STATE-holds.deed"
expect template-violated 1 "violated [blocking]: (maturity :level) is unknown" "$chora" "$work/STATE-broken.deed"
expect template-missing  1 "unresolved [blocking]: (maturity) is absent"    "$chora" "$work/STATE-missing.deed"
expect fork-silent       0 "not-applicable: (lineage :type) is fork"        "$work/fork_chora.deed" "$work/STATE-broken.deed"

exit "$fail"
