#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Controls for scripts/check-no-a2ml.sh: a clean tree passes, and a planted
# .a2ml — tracked, upper-case, or in an untracked non-git tree — fails and is
# named. Without the planted positives a PASS would prove nothing.
set -euo pipefail

CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/check-no-a2ml.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

# expect_fail DIR NAME — the checker must reject DIR and name NAME in its output.
expect_fail() {
  if bash "$CHECKER" "$1" > "$FIXTURE/out" 2>&1; then
    echo "FAIL: checker accepted a tree carrying $2" >&2; exit 1
  fi
  grep -qF "$2" "$FIXTURE/out" || { echo "FAIL: checker did not name $2" >&2; cat "$FIXTURE/out" >&2; exit 1; }
}

REPO="$FIXTURE/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
printf '(repo-deed)\n' > "$REPO/x_chora.deed"
git -C "$REPO" add x_chora.deed
bash "$CHECKER" "$REPO" | grep -q '^PASS:'

mkdir -p "$REPO/.machine_readable/descriptiles"
printf '[x]\n' > "$REPO/.machine_readable/descriptiles/STATE.a2ml"
git -C "$REPO" add .machine_readable
expect_fail "$REPO" ".machine_readable/descriptiles/STATE.a2ml"
git -C "$REPO" rm -q --cached -r .machine_readable && rm -rf "$REPO/.machine_readable"

printf '[x]\n' > "$REPO/AI.A2ML"
git -C "$REPO" add AI.A2ML
expect_fail "$REPO" "AI.A2ML"

PLAIN="$FIXTURE/plain"; mkdir -p "$PLAIN/sub"
printf '[x]\n' > "$PLAIN/sub/ANCHOR.a2ml"
expect_fail "$PLAIN" "sub/ANCHOR.a2ml"
rm "$PLAIN/sub/ANCHOR.a2ml"
bash "$CHECKER" "$PLAIN" | grep -q '^PASS:'

echo "PASS: check-no-a2ml controls (clean, tracked, upper-case, untracked)"
