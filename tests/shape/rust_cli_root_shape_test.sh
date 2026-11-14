#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# rust_cli_root_shape_test.sh — the rust-cli mint's root shape, against the REAL
# root allowlist and the REAL renderer (not copies of them).
#
#   1. Cargo.toml and Cargo.lock are '?'-optional in root-allow.txt: a rust-cli
#      mint carries them and must pass; the template (which has neither) must
#      still pass; and with the entries removed the mint shape must FAIL naming
#      them (the bidirectional gate can fire on this case).
#   2. mise.lock stays REQUIRED (no '?'), and render-mise.sh keeps the file when
#      an archetype changes the tool set: it prunes the pins of dropped tools
#      and keeps the pins of retained ones, instead of deleting the file.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# This test asserts the TEMPLATE's own root allowlist (the ?Cargo.toml entries of the
# rust-cli archetype). A repo minted from the template has its own allowlist, and a
# real Rust crate must keep Cargo.toml REQUIRED, so there the assertions do not apply.
if ! bash "$REPO/scripts/is-template-tree.sh" "$REPO"; then
    echo "SKIP: rust-cli root shape (not the template tree; is-template-tree.sh says no)"
    exit 0
fi
CHECKER="$REPO/scripts/check-root-shape.sh"
ALLOW="$REPO/.machine_readable/root-allow.txt"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# ── allowlist markers ───────────────────────────────────────────────────────
grep -qE '^\?Cargo\.toml([[:space:]]|$)' "$ALLOW" || fail "Cargo.toml is not a '?' optional entry"
grep -qE '^\?Cargo\.lock([[:space:]]|$)' "$ALLOW" || fail "Cargo.lock is not a '?' optional entry"
grep -qE '^mise\.lock([[:space:]]|$)' "$ALLOW" || fail "mise.lock must stay REQUIRED (no '?')"

# ── a fixture root satisfying the real allowlist ────────────────────────────
mk_root() { # <dir>: every REQUIRED entry of the real allowlist, nothing else
    local dir="$1" e
    mkdir -p "$dir/.machine_readable"
    cp "$ALLOW" "$dir/.machine_readable/root-allow.txt"
    git -C "$dir" init -q
    while IFS= read -r e; do
        case "$e" in
            '?'*) continue ;;
            */) mkdir -p "$dir/${e%/}" ;;
            *) mkdir -p "$dir/$(dirname "$e")"; : > "$dir/$e" ;;
        esac
    done < <(sed -E 's/[[:space:]]*#.*$//; s/[[:space:]]+$//' "$ALLOW" | awk 'NF')
}

T="$WORK/template"; mk_root "$T"
bash "$CHECKER" "$T" | grep -q '^PASS:' || fail "template-shaped root (no Cargo files) did not pass"

M="$WORK/mint"; mk_root "$M"
printf '[package]\nname = "x"\nversion = "0.1.0"\n' > "$M/Cargo.toml"
printf '# lock\n' > "$M/Cargo.lock"
bash "$CHECKER" "$M" | grep -q '^PASS:' || fail "rust-cli-shaped root (Cargo.toml + Cargo.lock) did not pass"

# Firing: with the entries absent from the allowlist the same root is drift.
grep -vE '^\?Cargo\.(toml|lock)' "$ALLOW" > "$M/.machine_readable/root-allow.txt"
if out=$(bash "$CHECKER" "$M" 2>&1); then fail "rust-cli root passed without the Cargo allow entries"; fi
grep -q 'Cargo.toml' <<<"$out" || fail "failure did not name Cargo.toml"
cp "$ALLOW" "$M/.machine_readable/root-allow.txt"

# A missing REQUIRED mise.lock is still drift (the rule was not loosened).
rm "$M/mise.lock"
if out=$(bash "$CHECKER" "$M" 2>&1); then fail "missing mise.lock did not fail the gate"; fi
grep -q 'mise.lock' <<<"$out" || fail "failure did not name mise.lock"

# ── render-mise.sh keeps (prunes) mise.lock when the tool set changes ──────
R="$WORK/render"
mkdir -p "$R/build/just"
cp "$REPO/build/just/provision-lib.sh" "$R/build/just/"
cp "$REPO/mise.toml" "$REPO/mise.lock" "$R/"
printf '[package]\nname = "x"\nversion = "0.1.0"\n' > "$R/Cargo.toml"
for tool in zig trivy; do
    grep -qF "[[tools.$tool]]" "$R/mise.lock" || fail "precondition: template lock does not pin $tool"
done
bash "$REPO/scripts/render-mise.sh" --root "$R" >/dev/null || fail "render-mise failed on a rust tree"
[ -s "$R/mise.lock" ] || fail "render-mise deleted mise.lock (root-allow.txt requires it)"
grep -qE '^rust = ' "$R/mise.toml" || fail "precondition: rust is not in the rendered toolchain"
grep -qE '^zig = ' "$R/mise.toml" && fail "precondition: zig is still declared"
for tool in zig trivy; do
    ! grep -qF "tools.$tool" "$R/mise.lock" || fail "lock still pins dropped tool $tool"
done
for tool in just shellcheck; do
    grep -qF "[[tools.$tool]]" "$R/mise.lock" || fail "lock lost the pin for retained tool $tool"
    grep -qE '^version = ' "$R/mise.lock" || fail "lock lost its concrete versions"
done
# The gap is visible, not silent: the newly declared rust tool is unpinned and
# the engine's own predicate says so.
if out=$(cd "$R" && PROVISION_ROOT="$R" bash build/just/provision-lib.sh mise-lock-gaps 2>&1); then
    fail "mise-lock-gaps did not report the unpinned rust tool"
fi
grep -q 'rust' <<<"$out" || fail "mise-lock-gaps did not name rust"
# Idempotent: a second render changes nothing.
cp "$R/mise.lock" "$WORK/lock.after1"
bash "$REPO/scripts/render-mise.sh" --root "$R" >/dev/null
cmp -s "$WORK/lock.after1" "$R/mise.lock" || fail "second render altered the pruned lock"

echo "PASS: rust-cli root shape (Cargo optional both ways, mise.lock required and kept)"
