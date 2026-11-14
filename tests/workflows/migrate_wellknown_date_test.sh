#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# A divergent legacy .well-known/ file is quarantined under a dated name. At
# mint the date must be the mint's own, so the drift gate's replay on a later
# day names it the same (Codex review of #275): repo-init passes --date. The
# default stays today (UTC), and a malformed date is refused, not used.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g0() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

# fixture DIR — a repo whose root and www/ copies of security.txt diverge.
fixture() {
    g0 init -q "$1"
    mkdir -p "$1/.well-known" "$1/www/.well-known"
    printf 'Contact: mailto:root@example.org\n' > "$1/.well-known/security.txt"
    printf 'Contact: mailto:www@example.org\n' > "$1/www/.well-known/security.txt"
    g0 -C "$1" add -A; g0 -C "$1" commit -q -m fixture
}

A="$work/a"; fixture "$A"
(cd "$A" && bash "$repo/scripts/migrate-wellknown-to-www.sh" --date 2001-02-03) > "$work/a.log" 2>&1 \
    || { cat "$work/a.log" >&2; fail 'the migration failed with --date'; }
[ -f "$A/www/.legacy-well-known-20010203/security.txt" ] \
    || { find "$A/www" >&2; fail 'the quarantine is not named by --date'; }
echo 'PASS: --date names the quarantine (a replay on another day names it the same)'

B="$work/b"; fixture "$B"
today=$(date -u +%Y%m%d)
(cd "$B" && bash "$repo/scripts/migrate-wellknown-to-www.sh") > "$work/b.log" 2>&1 \
    || { cat "$work/b.log" >&2; fail 'the migration failed without --date'; }
# The day can turn between the two date calls; either name is today's.
[ -f "$B/www/.legacy-well-known-$today/security.txt" ] || [ -f "$B/www/.legacy-well-known-$(date -u +%Y%m%d)/security.txt" ] \
    || { find "$B/www" >&2; fail 'without --date the quarantine is not named by today'; }
echo 'PASS: without --date the quarantine is named by today (UTC)'

Cdir="$work/c"; fixture "$Cdir"
rc=0; (cd "$Cdir" && bash "$repo/scripts/migrate-wellknown-to-www.sh" --date 2001-2-3) > "$work/c.log" 2>&1 || rc=$?
[ "$rc" -eq 2 ] && grep -q -- '--date must be YYYY-MM-DD' "$work/c.log" && [ -f "$Cdir/.well-known/security.txt" ] \
    || { cat "$work/c.log" >&2; fail "a malformed --date was not refused before writing (exit $rc)"; }
echo 'PASS: (-) a malformed --date is refused before anything moves'

grep -q 'migrate-wellknown-to-www.sh --date "\$CURRENT_DATE"' "$repo/build/just/repo-init.just" \
    || fail 'repo-init does not pass its mint date to the migration'
echo 'PASS: repo-init passes its mint date'
