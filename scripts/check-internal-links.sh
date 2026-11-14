#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-internal-links.sh [REPO_DIR] — every repository-internal link in a
# tracked .adoc or .md file must resolve to a file or directory that exists.
#
# Checked: AsciiDoc link:/xref:/include:: targets that name a path, and
# Markdown [text](relative/path) links. Resolved relative to the linking file
# (a leading "/" is the repository root, or the site root www/ for files under www/). A "#fragment" or "?query" is dropped.
# Not checked, by design: http(s):// and other URL schemes, mailto:, anchors
# alone, paths holding a double-brace mint token or a {attribute}, and
# anything inside a code fence, a listing block or a `backtick span`, where a
# link is an example rather than a link.
#
# Known intentional cases go in .machine_readable/internal-links-allow.txt,
# one per line:   <resolved repo-relative path> | <reason>
# A reason is mandatory. An entry whose target now exists fails (the ledger
# only shrinks), so an allowance cannot go stale in silence.
#
# It also checks the deed registry (see below).
#
# Exit: 0 all links resolve; 1 a link is dead, or the ledger is malformed/stale.
set -euo pipefail

ROOT="$(cd "${1:-.}" && pwd)"
ALLOW="$ROOT/.machine_readable/internal-links-allow.txt"
cd "$ROOT"

declare -A allowed=() used=()
rc=0
if [ -f "$ALLOW" ]; then
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    path="${line%%|*}"; reason="${line#*|}"
    path="$(printf '%s' "$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    reason="$(printf '%s' "$reason" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ "$reason" = "$line" ] || [ -z "$path" ] || [ -z "$reason" ]; then
      echo "FAIL: ${ALLOW#"$ROOT"/}:$n: entry needs '<path> | <reason>'" >&2; rc=1; continue
    fi
    allowed["$path"]="$reason"
  done < "$ALLOW"
fi

# extract FILE — print "LINE<TAB>TARGET" for each candidate link.
extract() {
  awk '
    /^```/ || /^----+[[:space:]]*$/ || /^\.\.\.\.+[[:space:]]*$/ { fence = !fence; next }
    fence { next }
    {
      s = $0
      gsub(/`[^`]*`/, "", s)
      while (match(s, /(link:|xref:|include::)[^[:space:]\[]+\[/)) {
        t = substr(s, RSTART, RLENGTH - 1); s = substr(s, RSTART + RLENGTH)
        sub(/^(link:|xref:|include::)/, "", t); print NR "\t" t
      }
    }
    { s = $0; gsub(/`[^`]*`/, "", s)
      while (match(s, /\]\([^)[:space:]]+\)/)) {
        t = substr(s, RSTART + 2, RLENGTH - 3); s = substr(s, RSTART + RLENGTH)
        print NR "\t" t
      }
    }' "$1"
}

dead=0; checked=0; skipped=0
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue   # tracked but deleted from the work tree (a mint in progress)
  while IFS=$'\t' read -r ln target; do
    [ -n "$target" ] || continue
    case "$target" in
      *'{'*|*'}'*) skipped=$((skipped + 1)); continue ;;
      '#'*|*://*|mailto:*|tel:*|data:*) continue ;;
    esac
    # xref:id[] with no path is an in-document anchor, not a file.
    case "$target" in */*|*.adoc|*.md) ;; *) continue ;; esac
    t="${target%%#*}"; t="${t%%\?*}"
    [ -n "$t" ] || continue
    checked=$((checked + 1))
    case "$t" in
      /*) case "$f" in www/*) res="www/${t#/}" ;; *) res="${t#/}" ;; esac ;;
      *)  res="$(dirname "$f")/$t" ;;
    esac
    res="$(realpath -m --relative-to="$ROOT" "$ROOT/$res")"
    if [ -e "$res" ] || [ -L "$res" ]; then
      if [ -n "${allowed[$res]+x}" ]; then
        echo "FAIL: stale allowance: $res exists now; remove it from ${ALLOW#"$ROOT"/}" >&2; rc=1
        unset 'allowed[$res]'
      fi
      continue
    fi
    if [ -n "${allowed[$res]+x}" ]; then
      used["$res"]=1; continue
    fi
    echo "DEAD: $f:$ln -> $target (no such path: $res)"
    dead=$((dead + 1))
  done < <(extract "$f")
done < <(git ls-files -z -- '*.adoc' '*.md' ':!:LICENSES/*')


# --- Deed document registry -------------------------------------------------
# <repo>_chora.deed's (documents (document :id #u8"repo-document:github.com/<owner>/<name>#<role>"
# :role <role> :path "P" [:removed-at-mint #t])) names pages other docs cite by id
# (ADR-008 profile C, domain repo-document, standards#1500). Each id must be in
# that domain, name github.com/<owner>/<name>#<role> with <role> equal to the
# entry's :role, and be unique; each :path must exist unless :removed-at-mint #t.
# Only #u8 is accepted: the owner ruled this form, and the deed linter rejects
# an opaque #uuid there, so a #uuid id could not pass the DEED gate anyway.
deed_docs() {
  awk '
    function flush(   id, role, path, rm) {
      id = ""; role = ""; path = ""; rm = "f"
      if (match(buf, /:id #u8"[^"]*"/)) { id = substr(buf, RSTART + 8, RLENGTH - 9) }
      if (match(buf, /:role [^ \t)]+/)) { role = substr(buf, RSTART + 6, RLENGTH - 6) }
      if (match(buf, /:path "[^"]*"/)) { path = substr(buf, RSTART + 7, RLENGTH - 8) }
      if (buf ~ /:removed-at-mint #t/) rm = "t"
      print id "\t" role "\t" path "\t" rm
    }
    /^[[:space:]]*;/ { next }
    {
      line = $0
      if (!inside && line ~ /^[[:space:]]*\(document([[:space:]]|$)/) { inside = 1; depth = 0; buf = "" }
      if (inside) {
        buf = buf " " line
        t = line; gsub(/"[^"]*"/, "", t)
        n = gsub(/\(/, "(", t); m = gsub(/\)/, ")", t)
        depth += n - m
        if (depth <= 0) { flush(); inside = 0 }
      }
    }' "$1"
}

shopt -s nullglob
deeds=(./*_chora.deed)
shopt -u nullglob
reg_n=0
declare -A seen_id=()
if [ "${#deeds[@]}" -eq 1 ]; then
  while IFS=$'\t' read -r did role dpath rm; do
    reg_n=$((reg_n + 1))
    if [[ "$did" != repo-document:* ]]; then
      echo "FAIL: ${deeds[0]#./}: document '${role:-?}' needs an :id #u8\"repo-document:github.com/<owner>/<name>#<role>\" (ADR-008 profile C, domain repo-document)" >&2; rc=1
    elif ! [[ "$did" =~ ^repo-document:github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#([A-Za-z0-9._-]+)$ ]]; then
      echo "FAIL: ${deeds[0]#./}: document id '$did' must name github.com/<owner>/<name>#<role>" >&2; rc=1
    elif [ "${BASH_REMATCH[1]}" != "$role" ]; then
      echo "FAIL: ${deeds[0]#./}: document id '$did' ends #${BASH_REMATCH[1]} but its :role is '$role'" >&2; rc=1
    elif [ -n "${seen_id[$did]+x}" ]; then
      echo "FAIL: ${deeds[0]#./}: document id $did is registered twice" >&2; rc=1
    fi
    seen_id["$did"]=1
    if [ -z "$role" ] || [ -z "$dpath" ]; then
      echo "FAIL: ${deeds[0]#./}: document $did needs :role and :path" >&2; rc=1
    elif [ ! -e "$dpath" ] && [ "$rm" != "t" ]; then
      echo "DEAD: ${deeds[0]#./} document $did (role $role) -> $dpath (no such path, and not :removed-at-mint #t)"
      dead=$((dead + 1))
    fi
  done < <(deed_docs "${deeds[0]}")
fi

for p in "${!allowed[@]}"; do
  # A note, not a failure: a minted repo drops the template-only pages that carried
  # these links, and its ledger is then left naming links that no longer exist.
  [ -n "${used[$p]+x}" ] || echo "NOTE: allowance not used (no tracked doc links to it any more): $p"
done

if [ "$dead" -gt 0 ] || [ "$rc" -ne 0 ]; then
  echo "FAIL: $dead dead internal link(s) ($checked checked, ${#used[@]} allowed, $skipped templated skipped)" >&2
  exit 1
fi
echo "PASS: $checked internal links resolve, $reg_n deed document id(s) resolve (${#used[@]} allowed, $skipped templated skipped)"
