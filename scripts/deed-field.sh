#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# deed-field.sh — read one field out of a deed (<repo>_chora.deed, or any
# *_praxis.deed: the root is the first form with an ABNF doc-head).
#
# The repo deed holds what the descriptiles CLADE / META / ECOSYSTEM / STATE /
# AGENTIC .a2ml files used to hold (rsr-template-repo#209). This is the one
# shell reader for it, so that every gate, extractor and recipe asks the same
# question the same way. It is a READER: it never writes the deed.
#
# Usage:
#   deed-field.sh DEED PATH KEY           first value of :KEY in the clause at PATH
#   deed-field.sh --list DEED PATH KEY    the items of the list :KEY ( … ), one per line
#   deed-field.sh --clause DEED PATH      the clause, one token per line (for hashing)
#   deed-field.sh --kv DEED PATH          every top-level :KEY of the clause in ONE pass, as
#                                         KEY<TAB>item lines (a list prints one line per item,
#                                         a scalar one line, as --list / the plain form would).
#                                         For a gate that needs several fields: each separate
#                                         call re-tokenises the whole deed.
#   deed-field.sh --has DEED PATH         exit 0 iff the clause exists
#   deed-field.sh --strict DEED           exit 0 iff the deed is exactly one balanced form:
#                                         nothing but whitespace and comments before or after
#                                         it ("trailing content after the form's closing ')'"
#                                         in deed_lint.js); the other modes read the first
#                                         form and ignore the rest. It checks token boundaries
#                                         only and is no substitute for the linter, which also
#                                         refuses a tab or a last comment with no line end
#   deed-field.sh --find [DIR]            print the one *_chora.deed in DIR (default .)
#   deed-field.sh --uuid DEED             the repo uuid: the body of :repo-uuid #uuid"…" as
#                                         written (#u8 is derived; a #u5 is derived only to
#                                         read an old deed, and check-identity.sh refuses it)
#   deed-field.sh --typed DEED PATH KEY   like the first form, but a tagged literal keeps its
#                                         tag and quotes: #u5"github.com/o/r" (a plain value
#                                         prints as it does without --typed)
#
# PATH names clauses below (repo-deed …), slash-separated: `status`,
# `agentic/integrity`, `meta/maintenance-axes`. An empty PATH is (repo-deed …)
# itself, so `deed-field.sh DEED "" canonical-name` reads the header.
#
# A clause is never a field's value: in `:example (agentic)` the parentheses
# are a list, so --has DEED agentic is false unless a real (agentic …) clause
# exists.
#
# KEY is matched only at the top level of that clause, never inside a nested
# clause: `status` :phase is the clause's own phase, not a (history (entry …))
# phase. Comments (`;` to end of line, outside strings) are ignored, layout is
# irrelevant, string escapes \" \\ \n \t are decoded, and the booleans #t / #f
# print as true / false, because every caller is a shell test. A tagged
# literal prints its string: `:repo-uuid #u5"github.com/o/r"` gives
# github.com/o/r, the uuid5 name (uuidgen --sha1 --namespace @url --name …).
#
# --uuid prints the repo id. The chora id is minted once and carried opaquely
# as `:repo-uuid #uuid"<v8 id of the birth path>"` (standards A1 V8, A7 J11), so
# for that form it prints the body as written and NEVER re-derives it: a
# transfer or rename does not change the id (ruling U1). Legacy literals are
# still read, with a note on stderr: #u5"NAME" gives the uuid5 (RFC 9562, URL
# namespace) of NAME, through uuidgen with --sha1, else scripts/uuid5-url.sh,
# else bun; #u8"DOMAIN:NAME" gives the profile C id through scripts/uuid-v8.sh.
# It exits 2 when no tool is available or the result is not uuid-shaped: it
# never guesses.
#
# Exit: 0 found; 1 clause or key absent (nothing printed); 2 usage error or no
# readable deed. --find exits 1 unless exactly one deed is present. --strict
# exits 1 for content outside the form and 2 for a form that never closes.
set -euo pipefail

mode=value
case "${1:-}" in
  --list|--clause|--has|--uuid|--typed|--kv|--strict) mode="${1#--}"; shift ;;
  --find)
    shopt -s nullglob
    deeds=("${2:-.}"/*_chora.deed)
    [ "${#deeds[@]}" -eq 1 ] || exit 1
    printf '%s\n' "${deeds[0]}"
    exit 0 ;;
esac

deed="${1:-}"; path="${2-}"; key="${3:-}"
[ "$mode" != uuid ] || { path=""; key=repo-uuid; }
if [ -z "$deed" ] || [ ! -r "$deed" ]; then
  echo "deed-field.sh: no readable deed: '${deed}'" >&2; exit 2
fi
if [[ ( "$mode" = value || "$mode" = typed || "$mode" = list ) && -z "$key" ]]; then
  echo "deed-field.sh: KEY is required" >&2; exit 2
fi

# read_deed MODE -> run the clause reader over $deed for $path / $key
read_deed() {
awk -v mode="$1" -v path="$path" -v key="$key" '
BEGIN { RS = "\001" }
{
  # Tokenise: "(" ")" , S<string> , A<atom>. Comments are dropped here.
  # Line-wise and regex-driven: a character-by-character substr() walk of the
  # whole deed cost ~15 ms per call, and every gate that reads several fields
  # pays it once per field. Each line is consumed by jumping to the next
  # significant character; a string may span lines (the newline is part of it).
  nl = split($0, ln, "\n"); nt = 0; instr = 0; v = ""
  for (li = 1; li <= nl; li++) {
    r = ln[li]
    while (r != "") {
      if (instr) {
        if (!match(r, /[\\"]/)) { v = v r; r = ""; break }
        v = v substr(r, 1, RSTART - 1)
        if (substr(r, RSTART, 1) == "\"") { tok[++nt] = "S" v; instr = 0; r = substr(r, RSTART + 1); continue }
        d = substr(r, RSTART + 1, 1)          # backslash escape; "" = escaped line end
        if (RSTART == length(r)) { v = v "\n"; r = ""; skipnl = 1; break }
        if (d == "n") v = v "\n"; else if (d == "t") v = v "\t"; else v = v d
        r = substr(r, RSTART + 2); continue
      }
      if (match(r, /^[ \t\r]+/)) { r = substr(r, RLENGTH + 1); continue }
      if (r == "") break
      c = substr(r, 1, 1)
      if (c == ";") break
      if (c == "(" || c == ")") { tok[++nt] = c; r = substr(r, 2); continue }
      if (c == "\"") { instr = 1; v = ""; r = substr(r, 2); continue }
      match(r, /^[^ \t\r();"]+/)
      tok[++nt] = "A" substr(r, 1, RLENGTH); r = substr(r, RLENGTH + 1)
    }
    if (instr) { if (skipnl) skipnl = 0; else if (li < nl) v = v "\n" }
  }
  if (instr) tok[++nt] = "S" v      # unterminated string at EOF: kept, as before
}
# Index of the ")" token that closes the clause opening at token o, or 0.
function close_of(o,   d, t) {
  d = 0
  for (t = o; t <= nt; t++) {
    if (tok[t] == "(") d++
    else if (tok[t] == ")") { d--; if (d == 0) return t }
  }
  return 0
}
# True when the "(" at token t opens the list value of a field, not a clause: it
# follows a keyword, directly or after the quote of a quoted list (deed.abnf:
# field = keyword value, value = … / quoted / list). `:example (agentic)` is
# a list holding the symbol agentic; the deed has no (agentic) clause.
function is_value(t) {
  return tok[t - 1] ~ /^A:/ || (tok[t - 1] == "A\047" && tok[t - 2] ~ /^A:/)
}
# First direct child clause of the clause opening at o whose head is name.
function child(o, name,   e, t, d) {
  e = close_of(o); d = 0
  for (t = o + 1; t < e; t++) {
    if (tok[t] == "(") { if (d == 0 && !is_value(t) && tok[t + 1] == "A" name) return t; d++ }
    else if (tok[t] == ")") d--
  }
  return 0
}
# A value token rendered for output: the type tag dropped, #t/#f as true/false.
function show(x) {
  x = substr(x, 2)
  if (x == "#t") return "true"
  if (x == "#f") return "false"
  return x
}
END {
  o = 0
  for (t = 1; t <= nt; t++)
    if (tok[t] == "(" && tok[t + 1] ~ /^A(repo-deed|praxis-deed|estate-deed|estate-atlas-deed)$/) { o = t; break }
  if (!o) exit 1
  if (path != "") {
    np = split(path, part, "/")
    for (p = 1; p <= np; p++) { o = child(o, part[p]); if (!o) exit 1 }
  }
  e = close_of(o)
  if (!e) exit 2
  if (mode == "strict") exit (o == 1 && e == nt) ? 0 : 1
  if (mode == "has") exit 0
  if (mode == "clause") { for (t = o; t <= e; t++) print tok[t]; exit 0 }
  if (mode == "kv") {
    d = 0
    for (t = o + 1; t < e; t++) {
      if (tok[t] == "(") { d++; continue }
      if (tok[t] == ")") { d--; continue }
      if (d != 0 || tok[t] !~ /^A:/) continue
      k = substr(tok[t], 3); nx = tok[t + 1]
      if (nx == "(") {
        le = close_of(t + 1); ld = 0
        for (u = t + 2; u < le; u++) {
          if (tok[u] == "(") ld++
          else if (tok[u] == ")") ld--
          else if (ld == 0) print k "\t" show(tok[u])
        }
      } else if (nx != ")" && nx != "") {
        if (nx ~ /^A#[a-z0-9]+$/ && substr(tok[t + 2], 1, 1) == "S") nx = tok[t + 2]
        print k "\t" show(nx)
      }
    }
    exit 0
  }
  d = 0
  for (t = o + 1; t < e; t++) {
    if (tok[t] == "(") { d++; continue }
    if (tok[t] == ")") { d--; continue }
    if (d != 0 || tok[t] != "A:" key) continue
    nx = tok[t + 1]
    if (mode == "value" || mode == "typed") {
      if (nx == "(" || nx == ")" || nx == "") exit 1
      # A tagged literal such as #u5"github.com/o/r" prints its string.
      if (nx ~ /^A#[a-z0-9]+$/ && substr(tok[t + 2], 1, 1) == "S") {
        if (mode == "typed") { print substr(nx, 2) "\"" substr(tok[t + 2], 2) "\""; exit 0 }
        nx = tok[t + 2]
      }
      print show(nx); exit 0
    }
    if (nx != "(") exit 1
    le = close_of(t + 1); ld = 0
    for (u = t + 2; u < le; u++) {
      if (tok[u] == "(") ld++
      else if (tok[u] == ")") ld--
      else if (ld == 0) print show(tok[u])
    }
    exit 0
  }
  exit 1
}
' "$deed"
}

# uuid5_url NAME -> the uuid5 of NAME in the RFC 9562 URL namespace
uuid5_url() {
  if uuidgen --sha1 --namespace @url --name x >/dev/null 2>&1; then
    uuidgen --sha1 --namespace @url --name "$1"
  elif [ -f "$(dirname "${BASH_SOURCE[0]}")/uuid5-url.sh" ] && bash "$(dirname "${BASH_SOURCE[0]}")/uuid5-url.sh" x >/dev/null 2>&1; then
    # The same derivation repo-init mints with (sha1sum, shasum or openssl).
    bash "$(dirname "${BASH_SOURCE[0]}")/uuid5-url.sh" "$1"
  elif command -v bun >/dev/null 2>&1; then
    bun -e '
      const h = new Bun.CryptoHasher("sha1");
      h.update(Buffer.from("6ba7b8119dad11d180b400c04fd430c8", "hex"));
      h.update(process.argv[1]);
      const b = h.digest().subarray(0, 16);
      b[6] = (b[6] & 0x0f) | 0x50;
      b[8] = (b[8] & 0x3f) | 0x80;
      const x = b.toString("hex");
      console.log([x.slice(0, 8), x.slice(8, 12), x.slice(12, 16), x.slice(16, 20), x.slice(20)].join("-"));
    ' "$1"
  else
    echo "deed-field.sh: --uuid needs uuidgen with --sha1, sha1sum, shasum, openssl, or bun" >&2; return 2
  fi
}

# The reader takes byte 0x01 as its record separator, so awk drops one that
# ends the file and --strict would pass it (checked against the line-wise
# tokeniser: a valid deed plus one trailing 0x01 still exits 0 without this).
# No deed holds that byte.
if [ "$mode" = strict ] && LC_ALL=C grep -q $'\001' "$deed"; then
  exit 1
fi

if [ "$mode" = uuid ]; then
  lit="$(read_deed typed)" || exit $?
  re_uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[58][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  case "$lit" in
    '#uuid"'*'"')
      # The chora id, minted once: print it as written, never re-derive it.
      id="${lit#\#uuid\"}"; id="${id%\"}" ;;
    '#u5"'*'"')
      name="${lit#\#u5\"}"; name="${name%\"}"
      # Read only so an old deed can still be looked up: a #u5 in an identity
      # field is u5-identity, an error in every mode (A1 v0.4.5 T30, Q2), and
      # scripts/check-identity.sh refuses it.
      echo "deed-field.sh: :repo-uuid is a #u5 literal, an error under A1 T30 (Q2); derived here only to read an old deed. Write #uuid\"<v8 id of the birth path>\"." >&2
      id="$(uuid5_url "$name")" || exit 2 ;;
    '#u8"'*:*'"')
      body="${lit#\#u8\"}"; body="${body%\"}"
      id="$(bash "$(dirname "${BASH_SOURCE[0]}")/uuid-v8.sh" "${body%%:*}" "${body#*:}")" || exit 2 ;;
    *) echo "deed-field.sh: :repo-uuid is not a #uuid, #u5 or #u8 literal: '$lit'" >&2; exit 2 ;;
  esac
  [[ "$id" =~ $re_uuid ]] \
    || { echo "deed-field.sh: :repo-uuid is not a lowercase v5 or v8 uuid: '$id'" >&2; exit 2; }
  printf '%s\n' "$id"
  exit 0
fi
read_deed "$mode"
