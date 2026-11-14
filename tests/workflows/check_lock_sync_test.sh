#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression controls for the POSIX awk lock parser. No network used.
# Usage: bash tests/workflows/check_lock_sync_test.sh
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$work/out" >&2; exit 1; }
command -v mawk >/dev/null || { echo 'FAIL: mawk is required for portability regression' >&2; exit 1; }
# The production script prefers gawk. Hide it so this catches the original
# Ubuntu/mawk interval-regex failure even when gawk is installed on the host.
mkdir -p "$work/bin" "$work/base"
for tool in bash mawk sort; do ln -s "$(command -v "$tool")" "$work/bin/$tool"; done
cat > "$work/base/ci.yml" <<'YML'
name: Test
on: pull_request
jobs:
  reusable:
    uses: Owner/Repo/.github/workflows/check.yml@v1
  local:
    runs-on: ubuntu-latest
    steps:
      - uses: ./local-action
      - uses: 'OWNER/REPO/subdir@v1' # same repository pin
YML
cat > "$work/base/actions.lock" <<'LOCK'
version: 'v0.0.3'
workflows:
    '.github/workflows/ci.yml':
        - 'owner/repo@v1'
dependencies:
    'owner/repo@v1':
        ref: 'v1'
        commit: 'sha1-1111111111111111111111111111111111111111'
        owner_id: 1
        repo_id: 2
LOCK
fresh() { rm -rf "$work/current"; cp -R "$work/base" "$work/current"; }
set_key() {
  local key_ref=$1 target line
  for target in "$work/current/ci.yml" "$work/current/actions.lock"; do
    while IFS= read -r line; do
      printf '%s\n' "${line//"@v1"/"@$key_ref"}"
    done < "$target" > "$work/key-file"
    mv "$work/key-file" "$target"
  done
}
sha_key() { set_key '1111111111111111111111111111111111111111'; }
expect() { # <exit> <diagnostic> <label>
  local want=$1 pattern=$2 label=$3 got=0
  BASH_ENV=/dev/null PATH="$work/bin" bash "$repo/scripts/check-lock-sync.sh" "$work/current" > "$work/out" 2>&1 || got=$?
  [[ "$got" -eq "$want" ]] || fail "$label: expected $want, got $got"
  if [[ "$want" -eq 0 ]]; then pattern='is in sync and transitively closed'; fi
  grep -qF -- "$pattern" "$work/out" || fail "$label: missing diagnostic '$pattern'"
  echo "PASS: $label"
}

fresh
expect 0 'OK' 'mawk reads job and step uses, subpaths, comments, and owner/repo case'
fresh
sha_key
sed -i "s/ref: 'v1'/ref: '0123456789abcdef0123456789abcdef012345'/" "$work/current/actions.lock"
expect 0 'OK' 'a 38-character hexadecimal tag is not a full SHA'
fresh
sed -i "s/ref: 'v1'/ref: '0123456789abcdef0123456789abcdef01234567'/" "$work/current/actions.lock"
expect 1 'SELF-SHA REFS' 'mawk detects exactly 40 hexadecimal characters in dependency ref'
for ref in abcdef0123456789abcdef0123456789abcdef01 ABCDEF0123456789ABCDEF0123456789ABCDEF01 aBcDeF0123456789aBcDeF0123456789aBcDeF01; do
  [[ "${#ref}" -eq 40 ]]
  fresh
  sed -i "s/ref: 'v1'/ref: '$ref'/" "$work/current/actions.lock"
  expect 1 'SELF-SHA REFS' "mawk rejects self-SHA refs regardless of hexadecimal case: $ref"
done
fresh
sha_key
sed -i "s/ref: 'v1'/ref: '0123456789abcdef0123456789abcdef0123456789'/" "$work/current/actions.lock"
expect 0 'OK' 'a 42-character tag is not misclassified as a full SHA'
fresh
sed -i 's/@v1/@V1/g' "$work/current/ci.yml"
expect 1 'refs missing from the lockfile' 'refs remain case sensitive'
fresh
sed -i '/commit:/a\        uses:\n            - '\''other/action@v2'\''' "$work/current/actions.lock"
expect 1 'DANGLING EDGES' 'nested dependency edge must resolve to a record'
cat >> "$work/current/actions.lock" <<'LOCK'
    'other/action@v2':
        ref: 'v2'
        commit: 'sha1-2222222222222222222222222222222222222222'
        owner_id: 3
        repo_id: 4
LOCK
expect 0 'OK' 'a transitively closed lock is accepted'
fresh
sed -i 's/^dependencies:/unused:/' "$work/current/actions.lock"
expect 1 'DANGLING EDGES' 'workflow lock pin needs a top-level dependency record'
fresh
sed -i "s/        - 'owner\/repo@v1'/        - 'owner\/repo@v2'/" "$work/current/actions.lock"
expect 1 'stale lockfile entries' 'orphan pins fail in the reverse direction'
fresh
printf 'name: Inline\non: pull_request\njobs: {}\n' > "$work/current/empty.yaml"
expect 1 'UNLISTED WORKFLOWS' 'zero-uses yaml workflow still needs a lock key'
sed -i "/^dependencies:/i\    '.github/workflows/empty.yaml': []" "$work/current/actions.lock"
expect 0 'OK' 'empty-list onboarding covers zero-uses workflows'
fresh
sed -i 's#./local-action#$/local-action#' "$work/current/ci.yml"
expect 1 'invalid local-action rewrite' 'corrupt dollar-slash local action fails'
fresh
sed -i "s/'v0.0.3'/'v0.0.2'/" "$work/current/actions.lock"
expect 1 'INVALID VERSION' 'old lock format is refused'
fresh
rm "$work/current/actions.lock"
expect 1 'no lockfile' 'missing lock is an explicit failure'

# Check the immediate length boundaries of the POSIX replacement for {40}.
for length in 39 41; do
  fresh
  sha_key
  printf -v ref '%*s' "$length" ''; ref=${ref// /a}
  sed -i "s/ref: 'v1'/ref: '$ref'/" "$work/current/actions.lock"
  expect 0 'OK' "a $length-character hexadecimal tag remains legal"
done
fresh
sha_key
sed -i "s/ref: 'v1'/ref: 'g123456789abcdef0123456789abcdef0123456789'/" "$work/current/actions.lock"
expect 0 'OK' 'a 40-character tag containing nonhexadecimal text is legal'
fresh
sed -i '/^version:/d' "$work/current/actions.lock"
expect 1 'INVALID VERSION (missing' 'a missing format version is an explicit failure'
fresh
sed -i "/^dependencies:/i\    '.github/workflows/deleted.yml': []" "$work/current/actions.lock"
expect 1 'workflow file that does not exist' 'a removed workflow cannot leave an orphan lock key'

# Coverage is per workflow, even when another workflow locks the same ref.
fresh
cp "$work/current/ci.yml" "$work/current/second.yaml"
sed -i "/^dependencies:/i\    '.github/workflows/second.yaml': []" "$work/current/actions.lock"
expect 1 'refs missing from the lockfile' 'another workflow pin cannot satisfy this workflow'
sed -i "/'\.github\/workflows\/second.yaml':/c\    '.github/workflows/second.yaml':\n        - 'owner/repo@v1'" "$work/current/actions.lock"
expect 0 'OK' 'both workflow keys can share one resolved dependency record'

fresh
cat >> "$work/current/actions.lock" <<'LOCK'
    'unused/action@v2':
        ref: 'v2'
        commit: 'sha1-2222222222222222222222222222222222222222'
        owner_id: 3
        repo_id: 4
LOCK
expect 0 'OK' 'an unreferenced leaf dependency is informational, not fatal'
sed -i "s/ref: 'v2'/ref: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'/" "$work/current/actions.lock"
expect 1 'SELF-SHA REFS' 'self-SHA refusal also covers unreferenced dependency records'

# A resolved commit does not make placeholder or malformed source-ref metadata
# valid. The K9 action preparation failure in Protoctist.jl used <sha-pinned>.
set_ref_scalar() {
  local scalar=$1 line
  while IFS= read -r line; do
    if [[ "$line" == '        ref:'* ]]; then
      printf '        ref: %s\n' "$scalar"
    else
      printf '%s\n' "$line"
    fi
  done < "$work/current/actions.lock" > "$work/new.lock"
  mv "$work/new.lock" "$work/current/actions.lock"
}
set_ref() { set_ref_scalar "'$1'"; }

for ref in main v1.2.3 release/2026.11; do
  fresh
  sha_key
  set_ref "$ref"
  expect 0 'OK' "named branch/tag ref remains legal: $ref"
done

for ref in '<sha-pinned>' '' 'release branch' 'release..next' 'release/.hidden' 'main.lock' 'main@{1}' 'main\next'; do
  fresh
  set_ref "$ref"
  expect 1 'INVALID NAMED REFS' "placeholder or malformed ref is refused: $ref"
done

fresh
sed -i '/^        ref:/d' "$work/current/actions.lock"
expect 1 'INVALID NAMED REFS' 'a dependency with no ref metadata is refused'
fresh
sed -i "s/ref: 'v1'/ref: 'v1/" "$work/current/actions.lock"
expect 1 'INVALID NAMED REFS' 'an unterminated quoted ref is refused'

fresh
sha_key
sed -i "s/ref: 'v1'/ref: \"main\"/" "$work/current/actions.lock"
expect 0 'OK' 'double-quoted named refs are accepted'
fresh
set_key main
sed -i "s/ref: 'v1'/ref: main/" "$work/current/actions.lock"
expect 0 'OK' 'plain named refs are accepted'

# Full SHA identities cover SHA-256 as well as SHA-1, but adjacent lengths
# and nonhexadecimal names must remain eligible branch/tag names.
for stem in abcdef01 ABCDEF01 aBcDeF01 01234567; do
  fresh
  printf -v ref '%s%s%s%s%s%s%s%s' "$stem" "$stem" "$stem" "$stem" "$stem" "$stem" "$stem" "$stem"
  [[ "${#ref}" -eq 64 ]]
  set_ref "$ref"
  expect 1 'SELF-SHA REFS' "64-hex source ref is refused: $stem"
done
for length in 63 65; do
  fresh
  sha_key
  printf -v ref '%*s' "$length" ''; ref=${ref// /a}
  set_ref "$ref"
  expect 0 'OK' "a $length-character hexadecimal tag remains legal"
done
fresh
sha_key
printf -v ref '%*s' 63 ''; ref="g${ref// /a}"
set_ref "$ref"
expect 0 'OK' 'a 64-character nonhexadecimal tag remains legal'

# The backend resolves short names under refs/tags/ or refs/heads/ itself.
for ref in refs/heads/main refs/tags/v1 refs/pull/18/head refs/; do
  fresh
  sha_key
  set_ref "$ref"
  expect 1 'INVALID NAMED REFS' "fully qualified ref is refused: $ref"
done
for ref in refs-main xrefs/heads/main Refs/heads/main; do
  fresh
  sha_key
  set_ref "$ref"
  expect 0 'OK' "a name without the exact refs/ prefix remains legal: $ref"
done
fresh
set_key refs/heads/main
set_ref refs/heads/main
expect 1 'INVALID NAMED REFS' 'matching key and value cannot legitimise a qualified ref'

# Mutable pin keys must agree exactly with metadata. A full SHA key records
# the short source name instead; this exception applies to both hash kinds.
fresh
set_ref v2
expect 1 'MISMATCHED REFS' 'mutable v1 key cannot record v2'
fresh
set_key Main
set_ref main
expect 1 'MISMATCHED REFS' 'metadata and mutable key refs are case sensitive'
fresh
set_key abcdef0123456789abcdef0123456789abcdef012
set_ref main
expect 1 'MISMATCHED REFS' 'an abbreviated SHA-like key receives no full-SHA exception'
for ref in main v1.2.3 release/2026.11; do
  fresh
  set_key "$ref"
  set_ref "$ref"
  expect 0 'OK' "matching mutable key and source ref pass: $ref"
done
fresh
sha_key
set_ref main
expect 0 'OK' 'a full SHA-1 key can record its short source branch'
fresh
printf -v key_ref '%*s' 64 ''; key_ref=${key_ref// /a}
set_key "$key_ref"
sed -i "s/sha1-1111111111111111111111111111111111111111/sha256-$key_ref/" "$work/current/actions.lock"
set_ref main
expect 0 'OK' 'a full SHA-256 key can record its short source branch'

# Type information matters: the spelling of a YAML scalar is not its value.
# Keep quoted literal names valid while refusing the corresponding non-string
# scalars, flow collections, and comment-only/null values.
for scalar in '' '#missing' '# missing' null Null NULL '~' true True TRUE false False FALSE 123 +123 -123 1.5 1e3 1E+3 1_000 0xFF 0o17 0b10 .inf .NaN '{}' '[]' '{name: main}'; do
  fresh
  sha_key
  set_ref_scalar "$scalar"
  expect 1 'INVALID REF SCALARS' "unquoted non-string/comment-only ref is refused: $scalar"
done
for ref in null true false 123 1e3 0xFF '{}'; do
  for quote in "'" '"'; do
    fresh
    sha_key
    set_ref_scalar "${quote}${ref}${quote}"
    expect 0 'OK' "quoted literal ref remains a string: ${quote}${ref}${quote}"
  done
done
for ref in main v1.2.3 release/2026.11 nullish TrueBranch TrUe 123release yes no on off; do
  fresh
  sha_key
  set_ref_scalar "$ref"
  expect 0 'OK' "plain string ref is not confused with a YAML scalar type: $ref"
done
for scalar in 'main # source branch' "'null' # literal branch name" '"true" # literal tag'; do
  fresh
  sha_key
  set_ref_scalar "$scalar"
  expect 0 'OK' "a trailing comment preserves a string ref: $scalar"
done
fresh
sha_key
set_ref 'release#1'
expect 0 'OK' 'a hash inside a quoted name is not a YAML comment'

# A closing quote must terminate the scalar, not merely match its last byte.
# Doubled single quotes remain valid YAML escaping inside a literal name.
for scalar in "'main'junk'" '"main"junk"'; do
  fresh
  sha_key
  set_ref_scalar "$scalar"
  expect 1 'INVALID NAMED REFS' "content after a quoted scalar is refused: $scalar"
done
for scalar in "'main''junk'" "\"main'junk\""; do
  fresh
  sha_key
  set_ref_scalar "$scalar"
  expect 0 'OK' "properly quoted literal name remains valid: $scalar"
done

# Case-folded lookup cannot lend one raw dependency record another's ref.
fresh
sha_key
sed -i "/^        ref:/d; s/^    'owner\/repo@/    'Owner\/Repo@/" "$work/current/actions.lock"
cat >> "$work/current/actions.lock" <<'LOCK'
    'owner/repo@1111111111111111111111111111111111111111':
        ref: 'main'
        commit: 'sha1-1111111111111111111111111111111111111111'
        owner_id: 1
        repo_id: 2
LOCK
expect 1 'Owner/Repo@1111111111111111111111111111111111111111 (ref: <missing ref>)' 'a later case variant cannot mask an earlier missing ref'
sed -i "/^    'Owner\/Repo@/a\        ref: 'main'" "$work/current/actions.lock"
expect 0 'OK' 'case variants pass when each raw dependency record has its own ref'
sed -i "/^    'owner\/repo@/,/^        repo_id:/ { /^        ref:/d; }" "$work/current/actions.lock"
expect 1 'owner/repo@1111111111111111111111111111111111111111 (ref: <missing ref>)' 'an earlier case variant cannot mask a later missing ref'

# Clause 5's one exception: the target of job-level reusable-workflow calls
# only may record its own SHA as ref: (GitHub runs it; see the script header).
# reusable_only drops the step that also uses OWNER/REPO as an action.
reusable_only() { sed -i "/- uses: 'OWNER\/REPO\/subdir@/d" "$work/current/ci.yml"; }
self_ref() { sed -i "s/ref: 'v1'/ref: '1111111111111111111111111111111111111111'/" "$work/current/actions.lock"; }
fresh
reusable_only
sha_key
self_ref
expect 0 'OK' 'a job-level reusable target may record its own SHA as ref'
fresh
sha_key
self_ref
expect 1 'SELF-SHA REFS' 'the exception does not cover a ref that a step also uses as an action'
fresh
reusable_only
sha_key
self_ref
cat >> "$work/current/actions.lock" <<'LOCK'
    'other/caller@v3':
        ref: 'v3'
        commit: 'sha1-3333333333333333333333333333333333333333'
        owner_id: 5
        repo_id: 6
        uses:
            - 'owner/repo@1111111111111111111111111111111111111111'
LOCK
expect 1 'SELF-SHA REFS' 'the exception does not cover a ref that another record names as a nested uses'
fresh
reusable_only
sha_key
sed -i "s#Owner/Repo/.github/workflows/check.yml@#Owner/Repo/.github/actions/check@#" "$work/current/ci.yml"
self_ref
expect 1 'SELF-SHA REFS' 'a path outside .github/workflows is not a reusable workflow'

# The exception needs the key itself pinned to the same full SHA as ref:.
fresh
reusable_only
self_ref
expect 1 'SELF-SHA REFS' 'a mutable key (@v1) with a SHA ref is not covered by the exception'
fresh
reusable_only
sha_key
sed -i "s/ref: 'v1'/ref: '2222222222222222222222222222222222222222'/" "$work/current/actions.lock"
expect 1 'SELF-SHA REFS' 'a SHA key whose ref names a different SHA is not covered'

# Job-level vs step position is read from the YAML, not inferred from the
# path: a step action may live in a directory named like a workflow file.
fresh
cat > "$work/current/ci.yml" <<'YML'
name: Test
on: pull_request
jobs:
  local:
    runs-on: ubuntu-latest
    steps:
      - uses: Owner/Repo/.github/workflows/tool.yml@v1
YML
sha_key
self_ref
expect 1 'SELF-SHA REFS' 'a step action with a workflow-shaped path is not a reusable call'
fresh
cat > "$work/current/ci.yml" <<'YML'
name: Test
on: pull_request
jobs:
  local:
    runs-on: ubuntu-latest
    steps:
      - name: build
        uses: Owner/Repo/.github/workflows/tool.yml@v1
  reusable:
    uses: Owner/Repo/.github/workflows/check.yml@v1
YML
sha_key
self_ref
expect 1 'SELF-SHA REFS' 'a non-first step key with a workflow-shaped path still counts as an action'
fresh
cat > "$work/current/ci.yml" <<'YML'
name: Test
on: pull_request
jobs:
  local:
    runs-on: ubuntu-latest
    steps:
      - run: echo build
  reusable:
    uses: Owner/Repo/.github/workflows/check.yml@v1
YML
sha_key
self_ref
expect 0 'OK' 'a job-level call after another job with steps is still a reusable call'
