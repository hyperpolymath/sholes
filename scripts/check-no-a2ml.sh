#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-no-a2ml.sh — enforce the estate rule that no .a2ml file exists. The
# format is retired: a repo's facts are clauses of its deed (<repo>_chora.deed,
# deed.abnf) and its contracts are .k9 / .k9.ncl files.
#
# Usage: check-no-a2ml.sh [REPO_ROOT]
# Inspects tracked files when REPO_ROOT is a git work tree, and every file
# under it (minus .git/) otherwise, so an untracked mint is covered too.
# Exit: 0 none found; 1 one or more .a2ml files (listed); 2 bad path.
set -euo pipefail

REPO_ROOT="${1:-.}"
[ -d "$REPO_ROOT" ] || { echo "ERROR: repository path does not exist: $REPO_ROOT" >&2; exit 2; }

if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  FOUND=$(git -C "$REPO_ROOT" ls-files -- '*.a2ml' '*.A2ML')
else
  FOUND=$(find "$REPO_ROOT" -path '*/.git' -prune -o -type f -iname '*.a2ml' -printf '%P\n')
fi

if [ -z "$FOUND" ]; then
  echo "PASS: no .a2ml files in the inspected repository"
  exit 0
fi
echo "FAIL: .a2ml is a retired format; move these facts into the repo deed or a .k9 contract:"
printf '  %s\n' $FOUND
exit 1
