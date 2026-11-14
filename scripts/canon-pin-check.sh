#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# canon-pin-check.sh — decide whether a repo deed's (canon …) pin implements a
# canon.lock. The decision only: no network. dogfood-gate.yml `Canon lockstep`
# fetches the locks and the canon PR's state and calls this; the tests in
# tests/workflows/canon_pin_check_test.sh drive it with fixtures.
#
# Two-phase lockstep. canon.lock [canon.lockstep].order is
# "spine-adopts-then-canon-releases", and the spine's adoption necessarily pins
# hashes that exist only in the unmerged canon PR. So the spine may adopt a
# canon AHEAD of its release by naming that PR in the clause:
#
#     (canon :version "2.1.6" :criteria-sha256 "…" :gates-sha256 "…"
#            :proposed-by "metadatastician/standards#1440" …)
#
# The pin then has to equal canon.lock at that PR's head, and the PR has to be
# open. When the PR merges, the pin equals the released canon.lock and the
# field is spent (a notice asks for it to be dropped). When the PR is closed
# unmerged or amended, the pin names a canon that is not released, and this
# fails. Standards Gate A checks the other side: a canon PR that changes
# canon.lock is not mergeable until the spine's main pins it.
#
# Spine and instance. Exact equality is the SPINE's invariant: the template
# is what implements the canon. A repo minted from the template carries the
# pin as PROVENANCE, "the canon release it was cut from" (repo-init.just),
# and a provenance record cannot follow later releases. Requiring equality
# there turned every instance red on every push the moment standards
# released a newer canon (2.1.5 reddened every 2.1.2-2.1.4 instance). So an
# instance whose pin names an OLDER version passes with a notice naming the
# release it lags. The spine is recognised by GITHUB_REPOSITORY_ID, which
# survives a transfer; with no id in the environment (a local run) the
# check stays strict.
#
# Usage:
#   canon-pin-check.sh released <deed> <canon.lock>
#       0  the pin equals canon.lock (a spent :proposed-by gives a notice),
#          or, outside the spine, the pin names an older canon version
#          (an older instance pin with :proposed-by also gives 3, plus a
#          LAGS_BEHIND=<released> line: only a MERGED proposal makes it spent)
#       3  the pin differs and the clause names a canon PR: the caller must
#          check that PR; stdout carries the line  PROPOSED_BY=<owner/repo#N>
#       1  the pin differs and names no canon PR (in an instance: the pin
#          names the released version or a later one, with other hashes)
#       2  malformed input (no single clause, a pin of the wrong shape, a
#          malformed :proposed-by, an unreadable lock)
#   canon-pin-check.sh pending <deed> <canon.lock-at-PR-head> <pr-state> [<released>]
#       (also 0 when <pr-state> is "merged", the pin equals that lock, and an
#       instance pin is older than <released>: the proposal is spent)
#       0  <pr-state> is "open" and the pin equals that lock
#       1  otherwise
#       2  malformed input
# Both modes print a Markdown table of the comparison to stdout.

set -euo pipefail

usage() { sed -n '36,50p' "$0" >&2; exit 2; }

# The spine's repository id (hyperpolymath/rsr-template-repo). An id, not a
# slug: a slug changes on a transfer, an id does not.
SPINE_REPOSITORY_ID=1306804488

# version_lt <a> <b>: true when semver a sorts strictly before b.
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]
}

# deed_canon <key> <deed-file>: print the value of :<key> from the deed's one
# (canon …) clause, or nothing when the clause or key is absent or the clause
# is not unique. The SAME function is in build/just/repo-init.just and
# standards scripts/check-canon-lockstep.sh; keep them identical.
deed_canon() {
    _clauses="$(awk 'BEGIN { bs = sprintf("%c", 92); dq = sprintf("%c", 34) } { o = ""; q = 0; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (q && c == bs) { o = o c substr($0, i + 1, 1); i++; continue } if (c == dq) q = !q; else if (!q && c == ";") break; o = o c } printf "%s ", o }' "$2" | grep -oE '[(]canon[[:space:]][^()]*[)]')" || true
    _n="$(echo "$_clauses" | grep -c '(canon' || true)"
    if [ "$_n" != "1" ]; then
        echo "deed_canon: $2 carries ${_n:-0} (canon …) clauses, need exactly 1" >&2
        return 0
    fi
    echo "$_clauses" | grep -oE ':'"$1"'[[:space:]]+"[^"]*"' | head -1 | sed -E 's/^[^"]*"//; s/"$//' || true
}

# canon_key <key> <lock>: a scalar under [canon].
canon_key() {
  awk -v key="$1" '
    /^[[:space:]]*#/ { next }
    /^\[/ { f = ($0 == "[canon]") ? 1 : 0; next }
    f && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); gsub(/^["[:space:]]+|["[:space:]]+$/, ""); print; exit
    }' "$2"
}

# artefact_hash <name> <lock>: the sha256 of [canon.artifacts] <name>.
artefact_hash() {
  awk -v key="$1" '
    /^[[:space:]]*#/ { next }
    $0 ~ "^" key "[[:space:]]*=" { f = 1 }
    f { buf = buf " " $0 }
    f && /sha256[[:space:]]*=/ { print buf; exit }
  ' "$2" | grep -oE '[0-9a-f]{64}' | head -1 || true
}

HEX='[0-9a-f]{64}'
SEMVER='[0-9]+\.[0-9]+\.[0-9]+'
PR_REF='(hyperpolymath|metadatastician)/standards#[1-9][0-9]*'

# compare <deed> <lock> <label>: print the table; set SAME=1 when all three
# pins agree. Exit 2 on a value of the wrong shape: "" = "" is not lockstep.
compare() {
  local deed="$1" lock="$2" label="$3" k want got re
  [ -r "$lock" ] || { echo "::error::cannot read $lock" >&2; exit 2; }
  SAME=1
  echo "| pin | ${label} | deed declares | |"
  echo "|---|---|---|---|"
  for k in version criteria-sha256 gates-sha256; do
    case "$k" in
      version)         want="$(canon_key version "$lock")"; re="$SEMVER" ;;
      criteria-sha256) want="$(artefact_hash criteria "$lock")"; re="$HEX" ;;
      gates-sha256)    want="$(artefact_hash gates "$lock")"; re="$HEX" ;;
    esac
    got="$(deed_canon "$k" "$deed")"
    if ! printf '%s' "$want" | grep -qxE "$re"; then
      echo "::error::canon.lock ${k} is not well-formed (got '${want}')" >&2; exit 2
    fi
    if ! printf '%s' "$got" | grep -qxE "$re"; then
      echo "::error::deed :${k} is not well-formed (got '${got}')" >&2; exit 2
    fi
    if [ "$want" = "$got" ]; then mark=":white_check_mark:"; else mark=":x:"; SAME=0; fi
    printf '| `%s` | `%s` | `%s` | %s |\n' "$k" "${want:0:16}" "${got:0:16}" "$mark"
  done
}

[ "$#" -ge 3 ] || usage
MODE="$1"; DEED="$2"; LOCK="$3"
[ -r "$DEED" ] || { echo "::error::cannot read $DEED" >&2; exit 2; }
n="$(awk 'BEGIN { bs = sprintf("%c", 92); dq = sprintf("%c", 34) } { o = ""; q = 0; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (q && c == bs) { i++; continue } if (c == dq) { q = !q; o = o " "; continue } if (!q && c == ";") break; if (!q) o = o c } print o }' "$DEED" | grep -oE '[(]canon([[:space:]]|$)' | wc -l | tr -d ' ')"
if [ "$n" != "1" ]; then
  echo "::error::$(basename "$DEED") carries $n (canon …) clauses; exactly 1 is required" >&2
  exit 2
fi
PROPOSED="$(deed_canon proposed-by "$DEED")"
if [ -n "$PROPOSED" ] && ! printf '%s' "$PROPOSED" | grep -qxE "$PR_REF"; then
  echo "::error:::proposed-by must name a canon pull request as owner/standards#N (got '${PROPOSED}')" >&2
  exit 2
fi

case "$MODE" in
  released)
    compare "$DEED" "$LOCK" "canon.lock (released)"
    if [ "$SAME" = 1 ]; then
      if [ -n "$PROPOSED" ]; then
        echo
        echo "::notice::the pin equals the released canon; :proposed-by \"${PROPOSED}\" is spent and can be dropped"
      fi
      exit 0
    fi
    pinned="$(deed_canon version "$DEED")"
    released="$(canon_key version "$LOCK")"
    # An instance keeps the template's clause as provenance, :proposed-by included.
    # A pin OLDER than the released canon passes with the lag notice, but only
    # if it carries no :proposed-by, or that proposal is shown to be spent:
    # being older does not prove the proposal merged (it may have closed
    # unmerged at a version that never released). The script has no release
    # history, so it defers to the PR-state lookup (exit 3), marking the lag
    # with LAGS_BEHIND=<released> so `pending` can accept a MERGED proposal.
    # An unreleased proposal (pin equals the release with other hashes, or is
    # later) is checked exactly as before, and the spine stays strict.
    if [ -n "${GITHUB_REPOSITORY_ID:-}" ] && [ "$GITHUB_REPOSITORY_ID" != "$SPINE_REPOSITORY_ID" ] \
       && version_lt "$pinned" "$released"; then
      if [ -z "$PROPOSED" ]; then
        echo
        echo "::notice::this repo was cut from canon ${pinned}; canon ${released} is released. The pin is provenance, so this is not a failure; re-pin the (canon …) clause to adopt ${released}."
        exit 0
      fi
      echo
      echo "PROPOSED_BY=${PROPOSED}"
      echo "LAGS_BEHIND=${released}"
      exit 3
    fi
    if [ -n "$PROPOSED" ]; then
      echo
      echo "PROPOSED_BY=${PROPOSED}"
      exit 3
    fi
    exit 1
    ;;
  pending)
    [ "$#" -ge 4 ] && [ "$#" -le 5 ] || usage
    RELEASED_NOW="${5:-}"
    STATE="$4"
    [ -n "$PROPOSED" ] || { echo "::error::pending mode needs a :proposed-by in the clause" >&2; exit 2; }
    compare "$DEED" "$LOCK" "canon.lock at ${PROPOSED}"
    # A merged proposal is spent only for an instance whose pin lags the release
    # (RELEASED_NOW, from LAGS_BEHIND) and equals the lock at the proposal's head.
    if [ "$STATE" = "merged" ] && [ "$SAME" = 1 ] && [ -n "$RELEASED_NOW" ] \
       && [ -n "${GITHUB_REPOSITORY_ID:-}" ] && [ "$GITHUB_REPOSITORY_ID" != "$SPINE_REPOSITORY_ID" ] \
       && version_lt "$(deed_canon version "$DEED")" "$RELEASED_NOW"; then
      echo
      echo "::notice::${PROPOSED} merged and released canon $(deed_canon version "$DEED"); canon ${RELEASED_NOW} is released since. The pin is provenance, so this is not a failure; re-pin the (canon …) clause and drop :proposed-by."
      exit 0
    fi
    if [ "$STATE" != "open" ]; then
      echo
      echo "::error::${PROPOSED} is ${STATE}, so the canon this deed pins was never released; re-adopt the released canon.lock or the canon PR that supersedes it"
      exit 1
    fi
    [ "$SAME" = 1 ] && exit 0
    echo
    echo "::error::the pin differs from canon.lock at the head of ${PROPOSED}; re-adopt that PR's current canon.lock"
    exit 1
    ;;
  *) usage ;;
esac
