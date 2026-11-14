#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# scripts/canon-pin-check.sh: the decision behind dogfood-gate.yml `Canon
# lockstep`, including two-phase adoption (:proposed-by). Offline: fixtures
# only, no network.
# Usage: bash tests/workflows/canon_pin_check_test.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
check="$root/scripts/canon-pin-check.sh"
tmp="$(mktemp -d)"
# CI sets the repository id; the strict cases below must not depend on which
# repository runs this file, so each case that wants an id passes its own.
unset GITHUB_REPOSITORY_ID
trap 'rm -rf "$tmp"' EXIT

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

# lock <file> <version> <criteria> <gates>: a canon.lock in the real layout.
lock() {
  cat > "$1" <<EOF
# criteria = { sha256 = "$C" }   <- a comment must not be read
[canon]
# version = "9.9.9"   <- a commented-out value must not be read
version      = "$2"
status       = "draft"          # draft | stable

[canon.artifacts]
criteria = { path = "0-canon/rsr/rsr-criteria-v2.a2ml",
             # previously sha256 = "$C" (a comment inside the entry)
             sha256 = "$3",
             slot = "criteria", normative = true }

gates = { path = ".machine_readable/template-capability-gates.toml",
          sha256 = "$4",
          slot = "gates", normative = true }
EOF
}

# deed <file> <version> <criteria> <gates> [extra fields…]
deed() {
  local f="$1" v="$2" c="$3" g="$4"; shift 4
  {
    echo '(repo-deed'
    echo '  :schema-version "1.0.0"'
    echo '  ; (canon :version "9.9.9") <- a comment, not a second clause'
    echo "  (canon"
    echo "    :version \"$v\""
    echo "    :criteria-sha256 \"$c\""
    echo "    :gates-sha256 \"$g\""
    for x in "$@"; do echo "    $x"; done
    echo '    :order "spine-adopts-then-canon-releases"))'
  } > "$f"
}

pass=0
expect() { # expect <want-rc> <name> <cmd…>
  local want="$1" name="$2"; shift 2
  local rc=0
  "$@" > "$tmp/out" 2> "$tmp/err" || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL: $name (rc $rc, want $want)"; cat "$tmp/out" "$tmp/err"; exit 1
  fi
  pass=$((pass + 1)); echo "PASS: $name"
}

lock "$tmp/released.lock" 2.1.5 "$A" "$B"
lock "$tmp/next.lock"     2.1.6 "$A" "$C"

deed "$tmp/same.deed" 2.1.5 "$A" "$B"
expect 0 "released: a pin equal to canon.lock passes" bash "$check" released "$tmp/same.deed" "$tmp/released.lock"

deed "$tmp/behind.deed" 2.1.4 "$A" "$C"
expect 1 "released: a different pin naming no canon PR fails" bash "$check" released "$tmp/behind.deed" "$tmp/released.lock"

# Spine versus instance: the pin is provenance in an instance, so an OLDER
# canon passes there with a notice; the spine (and a local run with no
# repository id) stays strict. A same-version or later pin with other hashes
# fails everywhere: that is a wrong pin, not a lag.
SPINE=1306804488 OTHER=999
expect 1 "spine: an older pin fails" env GITHUB_REPOSITORY_ID=$SPINE bash "$check" released "$tmp/behind.deed" "$tmp/released.lock"
expect 0 "instance: an older pin passes" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" released "$tmp/behind.deed" "$tmp/released.lock"
grep -q '::notice::this repo was cut from canon 2.1.4; canon 2.1.5 is released' "$tmp/out" || { echo "FAIL: lag notice missing"; exit 1; }
deed "$tmp/samever.deed" 2.1.5 "$A" "$C"
expect 1 "instance: the released version with other hashes fails" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" released "$tmp/samever.deed" "$tmp/released.lock"
deed "$tmp/later.deed" 2.1.6 "$A" "$C"
expect 1 "instance: a later version with no canon PR fails" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" released "$tmp/later.deed" "$tmp/released.lock"
deed "$tmp/minor.deed" 2.0.10 "$A" "$C"
expect 0 "instance: versions compare numerically (2.0.10 < 2.1.5)" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" released "$tmp/minor.deed" "$tmp/released.lock"
lock "$tmp/ten.lock" 2.1.10 "$A" "$B"
lock "$tmp/nine.lock" 2.1.9 "$A" "$B"
deed "$tmp/nine.deed" 2.1.9 "$A" "$C"
deed "$tmp/ten.deed" 2.1.10 "$A" "$C"
expect 0 "instance: versions compare numerically (2.1.9 < 2.1.10)" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" released "$tmp/nine.deed" "$tmp/ten.lock"
expect 1 "instance: 2.1.10 is not older than 2.1.9" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" released "$tmp/ten.deed" "$tmp/nine.lock"

deed "$tmp/ahead.deed" 2.1.6 "$A" "$C" ':proposed-by "metadatastician/standards#1440"'
expect 3 "released: a different pin naming a canon PR defers to that PR" bash "$check" released "$tmp/ahead.deed" "$tmp/released.lock"
grep -qx 'PROPOSED_BY=metadatastician/standards#1440' "$tmp/out" || { echo "FAIL: PROPOSED_BY line missing"; exit 1; }

expect 0 "pending: open canon PR with the same canon.lock passes" bash "$check" pending "$tmp/ahead.deed" "$tmp/next.lock" open
expect 1 "pending: a closed canon PR fails (the pin was never released)" bash "$check" pending "$tmp/ahead.deed" "$tmp/next.lock" closed
expect 1 "pending: an amended canon PR fails (its canon.lock moved)" bash "$check" pending "$tmp/ahead.deed" "$tmp/released.lock" open

deed "$tmp/spent.deed" 2.1.5 "$A" "$B" ':proposed-by "hyperpolymath/standards#1424"'
expect 0 "released: a spent :proposed-by still passes" bash "$check" released "$tmp/spent.deed" "$tmp/released.lock"
grep -q 'is spent' "$tmp/out" || { echo "FAIL: spent notice missing"; exit 1; }

# Release sequence: minted while the template pinned 2.1.4 via a proposal that
# released 2.1.4. While 2.1.4 is current it passes; once 2.1.5 releases, the
# instance defers its proposal to the PR state (rc 3 with LAGS_BEHIND), and only a
# MERGED proposal makes it pass with a notice; closed unmerged fails.
lock "$tmp/r214.lock" 2.1.4 "$A" "$C"
deed "$tmp/minted.deed" 2.1.4 "$A" "$C" ':proposed-by "metadatastician/standards#1440"'
expect 0 "instance: a spent proposal passes while its release is current" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" released "$tmp/minted.deed" "$tmp/r214.lock"
expect 3 "spine: the same older pin with a proposal is deferred, with no LAGS_BEHIND" env GITHUB_REPOSITORY_ID=$SPINE bash "$check" released "$tmp/minted.deed" "$tmp/released.lock"
if grep -q LAGS_BEHIND "$tmp/out"; then echo "FAIL: spine got a lag marker"; exit 1; fi
# An unreleased proposal (pin ahead of the release) is still validated in an instance.
expect 3 "instance: an unreleased proposal is still checked" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" released "$tmp/ahead.deed" "$tmp/released.lock"
grep -qx 'PROPOSED_BY=metadatastician/standards#1440' "$tmp/out" || { echo "FAIL: PROPOSED_BY missing for unreleased proposal"; exit 1; }

# An older instance pin with a proposal is spent only when that proposal MERGED:
# released mode defers (3) with LAGS_BEHIND, pending decides on the PR state.
expect 3 "instance: an older pin with a proposal defers to the PR state" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" released "$tmp/minted.deed" "$tmp/released.lock"
grep -qx "LAGS_BEHIND=2.1.5" "$tmp/out" || { echo "FAIL: LAGS_BEHIND missing"; exit 1; }
expect 0 "instance: an older pin whose proposal merged passes" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" pending "$tmp/minted.deed" "$tmp/r214.lock" merged 2.1.5
grep -q "merged and released canon 2.1.4" "$tmp/out" || { echo "FAIL: spent notice missing"; exit 1; }
expect 1 "instance: an older pin whose proposal closed unmerged fails" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" pending "$tmp/minted.deed" "$tmp/r214.lock" closed 2.1.5
expect 1 "instance: an older pin whose merged proposal lock differs fails" env GITHUB_REPOSITORY_ID=$OTHER bash "$check" pending "$tmp/minted.deed" "$tmp/released.lock" merged 2.1.5
expect 1 "spine: a merged proposal is not accepted as spent" env GITHUB_REPOSITORY_ID=$SPINE bash "$check" pending "$tmp/minted.deed" "$tmp/r214.lock" merged 2.1.5

deed "$tmp/badref.deed" 2.1.6 "$A" "$C" ':proposed-by "someone/else#12"'
expect 2 "a :proposed-by outside the canon repo is malformed" bash "$check" released "$tmp/badref.deed" "$tmp/released.lock"

deed "$tmp/badhash.deed" 2.1.5 "$A" "not-a-hash"
expect 2 "a pin of the wrong shape is malformed, never equal" bash "$check" released "$tmp/badhash.deed" "$tmp/released.lock"

{ cat "$tmp/same.deed"; echo '(canon :version "2.1.5")'; } > "$tmp/two.deed"
expect 2 "two (canon …) clauses are malformed" bash "$check" released "$tmp/two.deed" "$tmp/released.lock"

expect 2 "pending mode without :proposed-by is malformed" bash "$check" pending "$tmp/same.deed" "$tmp/next.lock" open

# Only the template tree (scripts/is-template-tree.sh) has the real deed to check; other trees skip with a notice.
if bash "$root/scripts/is-template-tree.sh" "$root"; then
# The real deed against a lock built from its own pins: the reader agrees
# with the deed this repository ships.
real="$root/rsr-template-repo_chora.deed"
v="$(bash "$root/scripts/deed-field.sh" "$real" canon version)"
c="$(bash "$root/scripts/deed-field.sh" "$real" canon criteria-sha256)"
g="$(bash "$root/scripts/deed-field.sh" "$real" canon gates-sha256)"
lock "$tmp/own.lock" "$v" "$c" "$g"
expect 0 "the shipped deed passes against its own pins" bash "$check" released "$real" "$tmp/own.lock"
else
  echo "SKIP: the shipped-deed controls (not the template tree; is-template-tree.sh says no)"
fi

echo "canon_pin_check: $pass passed"
