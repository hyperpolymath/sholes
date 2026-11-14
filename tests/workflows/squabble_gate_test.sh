#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing + Setup-error test suite for:
#   - .github/actions/squabble/{action.yml,install.sh,run.sh}
#   - scripts/check-required-contexts.sh
#
# Proves offline that tampered downloads, forged attestations, non-zero squabble
# exits, phantom ruleset contexts, path-filtered required workflows, and
# `gh pr merge --admin` bypasses all fail loudly with the expected exit code.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }

assert_rc() { # assert_rc <want> <label> <cmd...>
  local want="$1" label="$2" got=0
  shift 2
  "$@" >"$WORK/out" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    ok "$label"
  else
    bad "$label (wanted exit $want, got $got)"
    sed 's/^/        /' "$WORK/out"
  fi
}

echo "=== 1. squabble install.sh & run.sh guards ==="
# Source install.sh without running main
# shellcheck source=../../.github/actions/squabble/install.sh
source "$REPO_ROOT/.github/actions/squabble/install.sh"

printf 'tampered binary bytes' > "$WORK/bad-bin"
if verify_digest "$WORK/bad-bin" >"$WORK/out" 2>&1; then
  bad "Firing: tampered sha256 must fail verify_digest"
else
  ok "Firing: tampered sha256 rejected by verify_digest"
fi

printf '[]\n' > "$WORK/empty-att.json"
if check_attestation_json "$WORK/empty-att.json" >"$WORK/out" 2>&1; then
  bad "Firing: empty attestation array must fail check_attestation_json"
else
  ok "Firing: empty attestation array rejected by check_attestation_json"
fi

cat > "$WORK/good-att.json" <<JSON
[{"verificationResult":{"statement":{"subject":[{"name":"$SQUABBLE_ASSET","digest":{"sha256":"$SQUABBLE_SHA256"}}]}}}]
JSON
if check_attestation_json "$WORK/good-att.json" >"$WORK/out" 2>&1; then
  ok "Silence: matching SLSA subject digest accepted by check_attestation_json"
else
  bad "Silence: matching SLSA subject digest rejected"
fi

cat > "$WORK/wrong-att.json" <<JSON
[{"verificationResult":{"statement":{"subject":[{"name":"$SQUABBLE_ASSET","digest":{"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}}]}}}]
JSON
if check_attestation_json "$WORK/wrong-att.json" >"$WORK/out" 2>&1; then
  bad "Firing: mismatched SLSA subject digest must fail"
else
  ok "Firing: mismatched SLSA subject digest rejected"
fi

cat > "$WORK/standin-squabble" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--Blocking" ]; then exit 4; fi
printf 'args:%s\n' "$*"
exit 0
SH
chmod +x "$WORK/standin-squabble"

OUT_FILE="$WORK/gh-out"
: > "$OUT_FILE"
assert_rc 0 "Silence: run.sh propagates exit 0 and literal args" \
  env GITHUB_OUTPUT="$OUT_FILE" SQUABBLE_BIN="$WORK/standin-squabble" SQUABBLE_ARGS=$'chains\n.=' \
  bash "$REPO_ROOT/.github/actions/squabble/run.sh"
if grep -q '^exit-code=0$' "$OUT_FILE"; then
  ok "Silence: run.sh writes exit-code=0 to GITHUB_OUTPUT"
else
  bad "Silence: run.sh missing exit-code=0"
fi

: > "$OUT_FILE"
assert_rc 4 "Firing: run.sh propagates blocking exit 4 (dead upstream / cycle)" \
  env GITHUB_OUTPUT="$OUT_FILE" SQUABBLE_BIN="$WORK/standin-squabble" SQUABBLE_ARGS="--Blocking" \
  bash "$REPO_ROOT/.github/actions/squabble/run.sh"
if grep -q '^exit-code=4$' "$OUT_FILE"; then
  ok "Firing: run.sh writes exit-code=4 to GITHUB_OUTPUT"
else
  bad "Firing: run.sh missing exit-code=4"
fi

echo "=== 2. check-required-contexts.sh: Silence, Firing, Setup (0 / 1 / 2) ==="
assert_rc 0 "Silence: live repository required contexts pass" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$REPO_ROOT"

assert_rc 2 "Setup (exit 2): missing repo directory exits 2" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/does-not-exist"

# Mutant A: phantom workflow file
mkdir -p "$WORK/m_phantom/.github/workflows" "$WORK/m_phantom/.machine_readable"
printf 'scan / gitleaks => .github/workflows/missing.yml\n' > "$WORK/m_phantom/.machine_readable/required-contexts-allow.txt"
assert_rc 1 "Firing: missing producer workflow exits 1" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_phantom"

# Mutant B: path-filtered required workflow (strands PRs!)
mkdir -p "$WORK/m_paths/.github/workflows" "$WORK/m_paths/.machine_readable"
printf 'scan / gitleaks => .github/workflows/secret-scanner.yml\n' > "$WORK/m_paths/.machine_readable/required-contexts-allow.txt"
cat > "$WORK/m_paths/.github/workflows/secret-scanner.yml" <<'YML'
name: Secret Scanner
on:
  pull_request:
    paths:
      - 'src/**'
jobs:
  scan:
    name: scan / gitleaks
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
assert_rc 1 "Firing: path-filtered required workflow exits 1" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_paths"

# Mutant C: unmapped ruleset context
mkdir -p "$WORK/m_ruleset/.github/workflows" "$WORK/m_ruleset/.github/rulesets" "$WORK/m_ruleset/.machine_readable"
printf 'scan / gitleaks => .github/workflows/secret-scanner.yml\n' > "$WORK/m_ruleset/.machine_readable/required-contexts-allow.txt"
cat > "$WORK/m_ruleset/.github/workflows/secret-scanner.yml" <<'YML'
name: Secret Scanner
on:
  pull_request:
jobs:
  scan:
    name: scan / gitleaks
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
cat > "$WORK/m_ruleset/.github/rulesets/extra.json" <<'JSON'
{"rules":[{"parameters":{"required_status_checks":[{"context":"phantom / coverage"}]},"type":"required_status_checks"}]}
JSON
assert_rc 1 "Firing: unmapped ruleset required_status_checks context exits 1" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_ruleset"

# Mutant D: admin merge bypass in workflow
mkdir -p "$WORK/m_admin/.github/workflows" "$WORK/m_admin/.machine_readable"
printf 'scan / gitleaks => .github/workflows/secret-scanner.yml\n' > "$WORK/m_admin/.machine_readable/required-contexts-allow.txt"
cp "$WORK/m_ruleset/.github/workflows/secret-scanner.yml" "$WORK/m_admin/.github/workflows/secret-scanner.yml"
ADMIN_FLAG="--""admin"
cat > "$WORK/m_admin/.github/workflows/bad-merge.yml" <<YML
name: Bad Automerge
on:
  pull_request:
jobs:
  merge:
    runs-on: ubuntu-latest
    steps:
      - run: gh pr merge 1 --squash $ADMIN_FLAG
YML
assert_rc 1 "Firing: 'gh pr merge --admin' bypass in workflow exits 1" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_admin"

# Mutant E: multi-line backslash-continued admin bypass + array `on:` form
mkdir -p "$WORK/m_multiline/.github/workflows" "$WORK/m_multiline/.machine_readable"
printf 'scan / gitleaks => .github/workflows/secret-scanner.yml\n' > "$WORK/m_multiline/.machine_readable/required-contexts-allow.txt"
cat > "$WORK/m_multiline/.github/workflows/secret-scanner.yml" <<'YML'
name: Secret Scanner
on: [push, pull_request]
jobs:
  scan:
    name: scan / gitleaks
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
assert_rc 0 "Silence: array-form 'on: [push, pull_request]' accepted" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_multiline"

cat > "$WORK/m_multiline/.github/workflows/sneaky-merge.yml" <<YML
name: Sneaky Automerge
on: pull_request
jobs:
  merge:
    runs-on: ubuntu-latest
    steps:
      - run: |
          gh pr merge 1 --squash \\
            $ADMIN_FLAG
YML
assert_rc 1 "Firing: backslash-continued 'gh pr merge ... --admin' exits 1" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_multiline"

echo "=== 3. Attestations require every result and every matching subject ==="
guard_case() { # <success|failure> <label> <function> [args...]
  local want="$1" label="$2" got=success
  shift 2
  "$@" > "$WORK/out" 2>&1 || got=failure
  if [ "$want" = "$got" ]; then ok "$label"; else bad "$label ($got)"; fi
}
guard_case failure 'missing binary cannot pass digest verification' verify_digest "$WORK/missing-bin"
for json in '{}' 'null' '[{}]' '{bad}'; do
  printf '%s\n' "$json" > "$WORK/attestation.json"
  guard_case failure "invalid attestation shape is refused: $json" check_attestation_json "$WORK/attestation.json"
done
jq '.[0].verificationResult.statement.subject += [{name:"SHA256SUMS",digest:{sha256:"unrelated"}}]' \
  "$WORK/good-att.json" > "$WORK/attestation.json"
guard_case success 'additional unrelated subjects do not invalidate the matching asset' check_attestation_json "$WORK/attestation.json"
jq '.[0].verificationResult.statement.subject[0].name = "wrong-asset"' "$WORK/good-att.json" > "$WORK/attestation.json"
guard_case failure 'correct digest for the wrong asset is refused' check_attestation_json "$WORK/attestation.json"
jq -s 'add' "$WORK/good-att.json" "$WORK/empty-att.json" > "$WORK/attestation.json"
guard_case success 'nonempty valid verification result is accepted' check_attestation_json "$WORK/attestation.json"
jq -s 'add' "$WORK/good-att.json" "$WORK/wrong-att.json" > "$WORK/attestation.json"
guard_case failure 'one valid result cannot conceal a second bad result' check_attestation_json "$WORK/attestation.json"
jq '.[0].verificationResult.statement.subject += [{name:.[0].verificationResult.statement.subject[0].name,digest:{sha256:"wrong"}}]' \
  "$WORK/good-att.json" > "$WORK/attestation.json"
guard_case failure 'conflicting digests for the same asset are refused' check_attestation_json "$WORK/attestation.json"

# Replace only the gh process boundary; exercise the real verification wrapper.
verify_fixture_attestation() {
  (
    # shellcheck disable=SC2329 # Called indirectly by verify_attestation.
    gh() {
      printf '%s\n' "$@" > "$WORK/gh-args"
      cat "$WORK/good-att.json"
      return "${GH_VERIFY_STATUS:-0}"
    }
    verify_attestation "$@"
  )
}
guard_case success 'verified provenance wrapper accepts valid JSON' verify_fixture_attestation "$WORK/asset with spaces"
printf '%s\n' attestation verify "$WORK/asset with spaces" \
  --repo "$SQUABBLE_REPO" --signer-workflow "$SQUABBLE_SIGNER_WORKFLOW" \
  --source-ref "refs/tags/$SQUABBLE_TAG" --source-digest "$SQUABBLE_SOURCE_DIGEST" \
  --predicate-type https://slsa.dev/provenance/v1 --deny-self-hosted-runners --format json > "$WORK/expected-gh-args"
assert_rc 0 'attestation verifies the pinned source, signer, tag, and hosted runner' cmp "$WORK/expected-gh-args" "$WORK/gh-args"
GH_VERIFY_STATUS=42 guard_case failure 'a rejected gh verification cannot be rescued by valid stdout' verify_fixture_attestation "$WORK/asset"
platform_case() {
  # shellcheck disable=SC2329 # Called indirectly by require_platform.
  (uname() { case "$1" in -s) echo "$TEST_OS";; -m) echo "$TEST_ARCH";; esac; }; require_platform)
}
TEST_OS=Linux TEST_ARCH=x86_64 assert_rc 0 'Linux x86_64 platform is supported' platform_case
TEST_OS=Darwin TEST_ARCH=x86_64 assert_rc 1 'non-Linux runners are refused' platform_case
TEST_OS=Linux TEST_ARCH=aarch64 assert_rc 1 'non-x86_64 runners are refused' platform_case

echo "=== 4. Literal argv and optional runner outputs ==="
cat > "$WORK/argv-squabble" <<'SH'
#!/usr/bin/env bash
: > "$ARGV_CAPTURE"
if [ "$#" -gt 0 ]; then printf '%s\0' "$@" > "$ARGV_CAPTURE"; fi
exit "${SQUABBLE_STATUS:-0}"
SH
chmod +x "$WORK/argv-squabble"
export ARGV_CAPTURE="$WORK/argv"
literal="\$(touch '$WORK/PWNED'); * \$HOME \`id\`"
printf '%s\0' chains 'repo with spaces' '  leading and trailing  ' "$literal" > "$WORK/expected-argv"
printf 'existing=value\n' > "$OUT_FILE"
assert_rc 0 'blank lines drop while spaces and metacharacters remain literal' \
  env GITHUB_OUTPUT="$OUT_FILE" SQUABBLE_BIN="$WORK/argv-squabble" \
  SQUABBLE_ARGS=$'\nchains\n\nrepo with spaces\n  leading and trailing  \n'"$literal"$'\n' \
  bash "$REPO_ROOT/.github/actions/squabble/run.sh"
assert_rc 0 'argv boundaries are preserved byte for byte' cmp "$WORK/expected-argv" "$ARGV_CAPTURE"
assert_rc 0 'shell expressions in arguments are never executed' test ! -e "$WORK/PWNED"
printf 'existing=value\nexit-code=0\n' > "$WORK/expected-output"
assert_rc 0 'GITHUB_OUTPUT is appended, preserving existing outputs' cmp "$WORK/expected-output" "$OUT_FILE"
assert_rc 7 'absence of GITHUB_OUTPUT still propagates the binary exit' \
  env -u GITHUB_OUTPUT SQUABBLE_STATUS=7 SQUABBLE_BIN="$WORK/argv-squabble" SQUABBLE_ARGS='' \
  bash "$REPO_ROOT/.github/actions/squabble/run.sh"
assert_rc 0 'empty SQUABBLE_ARGS yields zero arguments' test ! -s "$ARGV_CAPTURE"
assert_rc 1 'missing executable is refused before invocation' \
  env SQUABBLE_BIN="$WORK/missing-binary" bash "$REPO_ROOT/.github/actions/squabble/run.sh"

echo "=== 5. Required context setup and trigger boundaries ==="
context_tree="$WORK/context-boundaries"
fresh_context() {
  rm -rf "$context_tree"
  mkdir -p "$context_tree/.github/workflows" "$context_tree/.machine_readable"
  printf '# mapping\r\n\r\n scan / gitleaks => .github/workflows/scan.yaml \r\n' > "$context_tree/.machine_readable/required-contexts-allow.txt"
  printf 'name: Scan\non: pull_request\njobs:\n  gitleaks:\n    name: scan / gitleaks\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
}
fresh_context
assert_rc 0 'scalar PR event, yaml extension, comments, CRLF, and whitespace are accepted' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
sed -i 's|name: scan / gitleaks|name: scan / renamed|' "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a renamed job no longer produces the required context' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs: {}\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a PR-triggered workflow with no jobs produces no context' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs:\n  gitleaks:\n    name: scan / gitleaks\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a job with neither runs-on nor uses produces no context' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
# A job that calls a reusable workflow produces `<caller> / <called job>`,
# never its own name alone; a remote reusable cannot be certified from here.
printf 'name: Inner\non: workflow_call\njobs:\n  g:\n    name: gitleaks\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/inner.yaml"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    uses: ./.github/workflows/inner.yaml\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 0 'a local reusable produces <caller> / <called job>' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    name: scan / gitleaks\n    uses: ./.github/workflows/inner.yaml\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a reusable caller named like the context does not produce it' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    name: scan / gitleaks\n    uses: example/repo/.github/workflows/inner.yaml@0123456789012345678901234567890123456789\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a remote reusable produces nothing the gate can certify' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
# GitHub names matrix runs `name (v1, v2)`, or evaluates a name that refers to
# the matrix; anything the gate cannot expand statically is refused, by name.
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    name: scan\n    strategy: {matrix: {tool: [gitleaks, trufflehog]}}\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
printf 'scan (gitleaks) => .github/workflows/scan.yaml\n' > "$context_tree/.machine_readable/required-contexts-allow.txt"
assert_rc 0 'a literal matrix names its runs `name (value)`' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    name: scan / ${{ matrix.tool }}\n    strategy: {matrix: {tool: [gitleaks]}}\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
printf 'scan / gitleaks => .github/workflows/scan.yaml\n' > "$context_tree/.machine_readable/required-contexts-allow.txt"
assert_rc 0 'a name that refers to the matrix is evaluated per run' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    name: scan / ${{ matrix.tool }}\n    strategy: {matrix: {tool: [gitleaks], include: [{tool: trufflehog}]}}\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a matrix with include is refused, not guessed' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
cp "$WORK/out" "$WORK/refusal"
assert_rc 0 'the include refusal names the job and says why' grep -q "not resolvable statically.*scan / \${{ matrix.tool }}" "$WORK/refusal"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    name: scan / ${{ matrix.tool }}\n    strategy:\n      matrix: ${{ fromJSON(vars.TOOLS) }}\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a computed matrix is refused, not guessed' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
cp "$WORK/out" "$WORK/refusal"
assert_rc 0 'the computed-matrix refusal names the job and says why' grep -q "not resolvable statically.*scan / \${{ matrix.tool }}" "$WORK/refusal"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    name: scan / ${{ matrix.tool }}\n    strategy: {matrix: {TOOL: [gitleaks]}}\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 0 'matrix property names match case-insensitively' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    name: scan / ${{ matrix.tool }}\n    strategy: {matrix: {TOOL: [gitleaks], tool: [trufflehog]}}\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'keys differing only in case are refused as ambiguous' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    name: scan / ${{ matrix.1tool }}\n    strategy: {matrix: {1tool: [gitleaks]}}\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a dereference GitHub rejects (matrix.1tool) is refused' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
# A called file counts only when it declares on: workflow_call; GitHub nests
# at most ten workflows (the caller and nine reusables); a cycle is refused.
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    uses: ./.github/workflows/inner.yaml\n' > "$context_tree/.github/workflows/scan.yaml"
printf 'name: Inner\non: push\njobs:\n  g:\n    name: gitleaks\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/inner.yaml"
assert_rc 1 'a called file without on: workflow_call produces nothing' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
chain_tree() { # <reusables>: scan.yaml calls r1 ... rN; the last runs job gitleaks
    local n=$1 i ctx=scan
    printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    uses: ./.github/workflows/r1.yaml\n' > "$context_tree/.github/workflows/scan.yaml"
    for ((i = 1; i < n; i++)); do
        printf 'name: R\non: workflow_call\njobs:\n  l%d:\n    uses: ./.github/workflows/r%d.yaml\n' "$i" "$((i + 1))" > "$context_tree/.github/workflows/r$i.yaml"
        ctx="$ctx / l$i"
    done
    printf 'name: R\non: workflow_call\njobs:\n  g:\n    name: gitleaks\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/r$n.yaml"
    printf '%s / gitleaks => .github/workflows/scan.yaml\n' "$ctx" > "$context_tree/.machine_readable/required-contexts-allow.txt"
}
chain_tree 9
assert_rc 0 'nine nested reusables (ten workflows) resolve' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
chain_tree 10
assert_rc 1 'a tenth nested reusable exceeds GitHub'"'"'s limit' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
rm -f "$context_tree"/.github/workflows/r*.yaml
printf 'name: Scan\non: [pull_request, workflow_call]\njobs:\n  scan:\n    uses: ./.github/workflows/scan.yaml\n' > "$context_tree/.github/workflows/scan.yaml"
printf 'scan / scan => .github/workflows/scan.yaml\n' > "$context_tree/.machine_readable/required-contexts-allow.txt"
assert_rc 1 'a workflow calling itself is refused, not followed' timeout 20 bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Inner\non: workflow_call\njobs:\n  g:\n    name: gitleaks\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/inner.yaml"
printf 'scan / gitleaks => .github/workflows/scan.yaml\n' > "$context_tree/.machine_readable/required-contexts-allow.txt"
# `$/.github/workflows/…` is GitHub's recommended same-repository form, and a
# caller with a literal matrix produces `<caller run> / <called job>`.
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    uses: $/.github/workflows/inner.yaml\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 0 'a $/ same-repository call resolves like ./' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    uses: $/.github/workflows/inner.yaml@v1\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a $/ call with an @ref (which GitHub forbids) produces nothing' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    strategy: {matrix: {target: [dev, prod]}}\n    uses: ./.github/workflows/inner.yaml\n' > "$context_tree/.github/workflows/scan.yaml"
printf 'scan (prod) / gitleaks => .github/workflows/scan.yaml\n' > "$context_tree/.machine_readable/required-contexts-allow.txt"
assert_rc 0 'a matrix caller produces <caller run> / <called job>' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
# GitHub runs only files directly in .github/workflows/: a subdirectory or a
# traversal is not a reusable workflow, whatever file it reaches.
mkdir -p "$context_tree/.github/workflows/sub"
cp "$context_tree/.github/workflows/inner.yaml" "$context_tree/.github/workflows/sub/inner.yaml"
printf 'scan / gitleaks => .github/workflows/scan.yaml\n' > "$context_tree/.machine_readable/required-contexts-allow.txt"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    uses: ./.github/workflows/sub/inner.yaml\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a reusable in a subdirectory of .github/workflows produces nothing' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non: pull_request\njobs:\n  scan:\n    uses: ./.github/workflows/sub/../inner.yaml\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'a traversal in a reusable path produces nothing' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
rm -r "$context_tree/.github/workflows/sub"
printf 'scan / gitleaks => .github/workflows/scan.yaml\n' > "$context_tree/.machine_readable/required-contexts-allow.txt"
rm "$context_tree/.github/workflows/inner.yaml"
printf 'name: Scan\non: pull_request_target\njobs:\n  gitleaks:\n    name: scan / gitleaks\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'pull_request_target alone cannot produce a required PR check' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
printf 'name: Scan\non:\n  pull_request:\n    paths-ignore: []\njobs:\n  gitleaks:\n    name: scan / gitleaks\n    runs-on: ubuntu-latest\n    steps: [{run: echo hi}]\n' > "$context_tree/.github/workflows/scan.yaml"
assert_rc 1 'paths-ignore is forbidden even when empty' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
for mapping in '# only comments' 'missing separator' ' => .github/workflows/scan.yaml' \
  'scan / gitleaks =>' 'scan => file => another'; do
  printf '%s\n' "$mapping" > "$context_tree/.machine_readable/required-contexts-allow.txt"
  assert_rc 2 "empty or malformed mapping is setup failure: $mapping" bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
done
fresh_context
rm "$context_tree/.machine_readable/required-contexts-allow.txt"
assert_rc 2 'missing mapping is setup failure' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"
fresh_context
rm -rf "$context_tree/.github/workflows"
assert_rc 2 'missing workflow directory is setup failure' bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$context_tree"

echo "=== 6. Installer verification order and publication boundaries (offline) ==="
# Exercise main in a fresh Bash process so errexit is active even though
# assert_rc captures failures. Only process boundaries are doubled; the real
# digest/attestation guards and installation code still run. The synthetic
# digest lets a harmless local executable stand in for the pinned release;
# real hashing of tampered bytes is covered above.
cat > "$WORK/install-driver" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$INSTALL_SCRIPT"
export SQUABBLE_TEST_VERSION="squabble ${SQUABBLE_TAG#v}"
uname() { case "$1" in -s) echo Linux;; -m) echo x86_64;; esac; }
gh() {
  case "$1 $2" in
    'release download')
      printf 'download\n' >> "$INSTALL_TRACE"
      [[ "$3" == "$SQUABBLE_TAG" && "$4" == --repo && "$5" == "$SQUABBLE_REPO" \
        && "$6" == --pattern && "$7" == "$SQUABBLE_ASSET" && "$8" == --dir && "$#" == 9 ]] || return 99
      [[ "$INSTALL_CASE" != download-failed ]] || return 8
      mkdir -p "$9"
      cat > "$9/$SQUABBLE_ASSET" <<'BIN'
#!/usr/bin/env bash
[[ "$#" == 1 && "$1" == --version ]] || exit 99
printf 'execute\n' >> "$INSTALL_TRACE"
[[ "$INSTALL_CASE" != binary-failed ]] || exit 9
if [[ "$INSTALL_CASE" == wrong-version ]]; then echo 'squabble invalid-test-version'; else printf '%s\n' "$SQUABBLE_TEST_VERSION"; fi
BIN
      chmod 0644 "$9/$SQUABBLE_ASSET"
      ;;
    'attestation verify')
      [[ -f "$3" && ! -x "$3" ]] || return 99
      printf 'attestation\n' >> "$INSTALL_TRACE"
      if [[ "$INSTALL_CASE" == attestation-failed ]]; then return 42; fi
      if [[ "$INSTALL_CASE" == empty-attestation ]]; then printf '[]\n'; else cat "$INSTALL_ATTESTATION"; fi
      ;;
    *) return 99 ;;
  esac
}
sha256sum() {
  [[ "$#" == 2 && "$1" == -- && -f "$2" && ! -x "$2" ]] || return 99
  printf 'digest\n' >> "$INSTALL_TRACE"
  if [[ "$INSTALL_CASE" == bad-digest ]]; then printf 'wrong  %s\n' "$2";
  else printf '%s  %s\n' "$SQUABBLE_SHA256" "$2"; fi
}
main
SH
export INSTALL_SCRIPT="$REPO_ROOT/.github/actions/squabble/install.sh" \
  INSTALL_ATTESTATION="$WORK/good-att.json" INSTALL_TRACE="$WORK/install-trace"
install_case() { # <exit> <case> <expected verification trace>
  local want="$1" scenario="$2" trace="$3"
  mkdir -p "$WORK/runner temp/$scenario"
  printf 'existing-output=value\n' > "$WORK/install-output"
  printf 'existing-path\n' > "$WORK/install-path"
  : > "$INSTALL_TRACE"
  assert_rc "$want" "installer: $scenario" env INSTALL_CASE="$scenario" \
    RUNNER_TEMP="$WORK/runner temp/$scenario" GITHUB_OUTPUT="$WORK/install-output" \
    GITHUB_PATH="$WORK/install-path" bash "$WORK/install-driver"
  printf '%s' "$trace" > "$WORK/expected-trace"
  assert_rc 0 "installer: $scenario runs only the permitted verification stages" \
    cmp "$WORK/expected-trace" "$INSTALL_TRACE"
  if [[ "$want" != 0 ]]; then
    printf 'existing-output=value\n' > "$WORK/expected-install-output"
    printf 'existing-path\n' > "$WORK/expected-install-path"
    assert_rc 0 "installer: $scenario publishes no executable output" \
      cmp "$WORK/expected-install-output" "$WORK/install-output"
    assert_rc 0 "installer: $scenario publishes no PATH entry" \
      cmp "$WORK/expected-install-path" "$WORK/install-path"
  fi
}
install_case 0 verified $'download\ndigest\nattestation\nexecute\n'
installed_bin=$(sed -n 's/^path=//p' "$WORK/install-output")
assert_rc 0 'verified binary is executable at the published path, including spaces' test -x "$installed_bin"
printf 'existing-output=value\npath=%s\n' "$installed_bin" > "$WORK/expected-install-output"
assert_rc 0 'installation appends its output without discarding other step outputs' \
  cmp "$WORK/expected-install-output" "$WORK/install-output"
printf 'existing-path\n%s\n' "${installed_bin%/*}" > "$WORK/expected-install-path"
assert_rc 0 'installation publishes the verified binary directory' cmp "$WORK/expected-install-path" "$WORK/install-path"
install_case 8 download-failed $'download\n'
install_case 1 bad-digest $'download\ndigest\n'
install_case 1 attestation-failed $'download\ndigest\nattestation\n'
install_case 1 empty-attestation $'download\ndigest\nattestation\n'
install_case 1 wrong-version $'download\ndigest\nattestation\nexecute\n'
install_case 9 binary-failed $'download\ndigest\nattestation\nexecute\n'

assert_rc 0 'Dependabot severity and semver policy controls' bash "$REPO_ROOT/tests/workflows/dependabot_automerge_test.sh"
echo "squabble_gate_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
