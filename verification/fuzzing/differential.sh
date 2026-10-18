#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

# Optional external differential check. GNU converters are comparison tools,
# never the canonical oracle: binary and malformed UTF-8 inputs are skipped.
set -euo pipefail

input=${1:?usage: differential.sh FILE}
command -v dos2unix >/dev/null || { echo "dos2unix not installed; differential check unavailable" >&2; exit 2; }
command -v sholes >/dev/null || { echo "sholes not installed; build the CLI first" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sholes clean <"$input" >"$tmp/sholes"
dos2unix -q <"$input" >"$tmp/gnu"
if cmp -s "$tmp/sholes" "$tmp/gnu"; then
  echo "PASS: sholes and dos2unix agree for $input"
else
  echo "FAIL: differential mismatch for $input" >&2
  cmp -l "$tmp/sholes" "$tmp/gnu" | head -20 >&2 || true
  exit 1
fi
