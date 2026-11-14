#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# secret_scanner_contract_test.sh — the three scanner check contexts are this
# repository's own, stable, least-privileged and lockable.
#
# WHY THIS EXISTS, in one measurement.
#
# The estate canonical secret scanner is a single job-level call:
#
#     jobs:
#       scan:
#         uses: metadatastician/standards/.github/workflows/secret-scanner-reusable.yml@<sha>
#         secrets: inherit
#
# A reusable call reports `<caller job> / <called job>`, so that wrapper emits
# `scan / gitleaks`, `scan / rust-secrets` and `scan / shell-secrets` — good
# names — but they are produced by jobs defined in a REMOTE file. Three
# consequences, each observed:
#
#   1. `secrets: inherit` forwards every repository and organisation secret to
#      a scanner that declares no `workflow_call.secrets` and reads no
#      `secrets.*` (CWE-250). Measured across the estate on 2026-11-08:
#      hyperpolymath/modshells and hyperpolymath/docmatrix both carry it, and
#      docmatrix's header still claims inherit is REQUIRED. It is not.
#   2. Renaming a job inside the callee renames the caller's check contexts.
#      A required context that moves when someone edits another repository is
#      not a contract.
#   3. `gh actions-lock` cannot lock a job-level remote reusable. A hand-added
#      record for one is worse than none: present-but-unresolvable fails the
#      run at startup with zero jobs, absent is merely unverified. See the
#      header of scripts/check-lock-sync.sh.
#
# This repository therefore runs the same three scanners as ordinary inline
# jobs whose `name:` is the context. This test is the control that keeps it
# that way, and it is deliberately shaped as a SILENCE test (the shipped tree
# passes) plus FIRING tests (mutants fail), so it cannot pass vacuously.
#
# Checks, in order:
#   silence  shipped workflow: three jobs, exact names, read-only, no secrets:,
#            pinned actions, triggers on pull_request and on push to the
#            default branch, and a concurrency group
#   silence  every mapped required context resolves to a job of that name
#   silence  no workflow in the tree carries `secrets: inherit`
#   firing   each property above, mutated, fails the check
#   wiring   scripts/check-required-contexts.sh still certifies the real tree
#
# Usage: bash tests/workflows/secret_scanner_contract_test.sh
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF="$REPO_DIR/.github/workflows/secret-scanner.yml"
MAP="$REPO_DIR/.machine_readable/required-contexts-allow.txt"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() {
    fail=$((fail + 1))
    echo "  FAIL: $1" >&2
    [ -f "$WORK/why" ] && sed 's/^/        /' "$WORK/why" >&2
    echo "::error::secret-scanner contract test failed: $1" # NOSONAR
}

# check FILE — assert every contract property on a candidate workflow file.
# Writes the reason to $WORK/why on failure and returns non-zero.
check() {
    local f="$1" want ctx jobs out
    : > "$WORK/why"

    # 1. exactly the three scanner jobs, by exact name
    for ctx in "scan / gitleaks" "scan / rust-secrets" "scan / shell-secrets"; do
        if ! grep -qxF "    name: \"$ctx\"" "$f"; then
            echo "no job named exactly \"$ctx\"" >> "$WORK/why"
            return 1
        fi
    done
    want=3

    # 2. no OTHER `scan / …` context: a fourth scanner needs a deliberate edit
    #    here too, so a context cannot appear in a generated repo unnoticed.
    mapfile -t out < <(grep -oE '^    name: "scan / [a-z-]+"' "$f")
    if [ "${#out[@]}" -ne "$want" ]; then
        printf 'expected %s scan job(s), found %s: %s\n' \
            "$want" "${#out[@]}" "${out[*]}" >> "$WORK/why"
        return 1
    fi

    # 3. a job-level remote reusable call would make the names remote: refuse
    if grep -qE '^[[:space:]]+uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/' "$f"; then
        echo "job-level remote reusable call: the check names would belong to the callee" >> "$WORK/why"
        return 1
    fi

    # 4. least privilege: workflow AND every job is contents: read only
    if ! grep -qxE 'permissions:' "$f"; then
        echo "no top-level permissions:" >> "$WORK/why"
        return 1
    fi
    if grep -qE '^[[:space:]]+(actions|checks|pull-requests|issues|statuses|packages|id-token|pages|deployments):' "$f"; then
        echo "a job or the workflow grants more than contents: read" >> "$WORK/why"
        return 1
    fi

    # 5. no secret access of any kind
    if grep -qE '^[[:space:]]*secrets:' "$f"; then
        echo "the workflow passes secrets: to a scanner that declares none" >> "$WORK/why"
        return 1
    fi
    if grep -qE 'secrets\.[A-Za-z_]' "$f"; then
        echo "the workflow reads a secrets.* context" >> "$WORK/why"
        return 1
    fi

    # 6. every uses: is a full 40-hex pin (the lock then has nothing to
    #    invent, and a tag cannot move under the run)
    if grep -nE '^[[:space:]]+-?[[:space:]]*uses:' "$f" | grep -vE '@[0-9a-f]{40}([[:space:]]*#.*)?$' > "$WORK/unpinned" 2>/dev/null; then
        echo "uses: refs that are not 40-hex pins:" >> "$WORK/why"
        cat "$WORK/unpinned" >> "$WORK/why"
        return 1
    fi

    # 7. triggers: pull_request bare (every PR, no path filter) and push to the
    #    real default branch. main is this repository's default branch; master
    #    is not, so it must not be the only value.
    grep -qE '^  pull_request:' "$f" || { echo "no pull_request trigger" >> "$WORK/why"; return 1; }
    grep -qE '^  push:' "$f" || { echo "no push trigger" >> "$WORK/why"; return 1; }
    grep -qE '^[[:space:]]+branches:.*\bmain\b' "$f" \
        || { echo "push does not target main (the default branch)" >> "$WORK/why"; return 1; }

    # 8. concurrency: a superseded PR scan must not keep burning a runner
    grep -qE '^concurrency:' "$f" || { echo "no concurrency group" >> "$WORK/why"; return 1; }
    grep -qE '^[[:space:]]+cancel-in-progress:[[:space:]]*true' "$f" \
        || { echo "concurrency does not cancel superseded runs" >> "$WORK/why"; return 1; }

    return 0
}

echo "=== 1. The workflow as it ships ==="
if check "$WF"; then ok "shipped secret-scanner.yml satisfies the three-context contract"; else bad "shipped secret-scanner.yml violates the contract"; fi

echo "=== 2. Every mapped context has a job of exactly that name ==="
if [ ! -f "$MAP" ]; then
    bad "mapping file $MAP is missing"
else
    mapped=0
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        ctx="${line%%=>*}"
        wf="${line##*=>}"
        ctx="$(printf '%s' "$ctx" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        wf="$(printf '%s' "$wf" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        mapped=$((mapped + 1))
        if [ ! -f "$REPO_DIR/$wf" ]; then
            bad "mapped context '$ctx' names missing workflow '$wf'"
            continue
        fi
        if grep -qxF "    name: \"$ctx\"" "$REPO_DIR/$wf" || grep -qxF "  name: \"$ctx\"" "$REPO_DIR/$wf"; then
            ok "mapped context '$ctx' is a job name in $wf"
        else
            bad "mapped context '$ctx' has no job of that name in $wf"
        fi
    done < "$MAP"
    [ "$mapped" -ge 3 ] && ok "$mapped required context(s) mapped" \
        || bad "only $mapped context(s) mapped; all three scanner jobs should be"
fi

echo "=== 3. No workflow passes secrets: inherit ==="
if hits="$(grep -rn '^[[:space:]]*secrets:[[:space:]]*inherit' "$REPO_DIR/.github/workflows/" 2>/dev/null)"; then
    printf '%s\n' "$hits" > "$WORK/why"
    bad "a workflow forwards every secret with secrets: inherit"
else
    ok "no workflow passes secrets: inherit"
fi

echo "=== 4. Firing: each contract property, mutated, is caught ==="
mutate() { # mutate LABEL SED-EXPR
    cp "$WF" "$WORK/m.yml"
    sed -i "$2" "$WORK/m.yml"
    if cmp -s "$WF" "$WORK/m.yml"; then
        bad "$1: the mutation changed nothing (control is wrong, not the tree)"
        return
    fi
    if check "$WORK/m.yml"; then
        bad "$1: the mutant passed the contract check"
    else
        ok "$1: caught"
    fi
}

mutate "a renamed scanner job" 's|    name: "scan / rust-secrets"|    name: "scan / rust-secrets-v2"|'
mutate "a missing scanner job" '/^  rust-secrets:$/,/^  shell-secrets:$/{/^  shell-secrets:$/!d}'
mutate "secrets: inherit added" 's|^    permissions:$|    secrets: inherit\n    permissions:|'
mutate "a secrets.* read added" 's|^          set -euo pipefail$|          set -euo pipefail; echo "${{ secrets.TOKEN }}"|'
mutate "a broader permission granted" 's|^permissions:$|permissions:\n  actions: read|'
mutate "an unpinned action" 's|@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1|@v7.0.1|'
mutate "push no longer targets the default branch" 's|^    branches: \[main\]$|    branches: [master]|'
mutate "no pull_request trigger" 's|^  pull_request:$|  schedule:|'
mutate "no concurrency group" 's|^concurrency:$|# concurrency:|'
mutate "a job-level remote reusable call" \
    's|^  shell-secrets:$|  delegated:\n    permissions:\n      contents: read\n    uses: metadatastician/standards/.github/workflows/secret-scanner-reusable.yml@f0b3cd4c464d33e1584f8528c17bce104555e256\n  shell-secrets:|'

echo "=== 5. Wire-up: the real tree still certifies all three contexts ==="
if command -v bun >/dev/null 2>&1; then
    if bash "$REPO_DIR/scripts/check-required-contexts.sh" "$REPO_DIR" > "$WORK/rc.log" 2>&1; then
        if grep -q '3 required status context' "$WORK/rc.log"; then
            ok "check-required-contexts.sh certifies 3 contexts on the real tree"
        else
            cp "$WORK/rc.log" "$WORK/why"
            bad "check-required-contexts.sh passed but certified a different count"
        fi
    else
        cp "$WORK/rc.log" "$WORK/why"
        bad "check-required-contexts.sh fails on the real tree"
    fi
else
    echo "  SKIP: bun is not installed, so check-required-contexts.sh cannot parse YAML"
fi

echo ""
if [ "$fail" -ne 0 ]; then
    echo "FAIL: secret scanner contract suite (${pass} passed, ${fail} failed)" >&2
    exit 1
fi
echo "PASS: secret scanner contract suite (${pass} checks)"
