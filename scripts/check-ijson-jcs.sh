#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Report or block JSON and JSON Lines files that are not I-JSON (RFC 7493) +
# JCS (RFC 8785) canonical, per metadatastician/standards 3-practice/JSON-POLICY.adoc
# (owner ruling D306) and DATA-FORMAT-ROUTING.adoc (transitional enforcement via
# hyperpolymath/ijson-jcs until a pinned metadatastician/kyq executable passes
# positive and negative tests).
#
# Usage: scripts/check-ijson-jcs.sh [--enforce] [PATH...]
#
# Exit contract (proven-tests-and-benches 3-outcome convention):
#   0 = pass (or report-only scan completed)
#   1 = --enforce found one or more non-canonical or invalid files
#   2 = setup/tooling error (missing binary, missing scan path): never a pass
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

enforce=0
if [ "${1:-}" = "--enforce" ]; then
  enforce=1
  shift
fi
if [ "$#" -eq 0 ]; then
  set -- .
fi

# Resolve the runner:
#   - When IJSON_JCS is explicitly provided by the caller, honour it strictly
#     (so a test passing IJSON_JCS=missing-bin gets exit 2, never a fallback).
#   - Otherwise prefer the compiled hyperpolymath/ijson-jcs binary on PATH, and
#     fall back to the local Bun RFC 7493/8785 implementation when offline.
RUNNER=()
RUNNER_STDIN=0
if [ -n "${IJSON_JCS:-}" ]; then
  if ! command -v "$IJSON_JCS" >/dev/null 2>&1; then
    printf '%s: not found; install hyperpolymath/ijson-jcs or set IJSON_JCS\n' "$IJSON_JCS" >&2
    exit 2
  fi
  RUNNER=("$IJSON_JCS")
elif [ "${IJSON_JCS_FORCE_JS:-0}" = "1" ] && command -v bun >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/ijson-jcs-cli.js" ]; then
  RUNNER=(bun "$SCRIPT_DIR/ijson-jcs-cli.js")
  RUNNER_STDIN=1
elif command -v ijson-jcs >/dev/null 2>&1; then
  RUNNER=(ijson-jcs)
elif command -v bun >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/ijson-jcs-cli.js" ]; then
  RUNNER=(bun "$SCRIPT_DIR/ijson-jcs-cli.js")
  RUNNER_STDIN=1
else
  printf 'ijson-jcs: neither ijson-jcs nor bun (for %s/ijson-jcs-cli.js) found\n' "$SCRIPT_DIR" >&2
  exit 2
fi

# A mistyped path must not turn into an empty, passing scan.
for path in "$@"; do
  if [ ! -e "$path" ]; then
    printf '%s: scan path does not exist\n' "$path" >&2
    exit 2
  fi
done

# list_files PATH... — emit NUL-delimited .json/.jsonl paths, pruning .git,
# node_modules, target, and _build directories.
list_files() {
  find "$@" \( -name .git -o -name node_modules -o -name target -o -name _build \) -prune \
    -o -type f \( -name '*.json' -o -name '*.jsonl' \) -print0
}

# is_jsonc_carve_out PATH — return 0 for devcontainer.json or .vscode JSON paths;
# return 1 otherwise.
is_jsonc_carve_out() {
  case "$1" in
    */devcontainer.json | devcontainer.json | */.vscode/*.json | .vscode/*.json)
      return 0
      ;;
  esac
  return 1
}

# classify_json FILE — print CANONICAL, NOT_CANONICAL, or INVALID using RUNNER.
# Canonical files require a final LF. Checker errors become INVALID verdicts.
classify_json() {
  local rc=0
  if [ "$RUNNER_STDIN" -eq 1 ]; then
    "${RUNNER[@]}" check <"$1" >/dev/null 2>&1 || rc=$?
  else
    "${RUNNER[@]}" check "$1" >/dev/null 2>&1 || rc=$?
  fi
  if [ "$rc" = 0 ] && [ "$(tail -c 1 "$1" | od -An -c | tr -d ' ')" != '\n' ]; then
    rc=1
  fi
  case "$rc" in
    0) echo CANONICAL ;;
    1) echo NOT_CANONICAL ;;
    *) echo INVALID ;;
  esac
}

# classify_jsonl FILE — print CANONICAL, NOT_CANONICAL, or INVALID for JSON Lines.
# Empty files are canonical; nonempty files require a final LF. Blank records
# or failed canonicalization yield INVALID; valid records must match JCS exactly.
classify_jsonl() {
  local file="$1" line canon verdict=CANONICAL
  if [ -s "$file" ] && [ "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" != '\n' ]; then
    verdict=NOT_CANONICAL
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      echo INVALID
      return
    fi
    if ! canon="$(printf '%s' "$line" | "${RUNNER[@]}" canon 2>/dev/null)"; then
      echo INVALID
      return
    fi
    if [ "$canon" != "$line" ]; then
      verdict=NOT_CANONICAL
    fi
  done <"$file"
  echo "$verdict"
}

total=0 canonical=0 noncanonical=0 invalid=0 skipped=0
while IFS= read -r -d '' file; do
  file="${file#./}"
  if is_jsonc_carve_out "$file"; then
    skipped=$((skipped + 1))
    continue
  fi
  total=$((total + 1))
  case "$file" in
    *.jsonl) verdict="$(classify_jsonl "$file")" ;;
    *) verdict="$(classify_json "$file")" ;;
  esac
  case "$verdict" in
    CANONICAL) canonical=$((canonical + 1)) ;;
    NOT_CANONICAL) noncanonical=$((noncanonical + 1)); printf 'NOT CANONICAL %s\n' "$file" ;;
    *) invalid=$((invalid + 1)); printf 'INVALID %s\n' "$file" ;;
  esac
done < <(list_files "$@" | sort -z)

summary="ijson-jcs: ${total} file(s) checked, ${canonical} canonical, ${noncanonical} not canonical, ${invalid} invalid; ${skipped} JSONC carve-out(s) skipped"
echo "$summary"
if [ -n "${GITHUB_ACTIONS:-}" ] && [ "$enforce" -eq 0 ]; then
  echo "::notice title=ijson-jcs (report-only)::${summary}. Fix with: ijson-jcs fix <file>"
fi
if [ "$enforce" -eq 1 ] && [ $((noncanonical + invalid)) -gt 0 ]; then
  exit 1
fi
exit 0
