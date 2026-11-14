#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# rsr-campaign.sh checks each propagated file for unfilled {{TOKEN}}s. A file
# with none (the usual case) made its grep exit 1, and pipefail + set -e then
# ended the whole campaign at the first ordinary file, before any report row.
# A dry run over a tokenless path must finish and report every repository.
# Network-free: git's insteadOf points https://github.com/ at local remotes.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g0() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

S="$work/spine"; g0 init -q -b main "$S"
mkdir -p "$S/notes"; printf 'new text, no tokens\n' > "$S/notes/plain.txt"
g0 -C "$S" add -A; g0 -C "$S" commit -q -m spine

for name in first second; do
    R="$work/src/$name"; g0 init -q -b main "$R"
    mkdir -p "$R/notes"; printf 'old text\n' > "$R/notes/plain.txt"
    g0 -C "$R" add -A; g0 -C "$R" commit -q -m init
    mkdir -p "$work/remotes/owner"; g0 clone -q --bare "$R" "$work/remotes/owner/$name.git"
done
printf 'owner/first\nowner/second\n' > "$work/repos.txt"
printf '[meta]\nname = chore/tokenless-check\n[paths]\nnotes/plain.txt\n' > "$work/m.campaign"

rc=0
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$work/remotes/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/" \
    bash "$repo/scripts/rsr-campaign.sh" --manifest "$work/m.campaign" --repos-file "$work/repos.txt" \
    --spine "$S" --work-dir "$work/run" --report "$work/report.tsv" >"$work/out" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || { cat "$work/out" >&2; fail "the dry run exited $rc on a tokenless path"; }
for name in first second; do
    grep -qP "^owner/$name\tnotes/plain.txt\tUPDATED\t" "$work/report.tsv" \
        || { cat "$work/report.tsv" >&2; fail "owner/$name has no UPDATED row"; }
done
echo 'PASS: rsr-campaign.sh finishes a dry run over a tokenless path and reports every repository'
