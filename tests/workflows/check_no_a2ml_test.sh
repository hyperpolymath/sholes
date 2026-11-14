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

# Shrink-only ledger: a listed file passes, an unlisted one beside it still
# fails, and 9-archive/ is out of scope.
git -C "$REPO" rm -q --cached AI.A2ML && rm "$REPO/AI.A2ML"
mkdir -p "$REPO/.machine_readable" "$REPO/9-archive/old"
printf '[x]\n' > "$REPO/LISTED.a2ml"
printf '[x]\n' > "$REPO/9-archive/old/ARCHIVED.a2ml"
printf '# ledger\nLISTED.a2ml  # waiting for kyX\n' > "$REPO/.machine_readable/a2ml-legacy-allow.txt"
git -C "$REPO" add LISTED.a2ml 9-archive .machine_readable
bash "$CHECKER" "$REPO" | grep -q '^PASS:'
printf '[x]\n' > "$REPO/NEW.a2ml"
git -C "$REPO" add NEW.a2ml
expect_fail "$REPO" "NEW.a2ml"

git -C "$REPO" rm -q --cached NEW.a2ml && rm "$REPO/NEW.a2ml"

# In a git work tree: an untracked file is still a file in the tree, the
# extension is matched in any case, and a tracked file already deleted from
# the work tree is not reported.
printf '[x]\n' > "$REPO/UNTRACKED.a2ml"
expect_fail "$REPO" "UNTRACKED.a2ml"
rm "$REPO/UNTRACKED.a2ml"
printf '[x]\n' > "$REPO/Mixed.A2ml"
git -C "$REPO" add Mixed.A2ml
expect_fail "$REPO" "Mixed.A2ml"
git -C "$REPO" rm -q --cached Mixed.A2ml && rm "$REPO/Mixed.A2ml"
printf '[x]\n' > "$REPO/GONE.a2ml"
git -C "$REPO" add GONE.a2ml && rm "$REPO/GONE.a2ml"
bash "$CHECKER" "$REPO" | grep -q '^PASS:' || { echo "FAIL: a deleted tracked file was reported" >&2; exit 1; }

PLAIN="$FIXTURE/plain"; mkdir -p "$PLAIN/sub"
printf '[x]\n' > "$PLAIN/sub/ANCHOR.a2ml"
expect_fail "$PLAIN" "sub/ANCHOR.a2ml"
rm "$PLAIN/sub/ANCHOR.a2ml"
bash "$CHECKER" "$PLAIN" | grep -q '^PASS:'

echo "PASS: check-no-a2ml controls (clean, tracked, upper-case, untracked, ledger)"
