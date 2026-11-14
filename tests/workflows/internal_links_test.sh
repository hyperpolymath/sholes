#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Controls for scripts/check-internal-links.sh: a tree of resolving links
# passes, and each planted defect (dead AsciiDoc link, dead Markdown link, a
# deed-registered path that is gone, a malformed or repeated id, an allowance
# with no reason or gone stale) fails and is named. Without the planted
# positives a PASS would prove nothing.
set -euo pipefail

CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/check-internal-links.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
ID1=repo-document:github.com/example-owner/example-repo#placeholders
ID2=repo-document:github.com/example-owner/example-repo#other
L='{'; TOK="${L}${L}TOKEN}}"   # built at run time so a minted repo's no-placeholders gate sees no token

fail() { echo "FAIL: $*" >&2; exit 1; }
# expect_pass DIR — the checker must accept DIR.
expect_pass() { bash "$CHECKER" "$1" > "$FIXTURE/out" 2>&1 || { cat "$FIXTURE/out" >&2; fail "checker rejected $2"; }; }
# expect_fail DIR WHAT NAMED — the checker must reject DIR and name NAMED.
expect_fail() {
  if bash "$CHECKER" "$1" > "$FIXTURE/out" 2>&1; then fail "checker accepted $2"; fi
  grep -qF -- "$3" "$FIXTURE/out" || { cat "$FIXTURE/out" >&2; fail "checker did not name $3 for $2"; }
}
# deed ID PATH REMOVED [ROLE] — write a one-document deed; ID is the body of the #u8 literal (an ID starting RAW: is written as given, without the #u8 wrapper).
deed() {
  case "$1" in RAW:*) idtok="${1#RAW:}" ;; *) idtok="#u8\"$1\"" ;; esac
  printf ';; SPDX-License-Identifier: MPL-2.0\n(repo-deed\n  :schema-version "1.0.0"\n  (documents\n    (document\n      :id %s\n      :role %s\n      :path "%s"\n      :removed-at-mint %s\n      :note "x")))\n' "$idtok" "${4:-placeholders}" "$2" "$3" > "$R/x_chora.deed"
}
fresh() {
  R="$FIXTURE/repo$1"; rm -rf "$R"; mkdir -p "$R/docs" "$R/www/policies" "$R/www/.well-known"
  git -C "$R" init -q
  printf 'x\n' > "$R/docs/target.adoc"; printf 'x\n' > "$R/www/.well-known/security.txt"
}
add() { git -C "$R" add -A; }

# --- Positive: every kind of resolving or exempt link ------------------------
fresh 1
cat > "$R/docs/a.adoc" <<'DOC'
See link:target.adoc[target], link:target.adoc#frag[fragment], xref:target.adoc[x],
link:https://example.org/missing[web], link:mailto:a@b.c[mail], <<local-anchor>>,
link:../@TOK@/gone.adoc[templated], and `link:inline-code-example.adoc[x]`.
include::target.adoc[]

----
link:fenced-example.adoc[never resolved]
----
DOC
sed -i "s/@TOK@/${TOK}/" "$R/docs/a.adoc"
printf 'A [md](target.adoc) and [web](https://example.org/x) and [top](#top).\n' > "$R/docs/b.md"
printf 'See link:/.well-known/security.txt[sec].\n' > "$R/www/policies/p.adoc"
deed "$ID1" docs/target.adoc '#f'
add; expect_pass "$R" "a tree whose links all resolve"
grep -q '^PASS:' "$FIXTURE/out" || fail "no PASS line"

# --- Negative: dead links ----------------------------------------------------
fresh 2
printf 'link:missing.adoc[x]\n' > "$R/docs/a.adoc"; add
expect_fail "$R" "a dead AsciiDoc link" "docs/a.adoc:1 -> missing.adoc"
fresh 3
printf '[x](nope/gone.md)\n' > "$R/docs/b.md"; add
expect_fail "$R" "a dead Markdown link" "docs/b.md:1 -> nope/gone.md"
fresh 4
printf 'link:/.well-known/humans.txt[x]\n' > "$R/www/policies/p.adoc"; add
expect_fail "$R" "a dead site-root link" "www/.well-known/humans.txt"

# --- Allowlist: reviewed entry passes; no reason, or stale, fails ------------
fresh 5
printf 'link:missing.adoc[x]\n' > "$R/docs/a.adoc"
mkdir -p "$R/.machine_readable"
printf '# ledger\ndocs/missing.adoc | planted: intentional\n' > "$R/.machine_readable/internal-links-allow.txt"; add
expect_pass "$R" "a reviewed allowance"
printf 'docs/missing.adoc\n' > "$R/.machine_readable/internal-links-allow.txt"; add
expect_fail "$R" "an allowance with no reason" "needs '<path> | <reason>'"
printf 'docs/missing.adoc | ok\n' > "$R/.machine_readable/internal-links-allow.txt"
printf 'x\n' > "$R/docs/missing.adoc"; add
expect_fail "$R" "a stale allowance (target now exists)" "stale allowance: docs/missing.adoc"
printf 'x\n' > "$R/docs/unlinked.adoc"
printf 'docs/unlinked.adoc | ok\ndocs/never-linked.adoc | ok\n' > "$R/.machine_readable/internal-links-allow.txt"
printf 'text\n' > "$R/docs/a.adoc"; add
expect_pass "$R" "an allowance no doc links to (a minted repo drops the linking page)"
grep -qF "NOTE: allowance not used" "$FIXTURE/out" || fail "the unused allowance was not reported"

# --- Deed registry -----------------------------------------------------------
fresh 6
deed "$ID1" docs/gone.adoc '#f'; add
expect_fail "$R" "a registered path that is gone" "document $ID1 (role placeholders) -> docs/gone.adoc"
deed "$ID1" docs/gone.adoc '#t'; add
expect_pass "$R" "a registered path that is gone but :removed-at-mint #t"
grep -q '1 deed document id' "$FIXTURE/out" || fail "registry entry not counted"
deed "not-a-name" docs/target.adoc '#f'; add
expect_fail "$R" "an id outside the repo-document domain" "needs an :id #u8"
deed "julia-package-identity:github.com/example-owner/example-repo#placeholders" docs/target.adoc '#f'; add
expect_fail "$R" "a wrong domain" "needs an :id #u8"
deed 'RAW:#uuid"01a1d229-3320-81a0-b9df-d93767675fbc"' docs/target.adoc '#f'; add
expect_fail "$R" "the old opaque #uuid form" "needs an :id #u8"
deed "repo-document:example.org/example-owner/example-repo#placeholders" docs/target.adoc '#f'; add
expect_fail "$R" "a name that is not github.com/<owner>/<name>#<role>" "must name github.com"
deed "repo-document:github.com/example-owner/example-repo" docs/target.adoc '#f'; add
expect_fail "$R" "a name with no #role" "must name github.com"
deed "$ID2" docs/target.adoc '#f' placeholders; add
expect_fail "$R" "a role that differs from the id's #role" "ends #other but its :role is 'placeholders'"
printf ';; SPDX-License-Identifier: MPL-2.0\n(repo-deed\n  :schema-version "1.0.0"\n  (documents\n    (document :id #u8"%s" :role placeholders :path "docs/target.adoc")\n    (document :id #u8"%s" :role placeholders :path "docs/target.adoc")))\n' "$ID1" "$ID1" > "$R/x_chora.deed"; add
expect_fail "$R" "a repeated id" "registered twice"
printf ';; SPDX-License-Identifier: MPL-2.0\n(repo-deed\n  :schema-version "1.0.0"\n  (documents\n    (document :id #u8"%s" :role placeholders :path "docs/target.adoc")\n    (document :id #u8"%s" :role other :path "docs/target.adoc")))\n' "$ID1" "$ID2" > "$R/x_chora.deed"; add
expect_pass "$R" "two distinct ids, one per line form"

# --- The real template passes ------------------------------------------------
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if bash "$TEMPLATE/scripts/is-template-tree.sh" "$TEMPLATE"; then
  bash "$CHECKER" "$TEMPLATE" > "$FIXTURE/out" 2>&1 || { cat "$FIXTURE/out" >&2; fail "the template tree does not pass"; }
else
  echo "SKIP: the template-tree control (not the template tree; is-template-tree.sh says no)"
fi
echo "PASS: internal-links controls (one positive tree; planted dead links, allowlist and deed-registry defects each rejected and named; template tree passes)"
