#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# resolve_template_pin_test.sh — controls for scripts/resolve-template-pin.sh.
#
# The resolver names the template commit a tree was minted from. Its defect
# class is a SILENT wrong answer: lintel recorded its own HEAD as the
# template commit, and nothing failed. So every positive case here has a
# negative twin that must be refused, and the child's own HEAD must never
# come out as the answer. Network-free: the "template" is a local repository.
#
# Usage: bash tests/workflows/resolve_template_pin_test.sh
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
pin="$repo/scripts/resolve-template-pin.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
field() { sed -n "s/^$1=//p" <<<"$2"; }

# A template with two commits on main and one on a side branch.
T="$work/template"
mkdir -p "$T"; g -C "$T" init -q -b main
printf 'v1\n' > "$T/README.adoc"; g -C "$T" add -A; g -C "$T" commit -qm one
C1=$(g -C "$T" rev-parse HEAD); T1=$(g -C "$T" rev-parse 'HEAD^{tree}')
printf 'v2\n' > "$T/README.adoc"; g -C "$T" commit -qam two
C2=$(g -C "$T" rev-parse HEAD)
g -C "$T" checkout -q -b side; printf 'side\n' > "$T/SIDE"; g -C "$T" add -A; g -C "$T" commit -qm side
C3=$(g -C "$T" rev-parse HEAD); g -C "$T" checkout -q main
SLUG=example-owner/example-template

# use_template DIR COMMIT — what GitHub's "Use this template" makes: one root
# commit with COMMIT's tree and none of its history, origin = the child.
use_template() {
    rm -rf "$1"; mkdir -p "$1"
    g -C "$T" archive "$2" | tar x -C "$1"
    g -C "$1" init -q -b main; g -C "$1" add -A; g -C "$1" commit -qm "Initial commit"
    g -C "$1" remote add origin "git@github.com:child-owner/child.git"
}
resolve() { bash "$pin" --slug "$SLUG" --url "$T" "$@"; }

# 1. A Use-this-template child resolves to the template commit with its tree.
use_template "$work/child" "$C1"
out=$(resolve --dir "$work/child")
[ "$(field commit "$out")" = "$C1" ] || fail "child resolved to $(field commit "$out"), want $C1"
[ "$(field tree "$out")" = "$T1" ] || fail 'child resolved to the wrong tree'
[ "$(field branch "$out")" = main ] || fail "branch $(field branch "$out"), want main"
[ "$(field source "$out")" = root-commit ] || fail "source $(field source "$out")"
[ "$(field commit "$out")" != "$(g -C "$work/child" rev-parse HEAD)" ] || fail "recorded the child's own HEAD"
echo 'PASS: a Use-this-template child resolves to the template commit, never its own HEAD'

# 2. It still resolves after the child has grown commits (root commit wins).
printf 'work\n' >> "$work/child/README.adoc"; g -C "$work/child" commit -qam work
[ "$(field commit "$(resolve --dir "$work/child")")" = "$C1" ] || fail 'a child with later commits lost its template'
echo 'PASS: later child commits do not move the template pin'

# 3. An uncommitted copy resolves by its work tree; a changed copy is refused.
rm -rf "$work/copy"; mkdir -p "$work/copy"; g -C "$T" archive "$C2" | tar x -C "$work/copy"; g -C "$work/copy" init -q
out=$(resolve --dir "$work/copy")
[ "$(field commit "$out")" = "$C2" ] && [ "$(field source "$out")" = work-tree ] || fail "copy resolved to: $out"
[ -z "$(find "$work/copy/.git/objects" -mindepth 1 -maxdepth 1 ! -name info ! -name pack)" ] || fail "resolving wrote objects into the copy's .git"
printf 'local edit\n' >> "$work/copy/README.adoc"
if resolve --dir "$work/copy" >/dev/null 2>"$work/err"; then fail 'a tree matching no template commit resolved'; fi
grep -q 'no commit of' "$work/err" || fail 'the refusal does not say why'
echo 'PASS: an exact copy resolves; an edited copy fails loudly'

# 4. A child of a commit only on a side branch names that branch.
use_template "$work/side" "$C3"
out=$(resolve --dir "$work/side")
[ "$(field commit "$out")" = "$C3" ] && [ "$(field branch "$out")" = side ] || fail "side-branch child: $out"
echo 'PASS: a side-branch commit records its branch'

# 5. Inside a checkout of the template itself, local HEAD is the answer
#    (unpushed work included, the #203 rationale).
g clone -q "$T" "$work/tcheck"
g -C "$work/tcheck" remote set-url origin "https://github.com/$SLUG.git"
printf 'unpushed\n' > "$work/tcheck/NEW"; g -C "$work/tcheck" add -A; g -C "$work/tcheck" commit -qm unpushed
out=$(bash "$pin" --slug "$SLUG" --dir "$work/tcheck")
[ "$(field commit "$out")" = "$(g -C "$work/tcheck" rev-parse HEAD)" ] && [ "$(field source "$out")" = template-checkout ] \
    || fail "template checkout: $out"
echo 'PASS: a template checkout records its own HEAD'

# 6. An asserted commit must exist in the template; one that does not is refused.
out=$(resolve --dir "$work/copy" --commit "$C1" 2>/dev/null)
[ "$(field commit "$out")" = "$C1" ] && [ "$(field tree "$out")" = "$T1" ] || fail "asserted commit: $out"
bogus=$(g -C "$work/child" rev-parse HEAD)
if resolve --dir "$work/child" --commit "$bogus" >/dev/null 2>&1; then fail "asserted the child's own commit"; fi
echo 'PASS: an asserted commit is verified against the template history'

# 7. Environment failures are loud: no template history, not a work tree, bad usage.
if bash "$pin" --slug "$SLUG" --url "$work/nowhere" --dir "$work/child" >/dev/null 2>&1; then fail 'an unreadable template resolved'; fi
mkdir -p "$work/plain"
if bash "$pin" --slug "$SLUG" --url "$T" --dir "$work/plain" >/dev/null 2>&1; then fail 'a non-git directory resolved'; fi
rc=0; bash "$pin" --dir "$work/child" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "missing --slug exited $rc, want 2"
echo 'PASS: unreadable template, non-git tree and bad usage all fail loudly'

# 8. A long history: the newest commit matches at once, and the search must
#    not die of SIGPIPE while git log is still writing. It did (exit 141)
#    against the real rsr-template-repo, whose history overflows the pipe
#    buffer; the three-commit fixture above could not show it.
L="$work/long"
mkdir -p "$L"; g -C "$L" init -q -b main
{
    for i in $(seq 1 3000); do
        printf 'commit refs/heads/main\nmark :%d\ncommitter t <t@t> %d +0000\ndata 2\nc\n' "$i" "$((1700000000 + i))"
        [ "$i" -gt 1 ] && printf 'from :%d\n' "$((i - 1))"
        printf 'M 100644 inline README.adoc\ndata %d\n%s\n\n' "$(( ${#i} + 1 ))" "$i"
    done
} | g -C "$L" fast-import --quiet
g -C "$L" checkout -q main
LC=$(g -C "$L" rev-parse HEAD)
rm -rf "$work/lchild"; mkdir -p "$work/lchild"; g -C "$L" archive HEAD | tar x -C "$work/lchild"
g -C "$work/lchild" init -q -b main; g -C "$work/lchild" add -A; g -C "$work/lchild" commit -qm "Initial commit"
out=$(bash "$pin" --slug "$SLUG" --url "$L" --dir "$work/lchild") || fail "a long template history failed to resolve (rc=$?)"
[ "$(field commit "$out")" = "$LC" ] || fail "long history resolved to $(field commit "$out"), want $LC"
echo 'PASS: a 3000-commit history resolves its newest commit without SIGPIPE'

# 9. Repeated trees (Codex review of #251). Commits A1 and A2 (empty) share a
#    tree; B follows with another. Dates are pinned so creation time decides.
A="$work/amb"
mkdir -p "$A"; g -C "$A" init -q -b main
at() { GIT_COMMITTER_DATE="@$1 +0000" GIT_AUTHOR_DATE="@$1 +0000" g -C "$A" "${@:2}"; }
printf 'a\n' > "$A/README.adoc"; g -C "$A" add -A; at 1700000100 commit -qm A1
A1=$(g -C "$A" rev-parse HEAD)
at 1700000200 commit -q --allow-empty -m A2; A2=$(g -C "$A" rev-parse HEAD)
printf 'b\n' > "$A/README.adoc"; at 1700000300 commit -qam B
# amb_child DIR EPOCH — a Use-this-template child with A1's tree, created at EPOCH.
amb_child() {
    rm -rf "$1"; mkdir -p "$1"; g -C "$A" archive "$A1" | tar x -C "$1"
    g -C "$1" init -q -b main; g -C "$1" add -A
    GIT_COMMITTER_DATE="@$2 +0000" GIT_AUTHOR_DATE="@$2 +0000" g -C "$1" commit -qm "Initial commit"
}
#    Created while A2 was the tip: the exact source is A2, by creation time.
amb_child "$work/amb-c1" 1700000250
out=$(bash "$pin" --slug "$SLUG" --url "$A" --dir "$work/amb-c1") || fail 'a child created at A2 did not resolve'
[ "$(field commit "$out")" = "$A2" ] || fail "child created at A2 resolved to $(field commit "$out")"
#    Created while A1 was the tip: A1, although A2 is newer with the same tree.
amb_child "$work/amb-c0" 1700000150
[ "$(field commit "$(bash "$pin" --slug "$SLUG" --url "$A" --dir "$work/amb-c0")")" = "$A1" ] \
    || fail 'a child created at A1 was not pinned to A1'
#    Created after B: the tip no longer has the tree, two commits do: refused.
amb_child "$work/amb-c2" 1700000400
if bash "$pin" --slug "$SLUG" --url "$A" --dir "$work/amb-c2" >/dev/null 2>"$work/err"; then
    fail 'an ambiguous tree resolved to one commit silently'
fi
grep -q 'ambiguous' "$work/err" && grep -q "$A1" "$work/err" && grep -q "$A2" "$work/err" \
    || fail 'the ambiguity refusal does not list both commits'
[ "$(field commit "$(bash "$pin" --slug "$SLUG" --url "$A" --dir "$work/amb-c2" --commit "$A1" 2>/dev/null)")" = "$A1" ] \
    || fail 'an asserted commit did not settle the ambiguity'
#    An uncommitted copy has no creation time: refused too.
rm -rf "$work/amb-wt"; mkdir -p "$work/amb-wt"; g -C "$A" archive "$A1" | tar x -C "$work/amb-wt"; g -C "$work/amb-wt" init -q
if bash "$pin" --slug "$SLUG" --url "$A" --dir "$work/amb-wt" >/dev/null 2>&1; then fail 'an ambiguous work tree resolved silently'; fi
echo 'PASS: repeated trees resolve by creation time, or are refused and listed'

# 10. repo-init must take provenance from the resolver, not from local HEAD.
recipe="$repo/build/just/repo-init.just"
grep -q 'bash scripts/resolve-template-pin.sh' "$recipe" || fail 'repo-init does not call the resolver'
if grep -nE 'PARENT_(PIN|BRANCH|TREE)=\$\(git ' "$recipe"; then fail 'repo-init reads the parent pin from local git again'; fi
echo 'PASS: repo-init delegates provenance to the resolver'

echo 'PASS: template pin resolution'
