#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing + Setup-error test suite for scripts/check-ijson-jcs.sh
# (proven-tests-and-benches TEST-DOCTRINE 3-outcome contract).
#
# Proves check-ijson-jcs.sh CAN FAIL and classifies each input for the right
# reason across .json and .jsonl: canonical (exit 0), non-canonical (exit 1
# under --enforce), invalid RFC 7493 I-JSON including duplicate keys, unsafe
# integers > 2^53-1, lone surrogates, and Unicode noncharacters (INVALID,
# exit 1 under --enforce), JSONC carve-outs skipped, and setup errors (exit 2).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_DIR/scripts/check-ijson-jcs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

expect() { # expect <wanted-exit> <label> [checker flags...]
  local want="$1" label="$2" got=0
  shift 2
  (cd "$WORK" && bash "$SCRIPT" "$@" t) >"$WORK/out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    echo "  PASS: $label"
  else
    fail=$((fail + 1))
    echo "  FAIL: $label (wanted exit $want, got $got)"
    sed 's/^/        /' "$WORK/out"
  fi
}

fresh() {
  rm -rf "$WORK/t"
  mkdir -p "$WORK/t"
}

names() { # names <fixed-string> <label>
  if grep -qF -- "$1" "$WORK/out"; then
    pass=$((pass + 1))
    echo "  PASS: $2"
  else
    fail=$((fail + 1))
    echo "  FAIL: $2"
    sed 's/^/        /' "$WORK/out"
  fi
}

echo "=== Silence & Firing: .json ==="
fresh; printf '{"a":1,"b":[true,null]}\n' > "$WORK/t/a.json"
expect 0 "Silence: canonical .json passes --enforce" --enforce
names "1 canonical, 0 not canonical, 0 invalid" "Silence: counted canonical"

fresh; printf '{"b":1,"a":2}\n' > "$WORK/t/a.json"
expect 0 "Report-only: unsorted .json exits 0"
names "NOT CANONICAL t/a.json" "Firing: report names unsorted file"
expect 1 "Firing: unsorted .json fails --enforce" --enforce

fresh; printf '{\n  "a": 1\n}\n' > "$WORK/t/a.json"
expect 1 "Firing: pretty-printed .json fails --enforce" --enforce

fresh; printf '{"a":1}' > "$WORK/t/a.json"
expect 1 "Firing: .json without trailing newline fails --enforce" --enforce
names "NOT CANONICAL t/a.json" "Firing: missing newline classed non-canonical"

fresh; printf '{"a":1}\n\n' > "$WORK/t/a.json"
expect 1 "Firing: .json with double trailing newline fails --enforce" --enforce

fresh; printf '{"a":1,"a":2}\n' > "$WORK/t/a.json"
expect 1 "Firing (RFC 7493): duplicate-key .json fails --enforce" --enforce
names "INVALID t/a.json" "Firing: duplicate key classed INVALID"

fresh; printf '{"n":9007199254740992}\n' > "$WORK/t/a.json"
expect 1 "Firing (RFC 7493): integer > 2^53-1 fails --enforce" --enforce
names "INVALID t/a.json" "Firing: unsafe integer classed INVALID"

fresh; printf '{"s":"\\ud800"}\n' > "$WORK/t/a.json"
expect 1 "Firing (RFC 7493): lone UTF-16 surrogate fails --enforce" --enforce
names "INVALID t/a.json" "Firing: lone surrogate classed INVALID"

fresh; printf '{"s":"\\ufffe"}\n' > "$WORK/t/a.json"
expect 1 "Firing (RFC 7493): Unicode noncharacter U+FFFE fails --enforce" --enforce
names "INVALID t/a.json" "Firing: noncharacter classed INVALID"

echo "=== Silence & Firing: .jsonl ==="
fresh; printf '{"a":1}\n{"b":[1,2]}\n' > "$WORK/t/a.jsonl"
expect 0 "Silence: canonical .jsonl passes --enforce" --enforce
names "1 canonical" "Silence: .jsonl counted canonical"

fresh; printf '{"a":1}\n{"z":1,"b":2}\n' > "$WORK/t/a.jsonl"
expect 1 "Firing: .jsonl with unsorted second line fails --enforce" --enforce
names "NOT CANONICAL t/a.jsonl" "Firing: report names .jsonl"

fresh; printf '{"a":1}\n\n{"b":2}\n' > "$WORK/t/a.jsonl"
expect 1 "Firing: .jsonl with blank line fails --enforce" --enforce
names "INVALID t/a.jsonl" "Firing: blank line classed INVALID"

echo "=== Scope & JSONC carve-out ==="
fresh; mkdir -p "$WORK/t/.devcontainer" "$WORK/t/.vscode"
printf '// SPDX-License-Identifier: MPL-2.0\n{ "name": "x" }\n' > "$WORK/t/.devcontainer/devcontainer.json"
printf '// comment\n{ "b": 1, "a": 2 }\n' > "$WORK/t/.vscode/settings.json"
expect 0 "Silence: tool-demanded JSONC skipped under --enforce" --enforce
names "2 JSONC carve-out(s) skipped" "Silence: JSONC skips counted explicitly"

echo "=== Setup / cannot-look outcomes (exit 2) ==="
fresh
got=0; bash "$SCRIPT" "$WORK/does-not-exist" >"$WORK/out" 2>&1 || got=$?
if [ "$got" = 2 ]; then pass=$((pass + 1)); echo "  PASS: missing path exits 2"
else fail=$((fail + 1)); echo "  FAIL: missing path exits 2 (got $got)"; fi

got=0; IJSON_JCS=ijson-jcs-not-installed bash "$SCRIPT" "$WORK/t" >"$WORK/out" 2>&1 || got=$?
if [ "$got" = 2 ]; then pass=$((pass + 1)); echo "  PASS: missing explicit IJSON_JCS binary exits 2"
else fail=$((fail + 1)); echo "  FAIL: missing explicit IJSON_JCS binary exits 2 (got $got)"; fi

got=0; IJSON_JCS=ijson-jcs-not-installed IJSON_JCS_FORCE_JS=1 bash "$SCRIPT" "$WORK/t" >"$WORK/out" 2>&1 || got=$?
if [ "$got" = 2 ]; then pass=$((pass + 1)); echo "  PASS: explicit missing runner takes precedence over forced JS"
else fail=$((fail + 1)); echo "  FAIL: explicit missing runner with forced JS (got $got)"; fi

cat > "$WORK/explicit-runner" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUNNER_LOG"
exit 0
SH
chmod +x "$WORK/explicit-runner"
fresh; printf '{}\n' > "$WORK/t/a.json"
IJSON_JCS="$WORK/explicit-runner" IJSON_JCS_FORCE_JS=1 RUNNER_LOG="$WORK/runner.log" \
  expect 0 "Silence: explicit runner selected with forced JS" --enforce
if grep -qF 'check t/a.json' "$WORK/runner.log"; then
  pass=$((pass + 1)); echo "  PASS: explicit runner receives file argument"
else
  fail=$((fail + 1)); echo "  FAIL: explicit runner was bypassed"
fi

echo "=== Canon stdout and dispatch ==="
bun run - "$REPO_DIR/scripts/ijson-jcs-cli.js" <<'JS'
import assert from "node:assert/strict";
const cli = process.argv[2];
const expected = JSON.stringify({ a: "x".repeat(2 * 1024 * 1024) });
const child = Bun.spawn(["bun", cli, "canon"], {
  stdin: new TextEncoder().encode(expected), stdout: "pipe", stderr: "pipe",
});
const chunks = [];
for await (const chunk of child.stdout) {
  chunks.push(Buffer.from(chunk));
  await Bun.sleep(1);
}
assert.equal(await child.exited, 0);
assert.equal(Buffer.concat(chunks).toString(), expected, "canon must drain stdout to a slow pipe");
assert.equal(await new Response(child.stderr).text(), "", "canon must not reach unknown-command handling");
for (const [command, input, diagnostic] of [
  ["canon", "{broken", "INVALID"], ["unknown", "{}", "unknown command"],
]) {
  const result = Bun.spawnSync(["bun", cli, command], { stdin: new TextEncoder().encode(input) });
  assert.equal(result.exitCode, 2);
  assert.equal(result.stdout.toString(), "");
  assert.ok(result.stderr.toString().includes(diagnostic));
}
console.log("PASS: canon drains large output and preserves dispatch error statuses");
JS

echo "=== Local CLI: exact canonical bytes and strict parser boundaries ==="
# Exercise the fallback directly even on machines with the Rust CLI installed.
# A byte comparison catches accidental newlines and UTF-16 ordering mistakes.
command -v bun >/dev/null 2>&1 || { echo 'FAIL: Bun is required for local CLI controls' >&2; exit 1; }
cli_case() { # <exit> <command> <input> <expected stdout> <label>
  local want="$1" cmd="$2" input="$3" expected="$4" label="$5" got=0
  printf '%s' "$input" | bun "$REPO_DIR/scripts/ijson-jcs-cli.js" "$cmd" \
    >"$WORK/cli-out" 2>"$WORK/cli-err" || got=$?
  printf '%s' "$expected" >"$WORK/cli-expected"
  if [ "$got" -eq "$want" ] && cmp -s "$WORK/cli-out" "$WORK/cli-expected"; then
    pass=$((pass + 1)); echo "  PASS: $label"
  else
    fail=$((fail + 1)); echo "  FAIL: $label (wanted exit $want, got $got, or wrong bytes)"
    cat "$WORK/cli-err"
  fi
}

cli_case 0 canon '{"2":2,"10":10,"__proto__":{"z":0,"a":1}}' \
  '{"10":10,"2":2,"__proto__":{"a":1,"z":0}}' 'numeric and prototype-like keys are preserved and sorted lexically'
cli_case 0 canon '{"\ue000":1,"\ud83d\ude00":2,"a":3,"aa":4}' \
  '{"a":3,"aa":4,"😀":2,"":1}' 'astral keys sort by UTF-16 code units, with prefix keys first'
cli_case 0 canon '[{"z":1,"a":2},false,null,[],{}]' \
  '[{"a":2,"z":1},false,null,[],{}]' 'nested objects sort without reordering arrays'
cli_case 0 canon '[-9007199254740991,9007199254740991,-0,1.50,1E+30,0.000001]' \
  '[-9007199254740991,9007199254740991,0,1.5,1e+30,0.000001]' 'safe integer limits and ECMAScript number serialization'
cli_case 0 canon '"\/\b\f\n\r\t\u0000\u0061"' \
  '"/\b\f\n\r\t\u0000a"' 'escapes normalize without losing control characters'
cli_case 0 canon '{"x":{"a":1},"y":{"a":2}}' \
  '{"x":{"a":1},"y":{"a":2}}' 'duplicate detection is scoped to each object'
cli_case 0 check '{"a":1}' '' 'CLI accepts canonical stdin without newline'
cli_case 0 check $'{"a":1}\n' '' 'CLI accepts one final LF'
cli_case 1 check $'{"a":1}\r\n' '' 'CRLF is valid JSON but noncanonical'
cli_case 1 check $'{"a":1}\n\n' '' 'two final LFs are noncanonical'

for input in '' ' ' '{' '[' '{"a":1,}' '[1,]' '{"a" 1}' '[1 2]' \
  'true false' '01' '-' '1.' '1e' '1e+' '+1' 'NaN' 'Infinity' '1e400' \
  '-9007199254740992' '"\x00"' '"\u12zz"' '"\udc00"' '"\ud800\u0041"' \
  '"\udbff\udfff"' '"\ufdd0"' '{"a":1,"\u0061":2}' \
  $'"raw\tcontrol"' $'\xef\xbb\xbf{}' $'"\xc0\xaf"'; do
  cli_case 2 canon "$input" '' "invalid input emits no canonical bytes: $(printf '%q' "$input")"
  cli_case 2 check "$input" '' "invalid input cannot pass check: $(printf '%q' "$input")"
done

echo "=== JSON Lines framing and scan scope ==="
# Isolate this section from a host-installed binary and inherited overrides.
export IJSON_JCS_FORCE_JS=1
fresh; : > "$WORK/t/empty.jsonl"
expect 0 'empty JSONL is a valid zero-record stream' --enforce
names '1 canonical' 'empty JSONL is counted as canonical'
fresh; : > "$WORK/t/empty.json"
expect 1 'empty JSON is invalid rather than a zero-record stream' --enforce
names 'INVALID t/empty.json' 'empty document is classified as invalid'
fresh; printf '{"z":1,"a":2}\n{bad}\n' > "$WORK/t/records.jsonl"
expect 1 'invalid JSONL record takes precedence over earlier formatting drift' --enforce
names '0 not canonical, 1 invalid' 'JSONL invalid verdict is retained for the whole file'
fresh; printf '{"a":1}\n{"b":2}' > "$WORK/t/records.jsonl"
expect 1 'JSONL without final LF is noncanonical' --enforce
names 'NOT CANONICAL t/records.jsonl' 'JSONL newline error is classified correctly'
fresh; printf '{"a":1}\n{"b":2,"b":3}\n' > "$WORK/t/records.jsonl"
expect 1 'invalid later JSONL record fails the whole file' --enforce
names 'INVALID t/records.jsonl' 'later invalid record is not merely noncanonical'
fresh; printf '{bad}\n' > "$WORK/t/a.json"
expect 0 'report-only mode reports invalid data without blocking'
names '1 invalid' 'report-only mode retains invalid count'
fresh
for dir in .git node_modules target _build; do
  mkdir -p "$WORK/t/$dir/nested"
  printf '{bad}\n' > "$WORK/t/$dir/nested/ignored.json"
done
printf '{"a":1}\n' > "$WORK/t/name with spaces.json"
expect 0 'dependency and VCS trees are pruned; filenames with spaces survive' --enforce
names '1 file(s) checked, 1 canonical' 'only the selected file is counted'
fresh; printf '// comment\n{}\n' > "$WORK/t/ordinary.json"
expect 1 'JSONC carve-out does not exempt ordinary JSON' --enforce
names 'INVALID t/ordinary.json' 'ordinary JSON comments are rejected'

echo "=== Unicode validation applies to decoded keys and every noncharacter plane ==="
bun run - "$REPO_DIR/scripts/ijson-jcs-cli.js" <<'JS'
import assert from "node:assert/strict";
const cli = process.argv[2];
function run(command, input) {
  return Bun.spawnSync(["bun", cli, command], { stdin: new TextEncoder().encode(input) });
}
// I-JSON excludes the entire FDD0..FDEF block and the last two code points
// of all 17 Unicode planes, in object keys as well as string values.
const forbidden = [
  ...Array.from({ length: 32 }, (_, i) => 0xfdd0 + i),
  ...Array.from({ length: 17 }, (_, plane) => [plane * 0x10000 + 0xfffe, plane * 0x10000 + 0xffff]).flat(),
];
for (const cp of forbidden) {
  const char = String.fromCodePoint(cp);
  for (const input of [JSON.stringify(char), JSON.stringify({ [char]: 1 })]) {
    for (const command of ["canon", "check"]) {
      const result = run(command, input);
      assert.equal(result.exitCode, 2, `${command} must reject U+${cp.toString(16)} in ${input}`);
      assert.equal(result.stdout.toString(), "", "invalid Unicode must emit no canonical bytes");
      assert.match(result.stderr.toString(), /INVALID/);
    }
  }
}
for (const cp of [0xfdcf, 0xfdf0, 0xfffd, 0x10000, 0x1fffd, 0x10fffd]) {
  const input = JSON.stringify({ [String.fromCodePoint(cp)]: String.fromCodePoint(cp) });
  const result = run("canon", input);
  assert.equal(result.exitCode, 0, `valid neighbor U+${cp.toString(16)} must be accepted`);
  assert.equal(result.stdout.toString(), input);
}
// JCS preserves Unicode normalization; these are distinct, legal keys.
const normalized = run("canon", '{"é":1,"e\\u0301":2}');
assert.equal(normalized.exitCode, 0);
assert.equal(normalized.stdout.toString(), '{"é":2,"é":1}');
console.log("PASS: Unicode key/value exclusions, valid boundaries, and normalization preservation");
JS

echo "check_ijson_jcs_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
