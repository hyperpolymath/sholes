#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# The honesty lint (from hyperpolymath/proven-tests-and-benches): fail if any
# proof escape hatch appears in Idris2 sources or if '%default total' is absent
# or placed after a declaration.
#
# Exit codes (proven-tests-and-benches 3-outcome convention):
#   0  no escape hatches found across >= 1 .idr file
#   1  at least one escape hatch or missing/misplaced '%default total' found
#   2  the scan could not be performed (missing/unreadable directory or 0 .idr
#      files — a skip is NOT a pass)
set -uo pipefail

if [ "$#" -gt 0 ]; then
  SCOPE=("$@")
else
  SCOPE=(src verification .machine_readable/coaptation)
fi

LITERAL_PATTERNS='believe_me|assert_total|assert_smaller|%partial|%default (partial|covering)|unsafePerformIO|idris_crash'
PARTIAL_DECL='^[[:space:]]*((public )?export[[:space:]]+|private[[:space:]]+)?partial([[:space:]]|$)'
COVERING_DECL='^[[:space:]]*((public )?export[[:space:]]+|private[[:space:]]+)?covering([[:space:]]|$)'
COVERING_ALLOWED=()
HOLE_PATTERN='(^|[[:space:](=,[])\?[a-zA-Z_][a-zA-Z0-9_'"'"']*'

missing=0
for dir in "${SCOPE[@]}"; do
  if [ ! -d "$dir" ]; then
    echo "check-escape-hatches: scope directory '$dir' does not exist" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "FAIL: NO SCAN WAS PERFORMED — the scan scope is incomplete." >&2
  echo "      A missing directory is not a clean result." >&2
  exit 2
fi

FIND_OUT="$(mktemp)"
trap 'rm -f "$FIND_OUT"' EXIT
if ! find "${SCOPE[@]}" -name '*.idr' -type f > "$FIND_OUT"; then
  echo "check-escape-hatches: find failed while scanning scope (${SCOPE[*]})" >&2
  echo "FAIL: NO SCAN WAS PERFORMED — an unreadable directory is not a clean result." >&2
  exit 2
fi
mapfile -t IDR_FILES < <(LC_ALL=C sort "$FIND_OUT")
if [ "${#IDR_FILES[@]}" -eq 0 ]; then
  echo "check-escape-hatches: 0 .idr files found in scope (${SCOPE[*]})" >&2
  echo "FAIL: NO SCAN WAS PERFORMED — an empty proof corpus is not a pass." >&2
  exit 2
fi

echo "Scanning ${#IDR_FILES[@]} Idris2 file(s) for proof escape hatches in: ${SCOPE[*]}"

hits=0

# Strip line and nested block comments once per file (preserving quoted comment
# markers inside Idris strings and exact line numbers) for all passes.
STRIP_DIR="$(mktemp -d)"
trap 'rm -f "$FIND_OUT"; rm -rf "$STRIP_DIR"' EXIT

# strip_idr_comments FILE — print source without line/doc or nested block comments,
# preserving line numbers and quoted comment markers in string literals.
strip_idr_comments() {
  awk '
    BEGIN { bs = sprintf("%c", 92); dq = sprintf("%c", 34); depth = 0 }
    depth == 0 && /^[[:space:]]*\|\|\|/ { print ""; next }
    depth == 0 && index($0, "--") == 0 && index($0, "{-") == 0 { print; next }
    {
      out = ""; in_str = 0; n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (depth > 0) {
          if (c == "{" && i < n && substr($0, i + 1, 1) == "-") { depth++; i++ }
          else if (c == "-" && i < n && substr($0, i + 1, 1) == "}") { depth--; i++ }
          out = out " "
        } else if (in_str) {
          out = out c
          if (c == bs && i < n) {
            i++
            out = out substr($0, i, 1)
          } else if (c == dq) {
            in_str = 0
          }
        } else {
          if (c == "{" && i < n && substr($0, i + 1, 1) == "-") {
            depth++
            i++
            out = out " "
          } else if (c == dq) {
            in_str = 1
            out = out c
          } else if (c == "-" && i < n && substr($0, i + 1, 1) == "-") {
            break
          } else {
            out = out c
          }
        }
      }
      print out
    }
  ' "$1"
}

declare -A STRIPPED_FILE=()
idx_f=0
for f in "${IDR_FILES[@]}"; do
  idx_f=$((idx_f + 1))
  sf="$STRIP_DIR/$idx_f.idr"
  strip_idr_comments "$f" > "$sf"
  STRIPPED_FILE["$f"]="$sf"
done

# scan_idr_code REGEX — print matching stripped lines as file:line:code.
# Scan IDR_FILES via STRIPPED_FILE; return 0 if any line matches, 1 otherwise.
scan_idr_code() {
  local pattern="$1" f line_no=0 found=0
  for f in "${IDR_FILES[@]}"; do
    line_no=0
    while IFS= read -r code || [ -n "$code" ]; do
      line_no=$((line_no + 1))
      if [[ "$code" =~ $pattern ]]; then
        printf '%s:%d:%s\n' "$f" "$line_no" "$code"
        found=1
      fi
    done < "${STRIPPED_FILE[$f]}"
  done
  return $(( 1 - found ))
}

if scan_idr_code "$LITERAL_PATTERNS"; then
  hits=1
fi

if scan_idr_code "$HOLE_PATTERN"; then
  hits=1
fi

if scan_idr_code "$PARTIAL_DECL"; then
  hits=1
fi

for f in "${IDR_FILES[@]}"; do
  sf="${STRIPPED_FILE[$f]}"
  mapfile -t cov_lines < "$sf"
  for (( idx = 0; idx < ${#cov_lines[@]}; idx++ )); do
    code="${cov_lines[$idx]}"
    if [[ "$code" =~ $COVERING_DECL ]]; then
      line_no=$((idx + 1))
      next_line="${cov_lines[$((idx + 1))]:-}"
      name="$(printf '%s\n' "$next_line" | sed -E 's/^[[:space:]]*([^[:space:]:]+).*/\1/')"
      allowed=0
      for pair in "${COVERING_ALLOWED[@]}"; do
        [ "$pair" = "$f:$name" ] && allowed=1
      done
      if [ "$allowed" -eq 0 ]; then
        echo "$f:$line_no: covering $name is not on the I/O allowlist"
        hits=1
      fi
    fi
  done
done

# Require '%default total' to appear and precede all value/type declarations
# (only blank lines, comments, module headers, imports, namespaces, or benign
# compiler pragmas %hide/%logging/%unbound_implicits may precede it).
for f in "${IDR_FILES[@]}"; do
  status="$(awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*(module|import|namespace)[[:space:]]/ { next }
    /^[[:space:]]*%(hide|logging|unbound_implicits|auto_implicit_depth)([[:space:]]|$)/ { next }
    /^[[:space:]]*%default total([[:space:]]|$)/ {
      if (saw_decl) { print "after_decl"; printed = 1; exit }
      saw_total = 1
      next
    }
    { if (!saw_total) saw_decl = 1 }
    END {
      if (!printed) {
        if (!saw_total) print "missing"
        else print "ok"
      }
    }
  ' "${STRIPPED_FILE[$f]}")"
  case "$status" in
    missing)
      echo "$f: missing '%default total'"
      hits=1
      ;;
    after_decl)
      echo "$f: '%default total' appears after a declaration (earlier definitions default to covering)"
      hits=1
      ;;
  esac
done

if [ "$hits" -ne 0 ]; then
  echo
  echo "FAIL: proof escape hatch found. Actually-Proven content may not use these."
  echo "      Banned: believe_me, assert_total, assert_smaller, %partial,"
  echo "              %default partial|covering, partial declarations,"
  echo "              covering outside the I/O allowlist,"
  echo "              unsafePerformIO, idris_crash, and hole syntax (?name)."
  echo "      Required: '%default total' before all declarations in every .idr file."
  exit 1
fi

echo "OK: no proof escape hatches across ${#IDR_FILES[@]} file(s) in ${SCOPE[*]}"
