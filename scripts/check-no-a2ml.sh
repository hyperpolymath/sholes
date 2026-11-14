#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-no-a2ml.sh — enforce the estate rule that no .a2ml file exists. The
# format is retired: a repo's facts are clauses of its deed (<repo>_chora.deed,
# deed.abnf) and its contracts are .k9 / .k9.ncl files.
#
# A repository that still carries legacy A2ML lists each file, by exact path,
# in the shrink-only ledger .machine_readable/a2ml-legacy-allow.txt (owner
# decision 2026-11-04); listed files and anything under 9-archive/ are not
# reported here. The ledger's own integrity (a listed file that is gone, a
# glob entry, an entry the base ledger did not list) is the canonical gate's
# job, standards scripts/check-a2ml-archived.sh, run by the deed lane
# (.github/hooks/validate-deed.sh).
#
# Usage: check-no-a2ml.sh [REPO_ROOT]
# Inspects tracked and untracked (not ignored) files when REPO_ROOT is a git work tree, and every file
# under it (minus .git/) otherwise, so an untracked mint is covered too.
# Exit: 0 none found; 1 one or more .a2ml files (listed); 2 bad path.
set -euo pipefail

REPO_ROOT="${1:-.}"
[ -d "$REPO_ROOT" ] || { echo "ERROR: repository path does not exist: $REPO_ROOT" >&2; exit 2; }

if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Tracked and untracked (not ignored) files, any case of the extension,
  # NUL-delimited so no path is quoted; a tracked file already deleted from
  # the work tree is not a file in it.
  FOUND=$(git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard -- ':(icase)*.a2ml' \
    | while IFS= read -r -d '' f; do [ -e "$REPO_ROOT/$f" ] && printf '%s\n' "$f"; done | sort -u)
else
  # Portable find (no GNU -printf): paths relative to REPO_ROOT.
  FOUND=$(cd "$REPO_ROOT" && find . -path ./.git -prune -o -type f -iname '*.a2ml' -print | sed 's#^\./##')
fi

LEDGER="$REPO_ROOT/.machine_readable/a2ml-legacy-allow.txt"
if [ -n "$FOUND" ]; then
  FOUND=$(printf '%s\n' "$FOUND" | grep -v '^9-archive/' || true)
fi
if [ -n "$FOUND" ] && [ -f "$LEDGER" ]; then
  LISTED=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$LEDGER" | grep -v '^$' || true)
  FOUND=$(printf '%s\n' "$FOUND" | grep -vxF -f <(printf '%s\n' "$LISTED") || true)
fi

if [ -z "$FOUND" ]; then
  echo "PASS: no .a2ml files outside the legacy ledger and 9-archive/"
  exit 0
fi
echo "FAIL: .a2ml is a retired format; move these facts into the repo deed or a .k9 contract (or, for a file that predates the ledger, list it in .machine_readable/a2ml-legacy-allow.txt):"
printf '%s\n' "$FOUND" | sed 's/^/  /'
exit 1
