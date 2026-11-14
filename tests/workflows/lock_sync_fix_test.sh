#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Self-test for scripts/lock-sync-fix.sh. No network: the resolver is swapped for
# a table-driven fake through LOCK_SYNC_RESOLVER.
# Usage: bash tests/workflows/lock_sync_fix_test.sh
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fix="$repo/scripts/lock-sync-fix.sh"
check="$repo/scripts/check-lock-sync.sh"
fail() { echo "FAIL: $*" >&2; [ -f "$work/out" ] && cat "$work/out" >&2; exit 1; }

S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222
S3=3333333333333333333333333333333333333333
S4=4444444444444444444444444444444444444444

# fake resolver; table lines: "tag owner/repo ref sha" and "ids owner/repo oid rid"
cat > "$work/resolver" <<'R'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$1" in
  tag)    awk -v k="$2 $3" '$1 == "tag" && $2 " " $3 == k { print $4; f = 1 } END { exit !f }' "$FAKE_TABLE" ;;
  ids)    awk -v k="$2" '$1 == "ids" && $2 == k { print $3, $4; f = 1 } END { exit !f }' "$FAKE_TABLE" ;;
  nested) awk -v k="$2" '$1 == "nested" && $2 == k { print $3 }' "$FAKE_TABLE" ;;
  *) exit 2 ;;
esac
R
chmod +x "$work/resolver"
export LOCK_SYNC_RESOLVER="$work/resolver" FAKE_TABLE="$work/table" FAKE_LOG="$work/log"

# fixture: two workflows share upload-artifact; ci.yml also SHA-pins setup
fresh() {
  rm -rf "$work/wf"; mkdir -p "$work/wf"; : > "$work/log"
  cat > "$work/wf/ci.yml" <<YML
name: CI
on: pull_request
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v2.0.0
      - uses: Acme/Setup@$S3 # v3.0.0
YML
  cat > "$work/wf/other.yml" <<'YML'
name: Other
on: pull_request
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v1.0.0
YML
  cat > "$work/wf/actions.lock" <<LOCK
# header comment
version: 'v0.0.3'
workflows:
    '.github/workflows/ci.yml':
        - 'acme/setup@$S1'
        - 'actions/upload-artifact@v1.0.0'
    '.github/workflows/other.yml':
        - 'actions/upload-artifact@v1.0.0'
dependencies:
    'acme/setup@$S1':
        ref: 'v1.0.0'
        commit: 'sha1-$S1'
        owner_id: 7
        repo_id: 8
    'actions/upload-artifact@v1.0.0':
        ref: 'v1.0.0'
        commit: 'sha1-$S1'
        owner_id: 44036562
        repo_id: 192625955
LOCK
  cat > "$work/table" <<TBL
tag actions/upload-artifact v2.0.0 $S2
tag acme/setup v3.0.0 $S3
TBL
}
run_fix() { "$fix" "$work/wf" > "$work/out" 2>&1; }

# 1. stale lock (Dependabot bumped ci.yml only): gate red before, green after
fresh
"$check" "$work/wf" > "$work/out" 2>&1 && fail "fixture should start out of sync"
run_fix || fail "fixer failed on a resolvable stale lock"
"$check" "$work/wf" > "$work/out" 2>&1 || fail "check-lock-sync.sh still red after the fix"
grep -qF "'actions/upload-artifact@v2.0.0':" "$work/wf/actions.lock" || fail "new tag record missing"
grep -qF "commit: 'sha1-$S2'" "$work/wf/actions.lock" || fail "new tag commit not recorded"
grep -qF "owner_id: 44036562" "$work/wf/actions.lock" || fail "owner_id not reused from the sibling record"
grep -qF "'actions/upload-artifact@v1.0.0':" "$work/wf/actions.lock" || fail "record still used by other.yml was dropped"
grep -qF "'acme/setup@$S3':" "$work/wf/actions.lock" || fail "SHA-pinned record missing"
grep -qF "ref: 'v3.0.0'" "$work/wf/actions.lock" || fail "SHA-pinned record lost its tag ref"
grep -qF "'acme/setup@$S1'" "$work/wf/actions.lock" && fail "orphaned old record not dropped"
head -1 "$work/wf/actions.lock" | grep -qF "# header comment" || fail "lock header not preserved"
grep -q '^tag actions/upload-artifact v1.0.0' "$work/log" && fail "re-resolved an unchanged record"

# 2. idempotent: second run changes nothing and asks the resolver nothing
cp "$work/wf/actions.lock" "$work/first.lock"; : > "$work/log"
run_fix || fail "second run failed"
cmp -s "$work/first.lock" "$work/wf/actions.lock" || fail "second run changed the lock"
[ ! -s "$work/log" ] || fail "second run called the resolver"

# 3. new action in a new repo takes its ids from the resolver
fresh
sed -i 's#actions/upload-artifact@v2.0.0#newowner/newrepo@v9.9.9#' "$work/wf/ci.yml"
printf 'tag newowner/newrepo v9.9.9 %s\nids newowner/newrepo 5 6\n' "$S4" >> "$work/table"
run_fix || fail "fixer failed for a new repo"
"$check" "$work/wf" > "$work/out" 2>&1 || fail "gate red after adding a new repo"
grep -qF "owner_id: 5" "$work/wf/actions.lock" || fail "resolver ids not used"

# 4. negative control: an unresolvable ref fails loudly and leaves the lock untouched
fresh
cp "$work/wf/actions.lock" "$work/before.lock"
sed -i '/upload-artifact v2.0.0/d' "$work/table"
if run_fix; then fail "unresolvable ref must exit non-zero"; fi
grep -q 'cannot resolve' "$work/out" || fail "failure must say why"
cmp -s "$work/before.lock" "$work/wf/actions.lock" || fail "lock modified despite failure"
"$check" "$work/wf" > /dev/null 2>&1 && fail "gate must stay red after a failed fix"

# 5. negative control: SHA pin whose comment tag resolves elsewhere is refused
fresh
printf 'tag acme/setup v3.0.0 %s\n' "$S4" > "$work/table"
printf 'tag actions/upload-artifact v2.0.0 %s\n' "$S2" >> "$work/table"
if run_fix; then fail "mismatched SHA/tag must exit non-zero"; fi
grep -q 'refusing to record a mismatched pin' "$work/out" || fail "mismatch not reported"

# 6. negative control: SHA pin with no tag comment is refused
fresh
sed -i "s/ # v3.0.0//" "$work/wf/ci.yml"
if run_fix; then fail "SHA pin without a tag comment must exit non-zero"; fi
grep -q "no trailing '# <tag>' comment" "$work/out" || fail "missing-comment not reported"

# 7. negative control: a new action with nested external uses: is refused, not half-recorded
fresh
printf 'nested actions/upload-artifact someorg/inner@v1\n' >> "$work/table"
cp "$work/wf/actions.lock" "$work/before.lock"
if run_fix; then fail "nested uses must exit non-zero"; fi
grep -q 'nested external uses' "$work/out" || fail "nested uses not reported"
cmp -s "$work/before.lock" "$work/wf/actions.lock" || fail "lock modified despite nested-uses failure"

echo "lock_sync_fix_test: all cases passed"
