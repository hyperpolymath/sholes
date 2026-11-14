#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# workflow_gap_fixes_test.sh — behaviour + negative controls for six inline
# workflow fixes (found by review on hyperpolymath/zig-unorm#6):
#   1 governance     TS verdict is the pinned script's alone
#   2 hypatia-scan   code_scanning_alerts do not count as CRITICAL
#   3 estate-audit   required-files + idris2-abi gates are run
#   4 rust-ci        cargo fmt --check and clippy -D warnings
#   5 rust-secrets   never prints the matched line
#   6 shell-secrets  quoted *_TOKEN/*_KEY/*_SECRET/PASSWORD literals detected
# Each fix has a silence case and a firing (negative-control) case, so the
# test cannot pass vacuously. Needs jq and a yq that accepts `yq -r`.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF="$REPO/.github/workflows"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1" >&2; }
expect() { # <label> <want rc> <got rc>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want rc=$2, got rc=$3)"; fi
}
step() { yq -r ".jobs[\"$2\"].steps[$3].run" "$WF/$1"; } # file job index

# Fake credentials assembled at run time so this file carries none.
TOK="abcdefghij""klmnopqrst""uvwxyz12"
GH="ghp_""$(printf 'A%.0s' $(seq 36))"

echo "== 6 shell-secrets"
step secret-scanner.yml shell-secrets 1 > "$WORK/shell.sh"
run_shell() { # <file content> -> rc
  local d="$WORK/r$RANDOM"; mkdir -p "$d/tmp"; ( cd "$d" && git init -q &&
    printf '%s\n' "$1" > deploy.sh && git add deploy.sh &&
    RUNNER_TEMP="$d/tmp" bash -e -o pipefail "$WORK/shell.sh" >"$d/out" 2>&1 ); local rc=$?
  cp "$d/out" "$WORK/last.out"; return $rc; }
run_shell "export API_TOKEN=\"$TOK\"";           expect "quoted _TOKEN literal blocks" 1 $?
run_shell "DB_PASSWORD='hunter2hunter2'";        expect "quoted PASSWORD literal blocks" 1 $?
run_shell "MY_SECRET=\"$TOK\"";                  expect "quoted _SECRET literal blocks" 1 $?
run_shell "export X=\"$GH\"";                    expect "provider pattern still blocks" 1 $?
run_shell 'API_TOKEN="${API_TOKEN}"';            expect "param expansion is not flagged" 0 $?
run_shell 'API_TOKEN="$(cat /run/secrets/t)"';   expect "command substitution is not flagged" 0 $?
run_shell 'echo hello';                          expect "clean file passes" 0 $?

echo "== 5 rust-secrets (no leak)"
step secret-scanner.yml rust-secrets 1 > "$WORK/rust.sh"
run_rust() { # <today> <path> -> rc
  local d="$WORK/q$RANDOM"; mkdir -p "$d/$(dirname "$2")"
  printf 'const AUTH_TOKEN: &str = "%s";\n' "$TOK" > "$d/$2"; : > "$d/Cargo.toml"
  ( cd "$d" && ENFORCE_RUST_WIDE_SCAN_FROM=2026-08-21 RUST_TODAY="$1" \
      bash -e -o pipefail "$WORK/rust.sh" >"$d/out" 2>&1 ); local rc=$?
  cp "$d/out" "$WORK/last.out"; return $rc; }
run_rust 2026-11-12 src/main.rs;      expect "./src hit still blocks" 1 $?
if grep -q "$TOK" "$WORK/last.out"; then bad "blocking output leaks the secret"; else ok "blocking output has no secret text"; fi
grep -q 'src/main.rs:1' "$WORK/last.out" && ok "file:line still reported" || bad "file:line missing"
run_rust 2026-11-12 crates/a/lib.rs;  expect "outside-src hit blocks after cutoff" 1 $?
if grep -q "$TOK" "$WORK/last.out"; then bad "wide-scan output leaks the secret"; else ok "wide-scan output has no secret text"; fi
run_rust 2026-01-01 crates/a/lib.rs;  expect "outside-src hit warns before cutoff" 0 $?
if grep -q "$TOK" "$WORK/last.out"; then bad "advisory output leaks the secret"; else ok "advisory output has no secret text"; fi

echo "== 2 hypatia CRITICAL count"
expr="$(grep -m1 -F 'CRITICAL="$(jq' "$WF/hypatia-scan.yml" | sed -E "s/^.*jq '(.*)' hypatia-findings.json.*$/\1/")"
[ -n "$expr" ] || bad "could not extract CRITICAL jq expression"
cat > "$WORK/f.json" <<'J'
[{"severity":"critical","rule_module":"code_scanning_alerts"},
 {"severity":"critical","rule_module":"code_scanning_alerts"},
 {"severity":"high","rule_module":"workflow_audit"}]
J
[ "$(jq "$expr" "$WORK/f.json")" = 0 ] && ok "historical alerts do not block" || bad "historical alerts counted"
jq '. + [{"severity":"critical","rule_module":"workflow_audit"}]' "$WORK/f.json" > "$WORK/g.json"
[ "$(jq "$expr" "$WORK/g.json")" = 1 ] && ok "a real critical still blocks" || bad "real critical not counted"
grep -q 'hypatia-findings.json' "$WF/hypatia-scan.yml" && ok "artifact still carries all findings" || bad "artifact path lost"

echo "== 1 governance TS verdict"
if grep -q 'bad_ts' "$WF/governance.yml"; then bad "second inline TS filter still present"; else ok "no inline TS filter"; fi
if grep -qE '^[[:space:]]*bash \.standards-checkout/scripts/check-ts-allowlist\.sh' "$WF/governance.yml" \
   && ! grep -qE 'if \[ -f \.standards-checkout/scripts/check-ts-allowlist\.sh' "$WF/governance.yml"; then
  ok "pinned script runs unconditionally"; else bad "pinned script skippable or missing"; fi

echo "== 3 estate audit gates"
for g in required-files-check idris2-abi-check; do
  grep -q "$g" "$WF/main-estate-audit.yml" && ok "$g present" || bad "$g missing"
done
grep -q 'yq -r' "$WF/main-estate-audit.yml" && ok "runs pinned action.yml script" || bad "no pinned-script runner"

echo "== 4 rust-ci"
grep -qF 'cargo fmt --all -- --check' "$WF/rust-ci.yml" && ok "fmt check" || bad "fmt check missing"
grep -qF 'cargo clippy --locked --all-targets -- -D warnings' "$WF/rust-ci.yml" && ok "clippy -D warnings" || bad "clippy missing"
grep -qF 'rustup component add rustfmt clippy' "$WF/rust-ci.yml" && ok "components ensured" || bad "components not ensured"

echo; [ "$fail" -eq 0 ] && { echo "PASS: workflow gap fixes ($pass checks)"; exit 0; }
echo "FAIL: workflow gap fixes ($pass passed, $fail failed)" >&2; exit 1
