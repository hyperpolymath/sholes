#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# uuid-v8.sh DOMAIN NAME — the ADR-008 profile C UUIDv8 of NAME in DOMAIN,
# the same on every machine and equal to standards `scripts/uuid-v8.js c`:
# the first 16 bytes of SHA-256(DOMAIN ":" NAME), the version nibble set to 8
# and the variant to 10xx. A repo's chora id is the profile C id of its birth
# path in the domain chora-registry (standards A1 rules V8 and V9, A7 J11); an
# id minted before V9 keeps its gv-clade-index id and is never reminted.
# SHA-256 comes from sha256sum, shasum or openssl, whichever is installed first.
#
# Exit: 0 printed; 2 usage, a DOMAIN that is empty or holds ":", or no
# SHA-256 tool (it never guesses).
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: uuid-v8.sh DOMAIN NAME" >&2; exit 2; }
[[ "$1" =~ ^[!-9\;-~]+$ ]] \
    || { echo "uuid-v8.sh: DOMAIN must be non-empty printable ASCII without ':'" >&2; exit 2; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r
    else echo "uuid-v8.sh: needs sha256sum, shasum or openssl" >&2; return 2
    fi
}
h="$(printf '%s:%s' "$1" "$2" | sha256)" || exit 2
[[ "$h" =~ ^[0-9a-f]{64} ]] || { echo "uuid-v8.sh: the SHA-256 tool printed '$h'" >&2; exit 2; }
printf '%s-%s-8%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" \
    $(( (16#${h:16:1} & 3) | 8 )) "${h:17:3}" "${h:20:12}"
