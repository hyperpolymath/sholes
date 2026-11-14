#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Run the real PR #253 policy step with a local GitHub Advisory API double.
# Usage: bash tests/workflows/dependabot_automerge_test.sh
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
bun run - "$repo" "$work/policy.sh" <<'JS'
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
const doc = Bun.YAML.parse(readFileSync(`${process.argv[2]}/.github/workflows/dependabot-automerge.yml`, "utf8"));
const job = doc.jobs.automerge;
assert.match(job.if, /github\.event\.pull_request\.user\.id == 49699333/);
assert.match(job.if, /github\.event\.pull_request\.user\.login == 'dependabot\[bot\]'/);
const policy = job.steps.filter(s => s.id === "policy");
assert.equal(policy.length, 1);
assert.equal(policy[0].env.GH_TOKEN, "${{ github.token }}");
for (const step of job.steps.filter(s => /gh pr (review|merge)/.test(s.run ?? ""))) {
  assert.equal(step.if, "steps.policy.outputs.action == 'automerge'");
  assert.equal(step.env.GH_TOKEN, "${{ github.token }}");
}
writeFileSync(process.argv[3], policy[0].run);
JS
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ "$#" -eq 2 && "$1" == api && "$2" == /advisories/GHSA-2345-6789-cfgh ]] || exit 98
printf '%s\n' "$2" >> "$ADVISORY_CALLS"
[[ "${API_STATUS:-0}" == 0 ]] || exit "$API_STATUS"
cat "$ADVISORY_JSON"
SH
chmod +x "$work/bin/gh"
export ADVISORY_CALLS="$work/api-calls" ADVISORY_JSON="$work/advisory.json"
export META_GHSA_ID=GHSA-2345-6789-cfgh DEP_NAMES='Example-Pkg' \
  UPDATE_TYPE=version-update:semver-patch PR_BODY=''
make_advisory() { # <severity> <JSON score>
  jq -nc --arg severity "$1" --argjson score "$2" \
    '{severity:$severity,cvss:{score:$score},vulnerabilities:[{package:{name:"example-pkg"}}]}' > "$ADVISORY_JSON"
}
expect() { # <action> <label>
  local want=$1 label=$2 got=0
  : > "$work/output"; : > "$ADVISORY_CALLS"
  BASH_ENV=/dev/null PATH="$work/bin:$PATH" GITHUB_OUTPUT="$work/output" \
    bash --noprofile --norc "$work/policy.sh" > "$work/log" 2>&1 || got=$?
  if [[ "$got" -eq 0 ]] && grep -qxF "action=$want" "$work/output"; then
    pass=$((pass + 1)); echo "PASS: $label"
  else
    fail=$((fail + 1)); echo "FAIL: $label (expected $want, exit $got)"
    cat "$work/output" "$work/log"
  fi
}
for severity in low medium; do
  make_advisory "$severity" 6.9
  for update in patch minor; do
    UPDATE_TYPE="version-update:semver-$update" expect automerge "$severity security $update below CVSS 7 qualifies"
  done
done
make_advisory medium 7
expect manual_review 'CVSS exactly 7 requires human review'
for severity in high critical unknown; do
  make_advisory "$severity" 4
  expect manual_review "severity $severity requires human review even with low score"
done
make_advisory low 2
for update in version-update:semver-major version-update:unknown ''; do
  UPDATE_TYPE="$update" expect manual_review "noneligible update type requires review: $update"
  [[ ! -s "$ADVISORY_CALLS" ]] || { echo 'FAIL: ineligible semver still queried advisory'; exit 1; }
done
META_GHSA_ID='' PR_BODY='' expect manual_review 'routine update without advisory requires review'
[[ ! -s "$ADVISORY_CALLS" ]] || { echo 'FAIL: routine update queried advisory'; exit 1; }
META_GHSA_ID='' PR_BODY='Security fix: GHSA-2345-6789-cfgh' expect automerge 'body advisory fallback is cross-checked with API'
[[ "$(cat "$ADVISORY_CALLS")" == /advisories/GHSA-2345-6789-cfgh ]] || { echo 'FAIL: body fallback did not query advisory'; exit 1; }
DEP_NAMES='other, EXAMPLE-PKG  ' expect automerge 'comma-separated dependency matching trims and folds case'
DEP_NAMES='other-pkg' expect manual_review 'advisory for a different package does not qualify'
DEP_NAMES='' expect manual_review 'missing dependency metadata fails closed'
API_STATUS=1 expect manual_review 'unavailable advisory API fails closed'
make_advisory low null
expect manual_review 'missing advisory score fails closed'
# Fail-closed means unreadable numeric data cannot qualify for auto-merge.
make_advisory low '"not-a-score"'
expect manual_review 'malformed advisory score fails closed'

# Boundary values must retain numeric typing; text cannot qualify as a score.
make_advisory medium 6.999
expect automerge 'numeric CVSS immediately below 7 remains eligible'
make_advisory low 0
expect automerge 'zero is a numeric CVSS score, not missing metadata'
for score in -1 7.001 10 true '"6.9"' '{}' '[]'; do
  make_advisory low "$score"
  expect manual_review "noneligible CVSS representation requires review: $score"
done
make_advisory low 2
jq 'del(.severity)' "$ADVISORY_JSON" > "$work/changed-advisory.json"
mv "$work/changed-advisory.json" "$ADVISORY_JSON"
expect manual_review 'missing severity cannot inherit a prior eligible decision'
make_advisory low 2
for names in 'example' 'example-pkg-extra' ' , , '; do
  DEP_NAMES="$names" expect manual_review "package matching requires a whole nonempty name: $names"
done
for vulnerabilities in '[]' 'null'; do
  make_advisory low 2
  jq --argjson values "$vulnerabilities" '.vulnerabilities = $values' "$ADVISORY_JSON" > "$work/changed-advisory.json"
  mv "$work/changed-advisory.json" "$ADVISORY_JSON"
  expect manual_review "no affected packages cannot qualify: $vulnerabilities"
done
printf 'dependabot_automerge_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
