#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# deed-clause.sh — the one WRITER for a deed's clauses (scripts/deed-field.sh is
# the reader). Every recipe that changes a deed at mint or setup time — the
# child's (rsr-profile) / (variant) / (provenance) clauses, groove-setup's port
# and API-surface flags — goes through here, so an edit is scoped to one clause
# and never a sed over the whole file.
#
# Usage:
#   deed-clause.sh get     DEED PATH            print the clause's source text
#   deed-clause.sh replace DEED PATH FILE|-     replace the clause with FILE's text
#                                               (FILE carries its own indentation)
#   deed-clause.sh append  DEED PATH FILE|-     add FILE's text as the clause's last child
#   deed-clause.sh set     DEED PATH KEY VALUE  replace the value of top-level :KEY
#
# PATH is slash-separated below the document root, exactly as deed-field.sh
# takes it; an empty PATH is the root form itself (append only). The root is
# the first form headed by an ABNF doc-head: repo-deed, praxis-deed,
# estate-deed or estate-atlas-deed.
#
# A clause's leading comments — the comment-only lines directly above its
# opening line, with no blank line between — belong to it: `get` prints them
# and `replace` swaps them out together with the clause, so rationale written
# for the template does not survive into a replacement.
#
# VALUE for `set` is a deed literal written as it appears in the file: a
# string with its quotes ("x"), an integer, #t / #f, or a bare symbol. It
# replaces a scalar value only; a list value is refused.
#
# Writes are atomic (temp file + mv) and the result is re-read with
# deed-field.sh before it replaces the deed: a write that leaves the form
# unreadable fails and leaves the deed untouched.
#
# Exit: 0 done; 1 clause or key absent; 2 usage error, unreadable deed or a
# result that does not re-read.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
op="${1:-}"; deed="${2:-}"; path="${3-}"
# usage — print the Usage block above to stderr and exit 2.
usage() { sed -n '12,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
case "$op" in get|replace|append|set) ;; *) usage ;; esac
[ -n "$deed" ] && [ -r "$deed" ] || { echo "deed-clause.sh: no readable deed: '$deed'" >&2; exit 2; }
key=""; value=""; text=""
case "$op" in
  replace|append)
    src="${4:-}"; [ -n "$src" ] || usage
    if [ "$src" = - ]; then text="$(cat)"; else text="$(cat "$src")"; fi ;;
  set)
    key="${4:-}"; value="${5-}"
    [ -n "$key" ] && [ -n "$value" ] || usage
    lit='^("([^"\\]|\\["\\nt])*"|#[tf]|-?[0-9]+|[A-Za-z][^ ()";]*)$'
    [[ "$value" =~ $lit ]] || { echo "deed-clause.sh: not a deed scalar literal: $value" >&2; exit 2; } ;;
esac
[ "$op" = append ] || [ -n "$path" ] || { echo "deed-clause.sh: $op needs a clause PATH" >&2; exit 2; }

# edit_deed -> the edited deed on stdout; exit 1 when PATH or KEY is absent
edit_deed() {
DC_TEXT="$text" DC_VALUE="$value" LC_ALL=C awk -v op="$op" -v path="$path" -v key="$key" '
BEGIN { RS = "\001"; text = ENVIRON["DC_TEXT"]; value = ENVIRON["DC_VALUE"] }
{
  s = $0; n = length(s); i = 1; nt = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == ";") { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
    if (c == "(" || c == ")") { nt++; tok[nt] = c; b[nt] = i; f[nt] = i; i++; continue }
    if (c == "\"") {
      st = i; i++
      while (i <= n) { c = substr(s, i, 1); if (c == "\\") { i += 2; continue }; if (c == "\"") break; i++ }
      nt++; tok[nt] = "S"; b[nt] = st; f[nt] = i; i++; continue
    }
    if (c == " " || c == "\t" || c == "\r" || c == "\n") { i++; continue }
    st = i; v = ""
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == " " || c == "\t" || c == "\r" || c == "\n" || c == "(" || c == ")" || c == "\"" || c == ";") break
      v = v c; i++
    }
    nt++; tok[nt] = "A" v; b[nt] = st; f[nt] = i - 1
  }
}
# close_of(o) — token index of the ")" that closes the form opened at token o; 0 if unbalanced.
function close_of(o,   d, t) {
  d = 0
  for (t = o; t <= nt; t++) {
    if (tok[t] == "(") d++
    else if (tok[t] == ")") { d--; if (d == 0) return t }
  }
  return 0
}
# child(o, name) — token index of the direct child form (name …) of the form at o; 0 if absent.
function child(o, name,   e, t, d) {
  e = close_of(o); d = 0
  for (t = o + 1; t < e; t++) {
    if (tok[t] == "(") { if (d == 0 && tok[t + 1] == "A" name) return t; d++ }
    else if (tok[t] == ")") d--
  }
  return 0
}
# Start offset of the clause opening at byte p: its line start when "(" begins
# its own line, widened over the leading comment-only lines directly above.
function lead(p,   ls, q, prev) {
  ls = p
  while (ls > 1 && substr(s, ls - 1, 1) != "\n") ls--
  if (substr(s, ls, p - ls) !~ /^[ ]*$/) return p
  while (ls > 1) {
    q = ls - 1; prev = q
    while (prev > 1 && substr(s, prev - 1, 1) != "\n") prev--
    if (substr(s, prev, q - prev) ~ /^[ ]*;/) ls = prev; else break
  }
  return ls
}
END {
  o = 0
  for (t = 1; t <= nt; t++)
    if (tok[t] == "(" && tok[t + 1] ~ /^A(repo-deed|praxis-deed|estate-deed|estate-atlas-deed)$/) { o = t; break }
  if (!o) exit 2
  if (path != "") {
    np = split(path, part, "/")
    for (p = 1; p <= np; p++) { o = child(o, part[p]); if (!o) exit 1 }
  }
  e = close_of(o); if (!e) exit 2
  if (op == "get") { st = lead(b[o]); printf "%s\n", substr(s, st, b[e] - st + 1); exit 0 }
  if (op == "replace") {
    st = lead(b[o])
    printf "%s%s%s", substr(s, 1, st - 1), text, substr(s, b[e] + 1); exit 0
  }
  if (op == "append") {
    # A closing ")" on its own line: the new child goes on the line above it.
    ls = b[e]; while (ls > 1 && substr(s, ls - 1, 1) != "\n") ls--
    if (substr(s, ls, b[e] - ls) ~ /^[ ]*$/) printf "%s%s\n%s", substr(s, 1, ls - 1), text, substr(s, ls)
    else printf "%s\n%s%s", substr(s, 1, b[e] - 1), text, substr(s, b[e])
    exit 0
  }
  d = 0
  for (t = o + 1; t < e; t++) {
    if (tok[t] == "(") { d++; continue }
    if (tok[t] == ")") { d--; continue }
    if (d != 0 || tok[t] != "A:" key) continue
    if (tok[t + 1] == "(" || tok[t + 1] == ")") exit 1
    printf "%s%s%s", substr(s, 1, b[t + 1] - 1), value, substr(s, f[t + 1] + 1); exit 0
  }
  exit 1
}
' "$deed"
}

if [ "$op" = get ]; then edit_deed; exit $?; fi
tmp="$(mktemp "${deed}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
rc=0; edit_deed > "$tmp" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
# The result must still read as one balanced form with the same root.
bash "$here/deed-field.sh" --has "$tmp" "" \
  || { echo "deed-clause.sh: $op left $(basename "$deed") unreadable; not written" >&2; exit 2; }
chmod --reference="$deed" "$tmp" 2>/dev/null || true
mv "$tmp" "$deed"
trap - EXIT
