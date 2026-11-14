#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Unit controls for the formatter added in PR #253 (Mike Farah yq 4.53.3+).
# Usage: bash tests/workflows/kyaml_format_test.sh
set -euo pipefail
yq --version 2>&1 | grep -q mikefarah || { echo "FAIL: this test needs Mike Farah yq (Go, 4.53.3+); the yq on PATH is a different tool" >&2; exit 1; }
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$work/out" >&2; exit 1; }
formatter="$repo/scripts/kyaml-format.sh"
expect() { # <exit> [formatter args...]
  local want=$1 got=0
  shift
  bash "$formatter" "$@" > "$work/out" 2>&1 || got=$?
  [[ "$got" -eq "$want" ]] || fail "expected exit $want, got $got"
}
file="$work/config with spaces.kyaml"
cat > "$file" <<'YML'
# keep this comment
name: "quoted # value"
enabled: true
items:
  - 1
  - null
body: |
  first line
  second line
YML
chmod 0750 "$file"
cp -p "$file" "$work/original"
yq -p yaml -o json -I 0 'sort_keys(..)' "$file" > "$work/before.json"
expect 1 --check "$file"
cmp -s "$file" "$work/original" || fail 'check mode changed the input bytes'
expect 0 "$file"
yq -p yaml -o json -I 0 'sort_keys(..)' "$file" > "$work/after.json"
cmp -s "$work/before.json" "$work/after.json" || fail 'formatting changed parsed data or block-scalar newlines'
grep -qF '# keep this comment' "$file" || fail 'formatting lost comments'
[[ "$(stat -c %a "$file")" == 750 ]] || fail 'atomic replacement changed permissions'
expect 0 --check "$file"
cp "$file" "$work/formatted"
expect 0 "$file"
cmp -s "$file" "$work/formatted" || fail 'formatting is not idempotent'
echo 'PASS: check mode is read only; formatting preserves data, comments, modes, and is idempotent'

printf 'body: |\n  missing final newline' > "$work/no-newline"
printf 'invalid: [\n' > "$work/malformed"
for name in no-newline malformed; do
  cp "$work/$name" "$work/saved"
  for mode in format check; do
    args=(); [[ "$mode" != check ]] || args+=(--check)
    expect 2 "${args[@]}" "$work/$name"
    cmp -s "$work/$name" "$work/saved" || fail "$mode rewrote refused input: $name"
  done
done
expect 2
expect 2 --check "$work/absent"
printf 'name: drift\n' > "$work/drift.kyaml"
cp "$work/drift.kyaml" "$work/saved"
expect 2 --check "$file" "$work/drift.kyaml" "$work/absent"
grep -qF '1 of 3 file(s) REFUSED' "$work/out" || fail 'refusal must take precedence over drift'
cmp -s "$work/drift.kyaml" "$work/saved" || fail 'mixed check rewrote drifted file'
echo 'PASS: missing, malformed, and unterminated inputs are refused without mutation; refusal outranks drift'

# Inject a renderer that changes data, retaining the real parser so the
# independent before/after guard must catch it before any replacement.
mkdir "$work/bin"
export REAL_YQ
REAL_YQ=$(command -v yq)
cat > "$work/bin/yq" <<'SH'
#!/usr/bin/env bash
if [[ "$4" == kyaml ]]; then
  printf '{changed: true}\n'
else
  exec "$REAL_YQ" "$@"
fi
SH
chmod +x "$work/bin/yq"
for mode in format check; do
  args=(); [[ "$mode" != check ]] || args+=(--check)
  BASH_ENV=/dev/null PATH="$work/bin:$PATH" expect 2 "${args[@]}" "$work/drift.kyaml"
  grep -qF 'does not parse to the same data' "$work/out" || fail 'semantic drift was not detected'
  cmp -s "$work/drift.kyaml" "$work/saved" || fail 'semantic drift overwrote the original'
done
[[ -z "$(find "$work" -name '.kyaml.*' -print)" ]] || fail 'formatter leaked a staging file'
echo 'PASS: semantic drift is refused in both modes before atomic replacement'

# Preserve the remote regression coverage: formatting refuses links even
# when the target is already canonical; check mode may inspect the target.
printf 'name: sample\n' > "$work/target.kyaml"
cp "$work/target.kyaml" "$work/symlink-original"
ln -s target.kyaml "$work/link.kyaml"
expect 2 "$work/link.kyaml"
grep -qF 'symlink' "$work/out" || fail 'symlink refusal did not name the cause'
[[ -L "$work/link.kyaml" && "$(readlink "$work/link.kyaml")" == target.kyaml ]] || fail 'formatting replaced the symlink'
cmp -s "$work/target.kyaml" "$work/symlink-original" || fail 'formatting modified a symlink target'
expect 1 --check "$work/link.kyaml"
[[ -L "$work/link.kyaml" ]] || fail 'check mode replaced the symlink'
cmp -s "$work/target.kyaml" "$work/symlink-original" || fail 'check mode modified a symlink target'
expect 0 "$work/target.kyaml"
expect 0 --check "$work/target.kyaml"
cp "$work/target.kyaml" "$work/symlink-formatted"
expect 2 "$work/link.kyaml"
[[ -L "$work/link.kyaml" ]] || fail 'formatting replaced a link to a canonical target'
cmp -s "$work/target.kyaml" "$work/symlink-formatted" || fail 'formatting changed a canonical symlink target'
ln -s missing.kyaml "$work/dangling.kyaml"
expect 2 "$work/dangling.kyaml"
[[ -L "$work/dangling.kyaml" ]] || fail 'formatting replaced a dangling symlink'
echo 'PASS: formatter refuses symlinks, preserves targets, and formats regular files'

# A failure at the final rename must preserve the input and clean the staged
# file. Inject only that process failure; parsing and rendering remain real.
mkdir "$work/fail-rename-bin"
cat > "$work/fail-rename-bin/mv" <<'SH'
#!/usr/bin/env bash
exit 75
SH
chmod +x "$work/fail-rename-bin/mv"
printf 'name: rename-failure\n' > "$work/rename.kyaml"
chmod 0640 "$work/rename.kyaml"
cp -p "$work/rename.kyaml" "$work/rename-original"
BASH_ENV=/dev/null PATH="$work/fail-rename-bin:$PATH" expect 2 "$work/rename.kyaml"
grep -qF 'failed to atomically replace' "$work/out" || fail 'rename failure was not reported'
cmp -s "$work/rename-original" "$work/rename.kyaml" || fail 'failed replacement changed input bytes'
[[ "$(stat -c %a "$work/rename.kyaml")" == 640 ]] || fail 'failed replacement changed input permissions'
[[ -z "$(find "$work" -name '.kyaml.*' -print)" ]] || fail 'failed replacement leaked a staging file'
echo 'PASS: atomic replacement failure preserves original bytes and permissions and removes staging files'
