#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# gen-repo-map.sh copies each root entry's allowlist comment into the map. It
# once trimmed them with xargs, which parses quotes: a comment holding an
# apostrophe was cut at it (tsunami-breaker's `priv/` note came out as
# "elixir/OTP: an"), and quote marks were dropped. The comment must come through
# whole, apostrophes and quotes included.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g0() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

R="$work/r"
g0 init -q "$R"
mkdir -p "$R/.machine_readable" "$R/priv"
printf 'x\n' > "$R/priv/f"; printf 'y\n' > "$R/mise.toml"
cat > "$R/.machine_readable/root-allow.txt" <<'EOF'
.machine_readable/
?priv/      # elixir/OTP: an application's priv dir is fixed at the project root
mise.toml   # every tool at "latest"
EOF
g0 -C "$R" add -A
bash "$repo/scripts/gen-repo-map.sh" "$R" >/dev/null 2>"$work/err" || { cat "$work/err" >&2; fail 'gen-repo-map.sh failed'; }
map="$R/docs/architecture/REPOSITORY-MAP.adoc"
grep -qxF "| elixir/OTP: an application's priv dir is fixed at the project root" "$map" \
    || { grep -n -A2 'priv/' "$map" >&2; fail 'a comment holding an apostrophe was cut'; }
grep -qxF '| every tool at "latest"' "$map" \
    || { grep -n -A2 'mise.toml' "$map" >&2; fail 'quote marks were dropped from a comment'; }
echo 'PASS: gen-repo-map.sh keeps allowlist comments whole, apostrophes and quotes included'
