#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# archetype_lock_merge_test.sh — an archetype's workflows reach a minted repo
# with their lock records, and the spine's workflows keep theirs.
#
# The julia-library overlay used to carry a whole actions.lock, and the
# overlay copy in `just repo-init` replaced the spine's lock with it. Every
# Julia mint (ZeroInflatedCounts.jl, ResidualEvidenceTypes.jl) began with Lock
# Sync red and its workflows refused at startup. The records now ship as
# archetypes/<name>/actions.lock and repo-init merges them in.
#
# Each check runs on a mint-shaped workflow directory: the spine's workflows
# plus the overlay's, under their minted names, with the lock repo-init writes.
#
#   positive    the merged lock passes scripts/check-lock-sync.sh
#   negative    the old shape (the fragment alone, as the copy left it) fails
#   negative    the merged lock minus one record the fragment added fails
#   negative    a fragment record that differs from the base's is refused,
#               and the base is left untouched
#   identity    merging an empty fragment rewrites the spine lock byte for byte
#   idempotent  merging the fragment twice changes nothing
#   wiring      build/just/repo-init.just still invokes the merge, and renames
#               each overlay .in workflow (GitHub never runs a .in file)
#   shape       no overlay carries .github/workflows/actions.lock
#   headers     each overlay workflow passes workflow-linter.yml's SPDX and
#               top-level permissions predicates, which a minted repo runs
#
# A minted repo keeps this test and estate-rules.yml but not archetypes/,
# which repo-init deletes once the merge is done; there it skips.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
if [ ! -d "$repo/archetypes" ]; then
    echo "SKIP: no archetypes/ here, so this is a minted repo; its lock was merged at mint and Lock Sync checks it"
    exit 0
fi
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
spine_lock="$repo/.github/workflows/actions.lock"

# Merge a lock fragment into a base lock in place, as `just repo-init` does.
merge() { bash "$repo/scripts/rust-tool.sh" merge-actions-lock "$@" >/dev/null; }

# Succeed when the workflow directory's lock passes check-lock-sync.sh.
lock_ok() { bash "$repo/scripts/check-lock-sync.sh" "$1" >"$fixture/sync.log" 2>&1; }

# Succeed when the file's leading comment block carries an SPDX line
# (workflow-linter.yml, "Check SPDX Headers", verbatim).
spdx_ok() { awk '/^# SPDX-License-Identifier:/ { found=1 } /^[^#[:space:]]/ { exit } END { exit !found }' "$1"; }

# Succeed when the file declares top-level permissions
# (workflow-linter.yml, "Check permissions", verbatim).
perms_ok() { grep -q "^permissions:" "$1"; }

# Print a failure and stop the test.
fail() { echo "FAIL: $*" >&2; exit 1; }

# The two header predicates must be able to fail before their passes count.
printf 'name: bare\non: push\njobs: {}\n' > "$fixture/bare.yml"
if spdx_ok "$fixture/bare.yml" || perms_ok "$fixture/bare.yml"; then
    fail "header predicates accept a workflow with no SPDX line and no permissions"
fi

# The identity control: the rewrite must be faithful to gh actions-lock's own
# layout, or every merge would show up as a diff of the whole spine lock.
{ grep -m1 '^version:' "$spine_lock"; echo 'workflows: {}'; echo 'dependencies: {}'; } > "$fixture/empty.lock"
cp "$spine_lock" "$fixture/identity.lock"
merge "$fixture/identity.lock" "$fixture/empty.lock"
cmp -s "$fixture/identity.lock" "$spine_lock" || fail "an empty merge rewrote the spine lock"

# Everything below reproduces the mint's lock step, so repo-init must still
# be the thing that runs it.
grep -q 'scripts/rust-tool.sh merge-actions-lock' "$repo/build/just/repo-init.just" \
    || fail "build/just/repo-init.just no longer merges archetype lock fragments"

shopt -s nullglob
checked=0
for arch in "$repo"/archetypes/*/; do
    name=$(basename "$arch")
    overlay_wf="${arch}overlay/.github/workflows"
    [ ! -e "$overlay_wf/actions.lock" ] \
        || fail "$name: overlay ships .github/workflows/actions.lock, which replaces the spine's lock at mint; move it to archetypes/$name/actions.lock"
    wfs=("$overlay_wf"/*.yml.in "$overlay_wf"/*.yml "$overlay_wf"/*.yaml.in "$overlay_wf"/*.yaml)
    [ ${#wfs[@]} -gt 0 ] || continue
    frag="${arch}actions.lock"
    [ -f "$frag" ] || fail "$name: overlay ships workflows but archetypes/$name/actions.lock is missing"
    checked=$((checked + 1))

    for f in "${wfs[@]}"; do
        spdx_ok "$f" || fail "$name: ${f#"$repo"/} has no SPDX line in its leading comment block"
        perms_ok "$f" || fail "$name: ${f#"$repo"/} has no top-level permissions"
        case "$f" in
            *.in) grep -qF ".github/workflows/$(basename "$f")" "$repo/build/just/repo-init.just" \
                || fail "$name: build/just/repo-init.just never renames ${f#"$repo"/}, so the minted workflow keeps its .in suffix and never runs" ;;
        esac
    done

    # The mint: spine workflows and lock, then the overlay's workflows under
    # their minted names, then the merge.
    minted="$fixture/$name/minted/.github/workflows"
    mkdir -p "$minted"
    cp -a "$repo/.github/workflows/." "$minted/"
    for f in "${wfs[@]}"; do b=$(basename "$f"); cp "$f" "$minted/${b%.in}"; done
    merge "$minted/actions.lock" "$frag"
    lock_ok "$minted" || { cat "$fixture/sync.log" >&2; fail "$name: merged lock fails check-lock-sync.sh"; }

    cp "$minted/actions.lock" "$fixture/once.lock"
    merge "$minted/actions.lock" "$frag"
    cmp -s "$minted/actions.lock" "$fixture/once.lock" || fail "$name: a second merge changed the lock"

    # The old defect: the fragment alone stands where the spine's lock was.
    clobbered="$fixture/$name/clobbered/.github/workflows"
    mkdir -p "$clobbered"
    cp -a "$minted/." "$clobbered/"
    cp "$frag" "$clobbered/actions.lock"
    if lock_ok "$clobbered"; then fail "$name: check-lock-sync.sh passes a lock that lost the spine's records"; fi

    # Drop one dependency record that only the fragment supplies.
    dep=""
    while IFS= read -r key; do
        grep -qxF "$key" "$spine_lock" || { dep="$key"; break; }
    done < <(awk '/^dependencies:/ { d = 1; next } d && /^    \x27/' "$frag")
    [ -n "$dep" ] || fail "$name: the fragment adds no dependency record, so the missing-record control cannot be planted"
    missing="$fixture/$name/missing/.github/workflows"
    mkdir -p "$missing"
    cp -a "$minted/." "$missing/"
    awk -v k="$dep" '$0 == k { skip = 1; next } skip && /^        / { next } { skip = 0; print }' \
        "$minted/actions.lock" > "$missing/actions.lock"
    ! cmp -s "$missing/actions.lock" "$minted/actions.lock" || fail "$name: the missing-record mutant is identical to the merged lock"
    if lock_ok "$missing"; then fail "$name: check-lock-sync.sh passes a lock missing $dep"; fi

    # A fragment whose record disagrees with the base's must stop the mint.
    sed "0,/^        commit: /s/^\(        commit: \).*/\1'sha1-0000000000000000000000000000000000000000'/" \
        "$frag" > "$fixture/conflict.lock"
    ! cmp -s "$fixture/conflict.lock" "$frag" || fail "$name: the conflict mutant is identical to the fragment"
    if bash "$repo/scripts/rust-tool.sh" merge-actions-lock "$minted/actions.lock" "$fixture/conflict.lock" 2>"$fixture/conflict.err" >/dev/null; then
        fail "$name: a conflicting record merged without error"
    fi
    grep -q 'differs from the base' "$fixture/conflict.err" || { cat "$fixture/conflict.err" >&2; fail "$name: the conflict was refused for the wrong reason"; }
    cmp -s "$minted/actions.lock" "$fixture/once.lock" || fail "$name: a refused merge changed the base lock"
done

[ "$checked" -gt 0 ] || fail "no archetype ships workflows, so nothing here was checked"
echo "PASS: $checked archetype(s): merged locks pass check-lock-sync, the clobber and missing-record mutants fail, conflicts are refused, merges are faithful and idempotent, overlay headers pass the linter"
