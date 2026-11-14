#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/dependabot.yml" <<'YAML'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
  - package-ecosystem: nix
    directory: /
  - package-ecosystem: cargo
    directory: /
YAML
bash "$repo/scripts/rust-tool.sh" prune-dependabot-ecosystems "$fixture/dependabot.yml" github-actions
grep -q 'github-actions' "$fixture/dependabot.yml"
if grep -qE 'nix|cargo' "$fixture/dependabot.yml"; then exit 1; fi
cp "$fixture/dependabot.yml" "$fixture/before"
bash "$repo/scripts/rust-tool.sh" prune-dependabot-ecosystems "$fixture/dependabot.yml" nix
cmp "$fixture/dependabot.yml" "$fixture/before"
cat > "$fixture/policy.md" <<'DOC'
<!--
SPDX-License-Identifier: MPL-2.0
-->
# Policy
Prose mentions TEMPLATE INSTRUCTIONS and must survive.
Actual policy.
DOC
bash "$repo/scripts/rust-tool.sh" strip-instruction-blocks "$fixture/policy.md"
grep -q SPDX "$fixture/policy.md"
grep -q '^# Policy' "$fixture/policy.md"
grep -q '^Prose mentions' "$fixture/policy.md"
if grep -q 'delete only this' "$fixture/policy.md"; then exit 1; fi
cp "$fixture/policy.md" "$fixture/before"
bash "$repo/scripts/rust-tool.sh" strip-instruction-blocks "$fixture/policy.md"
cmp "$fixture/policy.md" "$fixture/before"
# The tool edits only the files it is given. It used to walk a directory, and
# so edited git-ignored sibling checkouts under _build/ when minting lintel.
# Negative control: an unlisted file with a block must come through untouched.
mkdir -p "$fixture/cache"
printf '<!-- TEMPLATE INSTRUCTIONS: not ours -->\nsibling\n' > "$fixture/cache/README.md"
cp "$fixture/cache/README.md" "$fixture/cache.before"
printf '<!-- TEMPLATE INSTRUCTIONS: ours -->\nlisted\n' > "$fixture/listed.md"
printf '%s\n' "$fixture/listed.md" | bash "$repo/scripts/rust-tool.sh" strip-instruction-blocks -
if grep -q 'TEMPLATE INSTRUCTIONS' "$fixture/listed.md"; then echo 'FAIL: a listed file kept its block' >&2; exit 1; fi
cmp "$fixture/cache/README.md" "$fixture/cache.before" || { echo 'FAIL: an unlisted file was edited' >&2; exit 1; }
# A directory is refused (exit 2), not walked.
rc=0; bash "$repo/scripts/rust-tool.sh" strip-instruction-blocks "$fixture/cache" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: a directory argument exited $rc, want 2" >&2; exit 1; }
cmp "$fixture/cache/README.md" "$fixture/cache.before" || { echo 'FAIL: a refused directory was edited' >&2; exit 1; }
# The compile cache is keyed by source content. Keyed by name with an mtime
# check, a second checkout whose tool source is OLDER on disk than the cached
# build ran the first checkout's binary. Two versions, one cache, v2 older:
cache_dir="$fixture/tool-cache"
for v in 1 2; do
    mkdir -p "$fixture/co$v/scripts"
    cp "$repo/scripts/rust-tool.sh" "$fixture/co$v/scripts/"
    printf 'fn main() { println!("v%s"); }\n' "$v" > "$fixture/co$v/scripts/probe-tool.rs"
done
touch -d '2001-01-01' "$fixture/co2/scripts/probe-tool.rs"
[ "$(RSR_MINT_TOOL_CACHE="$cache_dir" bash "$fixture/co1/scripts/rust-tool.sh" probe-tool)" = v1 ] \
    || { echo 'FAIL: the first version did not run' >&2; exit 1; }
[ "$(RSR_MINT_TOOL_CACHE="$cache_dir" bash "$fixture/co2/scripts/rust-tool.sh" probe-tool)" = v2 ] \
    || { echo 'FAIL: an older-mtime source ran the cached binary of another version' >&2; exit 1; }
[ "$(RSR_MINT_TOOL_CACHE="$cache_dir" bash "$fixture/co1/scripts/rust-tool.sh" probe-tool)" = v1 ] \
    || { echo 'FAIL: the first version lost its own binary' >&2; exit 1; }
echo 'PASS: selected ecosystems, nonempty updates, comment boundaries, idempotence, listed files only, content-keyed cache'
