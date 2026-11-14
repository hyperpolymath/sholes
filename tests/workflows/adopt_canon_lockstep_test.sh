#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# scripts/adopt-canon-lockstep.sh: replaces only the canon-lockstep job and
# copies the decision script; refuses (writing nothing) when the lock would
# not cover the new job. Offline fixtures only.
# Usage: bash tests/workflows/adopt_canon_lockstep_test.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tool="$root/scripts/adopt-canon-lockstep.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

CHECKOUT="actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"

# block <workflow>: the canon-lockstep job as the test sees it, written
# independently of the tool: from the key to the last non-comment line before
# the next two-space key (or a column-0 key).
block() {
  awk '/^  "?canon-lockstep"?:/ { f = 1 }
       f && !/canon-lockstep/ && (/^  [^ #]/ || /^[^ #]/) { exit }
       f { print }' "$1" | awk '{ l[NR] = $0 } END { n = NR; while (n > 0 && (l[n] ~ /^[[:space:]]*$/ || l[n] ~ /^ {0,2}#/)) n--; for (i = 1; i <= n; i++) print l[i] }'
}

# instance <dir> <locked-actions…>: an old-style instance whose dogfood-gate
# has a job before and after an inline canon-lockstep job.
instance() {
  local d="$1"; shift
  mkdir -p "$d/.github/workflows" "$d/scripts"
  cat > "$d/.github/workflows/dogfood-gate.yml" <<'EOF'
name: Dogfood Gate
on: [push]
jobs:
  first:
    runs-on: ubuntu-24.04
    steps:
      - run: echo first

  canon-lockstep:
    name: Canon lockstep
    runs-on: ubuntu-24.04
    steps:
      - name: old inline compare
        run: |
          echo "old inline job"
          exit 1

  last:
    runs-on: ubuntu-24.04
    steps:
      - run: echo last
EOF
  {
    echo "version: 'v0.0.3'"
    echo "workflows:"
    echo "    '.github/workflows/dogfood-gate.yml':"
    for a in "$@"; do echo "        - '$a'"; done
    echo "dependencies:"
  } > "$d/.github/workflows/actions.lock"
}

# 1. Adopted: the job equals the template's, its neighbours are untouched,
#    the script is copied.
instance "$tmp/a" "$CHECKOUT"
bash "$tool" "$tmp/a" > /dev/null
tpl_job="$(block "$root/.github/workflows/dogfood-gate.yml")"
got_job="$(block "$tmp/a/.github/workflows/dogfood-gate.yml")"
[ "$tpl_job" = "$got_job" ] || fail "adopted job differs from the template's"
grep -q 'old inline job' "$tmp/a/.github/workflows/dogfood-gate.yml" && fail "old job text survived"
grep -q 'echo first' "$tmp/a/.github/workflows/dogfood-gate.yml" || fail "the job before was lost"
grep -qx '  last:' "$tmp/a/.github/workflows/dogfood-gate.yml" || fail "the job after was lost"
grep -q '^  last:' <(awk '/^  canon-lockstep:/{f=1} f' "$tmp/a/.github/workflows/dogfood-gate.yml") || fail "job order changed"
cmp -s "$root/scripts/canon-pin-check.sh" "$tmp/a/scripts/canon-pin-check.sh" || fail "decision script not copied"
ok "adopts the template job between untouched neighbours and copies the script"

# 1b. The next job written with an inline comment, or with a quoted key, and
#     its header comment, all survive (a missed boundary used to delete the
#     next job).
for next in '  build: # Build application' '  "build":'; do
  instance "$tmp/n" "$CHECKOUT"
  perl -0pi -e "s/\n  last:\n/\n  # --- the build job ---\n${next//\//\\/}\n/" "$tmp/n/.github/workflows/dogfood-gate.yml"
  grep -qxF "$next" "$tmp/n/.github/workflows/dogfood-gate.yml" || fail "fixture for '$next' not built"
  bash "$tool" "$tmp/n" > /dev/null
  wf="$tmp/n/.github/workflows/dogfood-gate.yml"
  grep -qxF "$next" "$wf" || fail "the next job ('$next') was deleted"
  grep -qxF '  # --- the build job ---' "$wf" || fail "the next job's header comment was deleted ('$next')"
  grep -q 'echo last' "$wf" || fail "the next job's body was deleted ('$next')"
  grep -q 'old inline job' "$wf" && fail "old job text survived ('$next')"
  rm -rf "$tmp/n"
done
ok "a next job with an inline comment or a quoted key, and its header comment, survive"

# 2. Idempotent.
cp "$tmp/a/.github/workflows/dogfood-gate.yml" "$tmp/once"
out="$(bash "$tool" "$tmp/a")"
cmp -s "$tmp/once" "$tmp/a/.github/workflows/dogfood-gate.yml" || fail "second run changed the workflow"
[ "$out" = "adopt-canon-lockstep: already current" ] || fail "second run did not report current: $out"
ok "idempotent"

# 3. Refused, untouched: the lock does not cover the template job's checkout.
instance "$tmp/b" "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
cp "$tmp/b/.github/workflows/dogfood-gate.yml" "$tmp/b-before"
if bash "$tool" "$tmp/b" > /dev/null 2> "$tmp/b-err"; then fail "an uncovered lock was accepted"; fi
cmp -s "$tmp/b-before" "$tmp/b/.github/workflows/dogfood-gate.yml" || fail "refusal changed the workflow"
[ ! -f "$tmp/b/scripts/canon-pin-check.sh" ] || fail "refusal copied the script"
grep -q "does not list for dogfood-gate.yml: $CHECKOUT" "$tmp/b-err" || fail "refusal reason missing"
ok "refuses, writing nothing, when actions.lock does not cover the job"

# 4. No job: left alone. Two jobs: refused.
mkdir -p "$tmp/c/.github/workflows"
printf 'jobs:\n  first:\n    runs-on: x\n' > "$tmp/c/.github/workflows/dogfood-gate.yml"
cp "$tmp/c/.github/workflows/dogfood-gate.yml" "$tmp/c-before"
bash "$tool" "$tmp/c" > /dev/null || fail "a repo without the job was refused"
cmp -s "$tmp/c-before" "$tmp/c/.github/workflows/dogfood-gate.yml" || fail "a repo without the job was changed"
instance "$tmp/d" "$CHECKOUT"
printf '\n  canon-lockstep:\n    runs-on: x\n' >> "$tmp/d/.github/workflows/dogfood-gate.yml"
if bash "$tool" "$tmp/d" > /dev/null 2>&1; then fail "two canon-lockstep jobs were accepted"; fi
ok "no job is left alone; two jobs are refused"

echo "adopt_canon_lockstep: $pass passed"
