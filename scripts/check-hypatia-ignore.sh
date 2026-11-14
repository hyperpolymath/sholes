#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-hypatia-ignore.sh — the meta-rules that govern `.hypatia-ignore`.
#
# Hypatia reads `.hypatia-ignore` as a flat set of (rule_module, rule_type,
# path-fragment) exemptions and ORs them with its built-in defaults
# (lib/hypatia/scanner_suppression.ex). Three properties follow from that, and
# none of them are checked anywhere else:
#
#   1. Fragments are SUBSTRING matches, so an entry for `x.yml` also silences
#      `x.yml.bak`, and one for `build/docs-seed/` silences
#      `build/docs-seed-old/`. An entry that does not end at a path boundary is
#      a suppression wider than its stated reason.
#   2. The set has no precedence: a directory-wide entry makes every narrower
#      entry for the same (module, type) dead code, which reads as though the
#      narrow case were considered when it was not.
#   3. Nothing ties an entry to the file it names, so a rename leaves an
#      exemption that no longer applies to anything (or applies to the wrong
#      thing) and nothing says so.
#
# The check enforces each of those as a rule about the rules, and requires the
# stated reason the file's own header promises. It does not and cannot check
# that Hypatia agrees: the built-in defaults live in another repository.
#
# ORDER OF THE LAYERS (authoritative statement: docs/HYPATIA-RULE-ORDER.adoc)
#   rule-level total ban  >  built-in defaults  =  repo .hypatia-ignore  >
#   inline `# hypatia: allow`  >  baseline  >  grid normalisation
# The first two are Hypatia's; only `.hypatia-ignore` and inline directives are
# this repository's to get wrong.
#
# Exit contract (proven-tests-and-benches 3-outcome convention):
#   0 = every entry is well formed, bounded, live and explained
#   1 = at least one entry violates a rule above
#   2 = setup error (missing repo directory or ignore file)
set -euo pipefail

REPO_ROOT="${1:-.}"
IGNORE="$REPO_ROOT/.hypatia-ignore"

if [ ! -d "$REPO_ROOT" ]; then
  echo "check-hypatia-ignore: repo directory '$REPO_ROOT' does not exist" >&2
  exit 2
fi
if [ ! -f "$IGNORE" ]; then
  echo "check-hypatia-ignore: no .hypatia-ignore at '$IGNORE'" >&2
  exit 2
fi

errors=0
fail() {
  echo "FAIL: $*" >&2
  errors=$((errors + 1))
}
note() { echo "  note: $*"; }

entries="$(mktemp)"
trap 'rm -f "$entries"' EXIT

lineno=0
have_reason=0
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno + 1))
  line="${raw%$'\r'}"
  case "$line" in
    '#'*)
      # A comment opens a reason block: every entry directly beneath it — one
      # or many, which is how this file groups them — inherits that reason.
      have_reason=1
      continue
      ;;
    '')
      # A blank line closes the block, so the next entry needs its own reason.
      have_reason=0
      continue
      ;;
  esac
  # ── format: <module>/<type>:<path> | <module>/*:<path> | <path> ──────────
  if [[ "$line" != *:* ]]; then
    fail "line ${lineno}: '${line}' has no ':'; a bare path exempts every rule for that path, which needs an explicit reason and the module/type form instead"
    continue
  fi
  selector="${line%%:*}"
  path="${line#*:}"
  if [[ "$path" == *:* ]]; then
    fail "line ${lineno}: '${line}' has more than one ':' (path fragments cannot contain ':')"
    continue
  fi
  # Rule TYPES carry uppercase (SD022, RE001); rule MODULES do not.
  if [[ ! "$selector" =~ ^[a-z][a-z0-9_]*/([A-Za-z0-9_]+|\*)$ ]]; then
    fail "line ${lineno}: selector '${selector}' is not <rule_module>/<rule_type> or <rule_module>/*"
    continue
  fi
  module="${selector%%/*}"
  type="${selector##*/}"
  if [[ -z "$path" ]]; then
    fail "line ${lineno}: '${line}' has an empty path fragment"
    continue
  fi

  # ── rule 1: the fragment must end on a path boundary ────────────────────
  # Trailing '/' is a directory; anything else must look like a file name (it
  # contains a dot in its last segment). A fragment that satisfies neither is a
  # raw substring, and silences files its author never considered.
  last_seg="${path##*/}"
  if [[ "$path" != */ && "$last_seg" != *.* ]]; then
    fail "line ${lineno}: path fragment '${path}' ends on neither '/' nor a file name (a raw substring match silences more than it names)"
  fi

  # ── rule 3: the path it names must exist ────────────────────────────────
  if [[ ! -e "$REPO_ROOT/$path" ]]; then
    fail "line ${lineno}: path '${path}' does not exist in this repository (a stale exemption keeps suppressing a path that was renamed, and no longer describes what it says)"
  fi

  # ── reason: every entry belongs to an explained block ───────────────────
  # The file's header promises each entry carries a stated reason. A block of
  # entries may share one comment (that is how the workflow families here are
  # documented); a blank line starts a new block, and a new block needs a new
  # reason. The group's entries keep `have_reason` set, so only the first entry
  # after a blank line can fail.
  if [ "$have_reason" -eq 0 ]; then
    fail "line ${lineno}: '${line}' has no stated reason (the block above it does not begin with a comment)"
  fi

  printf '%s\t%s\t%s\n' "$module" "$type" "$path" >> "$entries"
done < "$IGNORE"

# ── rule 2: no duplicate, no entry subsumed by a broader one ───────────────
if [ -s "$entries" ]; then
  while IFS=$'\t' read -r module type path; do
    # duplicate
    if [ "$(awk -F'\t' -v m="$module" -v t="$type" -v p="$path" '$1 == m && $2 == t && $3 == p' "$entries" | wc -l)" -gt 1 ]; then
      fail "duplicate entry ${module}/${type}:${path}"
    fi
    # subsumed: same module, and the other entry's type covers this one (same
    # type or '*'), and the other path is a substring of this one (or equal).
    broader="$(awk -F'\t' -v m="$module" -v t="$type" -v p="$path" '
        $1 == m && ($2 == t || $2 == "*") && $3 != p {
          if (index(p, $3) > 0) print $2 ":" $3
        }' "$entries" | sort -u)"
    if [ -n "$broader" ]; then
      fail "${module}/${type}:${path} is already covered by ${module}/${broader} — one of the two is dead code"
    fi
  done < "$entries"
fi

# ── advisory: grouping ────────────────────────────────────────────────────
# The set is unordered to Hypatia but read in order by people. Modules should
# be contiguous so a reviewer sees one rule's story in one place.
seen=""
prev=""
while IFS=$'\t' read -r module _ _; do
  [ -n "$module" ] || continue
  if [ "$module" != "$prev" ]; then
    case " $seen " in
      *" $module "*) note "module '${module}' appears in more than one block; Hypatia does not care, reviewers do" ;;
    esac
    seen="$seen $module"
    prev="$module"
  fi
done < "$entries"

if [ "$errors" -ne 0 ]; then
  echo "check-hypatia-ignore: ${errors} rule violation(s) in .hypatia-ignore" >&2
  exit 1
fi
echo "check-hypatia-ignore: $(grep -c . "$entries" 2>/dev/null || echo 0) exemption(s) well formed, bounded, live and explained"
