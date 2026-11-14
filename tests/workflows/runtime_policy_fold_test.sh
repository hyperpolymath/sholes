#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression tests for PR #244: governance replaces the retired runtime gate
# in both validators. Run offline with:
#   bash tests/workflows/runtime_policy_fold_test.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
# A space in the path also checks that both validators quote the supplied root.
FIXTURE="$SCRATCH/repo with spaces"
WORKFLOWS="$FIXTURE/.github/workflows"
mkdir -p "$WORKFLOWS"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Independent fixture requirements: deriving these from the validators would
# let a regression in their required-workflow lists silently change the tests.
for name in hypatia-scan codeql scorecard quality mirror instant-sync \
  guix-policy security-policy wellknown-enforcement workflow-linter \
  governance secret-scanner; do
  printf '# SPDX-License-Identifier: MPL-2.0\nname: %s\n' "$name" > "$WORKFLOWS/$name.yml"
done

# Unit-test the template validator's actual workflow requirement section.
# The complete script also invokes compilers and scans unrelated source files;
# extracting this section keeps these tests independent of those toolchains.
TEMPLATE_CHECKS=$(awk '
  /^REQUIRED_WORKFLOWS=\(/ { emit=1; starts++ }
  /^# Verify all workflows/ { if (emit) { emit=0; ends++ } }
  emit { print }
  END { if (starts != 1 || ends != 1) exit 1 }
' "$REPO_DIR/scripts/validate-template.sh") || fail "cannot locate template workflow checks"

# These variables and callbacks are consumed by the sourced validator section.
# shellcheck disable=SC2034,SC2329
template_check() (
  REPO_ROOT="$FIXTURE"
  VERBOSE=1
  ERRORS=0
  log_pass() { printf 'PASS: %s\n' "$*"; }
  log_error() { printf 'ERROR: %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
  # Execute the original array, resolver and loop, rather than a copy of them.
  # shellcheck disable=SC1091
  source /dev/stdin <<< "$TEMPLATE_CHECKS"
  declare -p REQUIRED_WORKFLOWS >/dev/null
  [ "$ERRORS" -eq 0 ]
)

workflow_check() {
  bash "$REPO_DIR/tests/workflows/validate_workflows_test.sh" "$WORKFLOWS"
}

expect_status() {
  local expected="$1" check="$2" actual=0
  OUTPUT=$("$check" 2>&1) || actual=$?
  [ "$actual" -eq "$expected" ] \
    || fail "$check returned $actual, expected $expected: $OUTPUT"
}

require_output() {
  grep -Fq -- "$1" <<< "$OUTPUT" || fail "missing '$1' in: $OUTPUT"
}

reject_output() {
  if grep -Fq -- "$1" <<< "$OUTPUT"; then
    fail "unexpected '$1' in: $OUTPUT"
  fi
}

assert_governance_present() {
  expect_status 0 template_check
  require_output 'Workflow found: governance.yml'
  reject_output 'Required workflow missing:'
  expect_status 0 workflow_check
  require_output 'Found: governance.yml'
  reject_output 'Missing:'
  for retired in runtime-policy npm-bun-blocker ts-blocker; do
    reject_output "$retired.yml"
  done
}

assert_governance_missing() {
  local workflow_status="${1:-0}"
  expect_status 1 template_check
  require_output 'Required workflow missing: governance.yml'
  # This validator intentionally reports missing workflows as recommendations.
  expect_status "$workflow_status" workflow_check
  require_output 'Missing: governance.yml'
  reject_output 'Found: governance.yml'
}

# Positive control: no runtime-policy.yml (or its predecessors) is needed.
assert_governance_present
echo 'PASS: governance alone satisfies both validators'

# Negative control: removing governance must be observed by both checks.
rm "$WORKFLOWS/governance.yml"
assert_governance_missing
echo 'PASS: missing governance fails template validation and warns in workflow validation'

# Legacy workflow names must not accidentally become aliases for governance.
for retired in runtime-policy npm-bun-blocker ts-blocker; do
  printf '# SPDX-License-Identifier: MPL-2.0\nname: Retired\n' > "$WORKFLOWS/$retired.yml"
  assert_governance_missing
  rm "$WORKFLOWS/$retired.yml"
  echo "PASS: $retired.yml cannot replace governance.yml"
done

# A repository carrying every historical gate still needs governance. Keep
# these files through recovery to check coexistence as well as replacement.
for retired in runtime-policy npm-bun-blocker ts-blocker; do
  printf '# SPDX-License-Identifier: MPL-2.0\nname: Retired\n' > "$WORKFLOWS/$retired.yml"
done
assert_governance_missing
echo 'PASS: all retired workflows together cannot replace governance.yml'
cp "$REPO_DIR/.github/workflows/governance.yml" "$WORKFLOWS/governance.yml"
expect_status 0 template_check
require_output 'Workflow found: governance.yml'
reject_output 'Required workflow missing:'
expect_status 0 workflow_check
require_output 'Found: governance.yml'
reject_output 'Missing:'
echo 'PASS: governance satisfies both validators alongside retired workflows'
rm "$WORKFLOWS/governance.yml"
for retired in runtime-policy npm-bun-blocker ts-blocker; do
  rm "$WORKFLOWS/$retired.yml"
done

# Only the declared root-level .yml name satisfies this requirement. A .yaml
# file is discoverable by workflow validation, but is not a configured alias;
# backup/template suffixes must not pass through a prefix or glob match.
for alternative in governance.yaml governance.yml.bak governance.yml.in; do
  cp "$REPO_DIR/.github/workflows/governance.yml" "$WORKFLOWS/$alternative"
  assert_governance_missing
  rm "$WORKFLOWS/$alternative"
  echo "PASS: $alternative cannot replace governance.yml"
done

# Recursive discovery must not turn a nested workflow into the required file.
mkdir "$WORKFLOWS/nested"
cp "$REPO_DIR/.github/workflows/governance.yml" "$WORKFLOWS/nested/governance.yml"
assert_governance_missing
rm "$WORKFLOWS/nested/governance.yml"
rmdir "$WORKFLOWS/nested"
echo 'PASS: nested governance.yml does not satisfy the root-level requirement'

# Existence checks must not accept an entry whose target is missing.
ln -s missing-governance.yml "$WORKFLOWS/governance.yml"
assert_governance_missing 1
require_output "governance.yml: Missing 'name' field"
rm "$WORKFLOWS/governance.yml"
echo 'PASS: dangling governance symlink is treated as missing'

# A path with the right name is insufficient: a regular workflow file is needed.
mkdir "$WORKFLOWS/governance.yml"
# The directory also fails this validator's name-field check during discovery.
assert_governance_missing 1
require_output "governance.yml: Missing 'name' field"
rmdir "$WORKFLOWS/governance.yml"
echo 'PASS: a directory named governance.yml is treated as missing'

# Recovery control: restoring the file clears the diagnostic in both checks.
cp "$REPO_DIR/.github/workflows/governance.yml" "$WORKFLOWS/governance.yml"
assert_governance_present
echo 'PASS: restoring governance clears both missing-workflow diagnostics'
