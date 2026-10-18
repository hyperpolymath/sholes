#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The mint's self-name pass rewrites the template's literal name to the
# child's, except on provenance lines and in issue references. It is a sed
# program inside build/just/repo-init.just; this runs that program, as the
# recipe defines it, over fixture lines. A recipe without the two lines fails
# the test rather than skipping it.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
recipe="$repo/build/just/repo-init.just"
prov=$(grep -m1 -E "^ +SELF_PROV='" "$recipe") || { echo "FAIL: no SELF_PROV line in $recipe" >&2; exit 1; }
prog=$(grep -m1 -E '^ +SELF_NAME_SED="' "$recipe") || { echo "FAIL: no SELF_NAME_SED line in $recipe" >&2; exit 1; }
OWNER=example-owner REPO=mint-check
eval "$prov"; eval "$prog"
fail=0
# check INPUT EXPECTED — the pass must turn INPUT into EXPECTED.
check() {
  local got; got=$(printf '%s\n' "$1" | sed -E "$SELF_NAME_SED")
  if [ "$got" = "$2" ]; then echo "  PASS $1"; else echo "  FAIL $1 -> $got (want $2)" >&2; fail=1; fi
}
check 'project := "rsr-template-repo"' 'project := "mint-check"'
check 'sonar.projectKey=hyperpolymath_rsr-template-repo' 'sonar.projectKey=hyperpolymath_mint-check'
check 'https://github.com/hyperpolymath/rsr-template-repo/issues/new' 'https://github.com/example-owner/mint-check/issues/new'
# Issue references name the template's own issues.
check '# deed clauses since rsr-template-repo#209.' '# deed clauses since rsr-template-repo#209.'
check 'see hyperpolymath/rsr-template-repo#53 and rsr-template-repo#106' 'see hyperpolymath/rsr-template-repo#53 and rsr-template-repo#106'
check 'rsr-template-repo (rsr-template-repo#7)' 'mint-check (rsr-template-repo#7)'
# Provenance and detector lines are left alone.
check ':instantiated-from "hyperpolymath/rsr-template-repo"' ':instantiated-from "hyperpolymath/rsr-template-repo"'
check ':reject-if-contains ("rsr-template-repo")' ':reject-if-contains ("rsr-template-repo")'
[ "$fail" -eq 0 ] || { echo "FAIL: self-name pass" >&2; exit 1; }
echo 'PASS: self-name pass rewrites the name, keeps issue references, provenance and detectors'
