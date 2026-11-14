#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# replay-mint.sh runs the real recipe under RSR_MINT_REPLAY=1, where repo-init
# trusts RSR_PACKAGE_UUID. Only a recorded (mint-answers :package-uuid) may
# supply it: a fresh mint (a chain mint's new side) must not inherit one from
# the caller's environment, or a stray value would become the child's Julia
# package identity (Codex review of #275). A stub `just` records what the
# replay passes, so no mint runs and this takes a second.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

T="$work/template"; mkdir -p "$T"; printf 'x\n' > "$T/f"
g -C "$T" init -q -b main; g -C "$T" add -A; g -C "$T" commit -q -m t
PIN=$(g -C "$T" rev-parse HEAD)
mkdir -p "$work/bin"
cat > "$work/bin/just" <<'FAKE_JUST'
#!/usr/bin/env bash
printf '%s|%s\n' "${RSR_PACKAGE_UUID:-}" "${RSR_MINT_REPLAY:-}" > .env-probe
FAKE_JUST
chmod +x "$work/bin/just"
replay() { PATH="$work/bin:$PATH" bash "$repo/scripts/replay-mint.sh" "$T" "$PIN" "$@" >/dev/null; }
STRAY=00000000-0000-8000-8000-000000000000
RECORDED=9271df15-3174-8475-ac0b-136d649c1f76

# 1. A fresh mint ignores a package uuid in the caller's environment.
RSR_PACKAGE_UUID="$STRAY" OWNER=o REPO=r replay "$work/fresh"
[ "$(cat "$work/fresh/.env-probe")" = "|1" ] \
    || fail "a fresh replay passed '$(cat "$work/fresh/.env-probe")'; expected no package uuid under RSR_MINT_REPLAY=1"

# 2. A replay from a deed passes the recorded uuid, over the environment's.
printf '(repo-deed\n  (mint-answers\n    :repo "r"\n    :owner "o"\n    :package-uuid "%s"))\n' "$RECORDED" > "$work/x_chora.deed"
RSR_PACKAGE_UUID="$STRAY" replay "$work/recorded" --answers-from "$work/x_chora.deed"
[ "$(cat "$work/recorded/.env-probe")" = "$RECORDED|1" ] \
    || fail "a recorded replay passed '$(cat "$work/recorded/.env-probe")'; expected the recorded uuid"
echo "PASS: replay-mint passes a package uuid only from recorded answers"
