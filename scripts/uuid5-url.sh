#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# uuid5-url.sh NAME — the UUIDv5 of NAME in the RFC 9562 URL namespace, the
# same on every machine: equal to `uuidgen --sha1 --namespace @url --name NAME`
# (util-linux), which macOS's uuidgen cannot compute (it has no --sha1).
#
# RFC 9562 §5.5: SHA-1 over the namespace's 16 bytes followed by NAME's bytes,
# truncated to 16 bytes, the version nibble set to 5 and the variant to 10xx.
# SHA-1 comes from sha1sum, shasum or openssl, whichever is installed first.
#
# Exit: 0 printed; 2 usage, or no SHA-1 tool (it never guesses).
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: uuid5-url.sh NAME" >&2; exit 2; }

sha1() {
    if command -v sha1sum >/dev/null 2>&1; then sha1sum # NOSONAR shell:S4790: RFC 9562 mandates SHA-1 for UUIDv5
    elif command -v shasum >/dev/null 2>&1; then shasum -a 1 # NOSONAR shell:S4790: RFC 9562 mandates SHA-1 for UUIDv5
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha1 -r # NOSONAR shell:S4790: RFC 9562 mandates SHA-1 for UUIDv5
    else echo "uuid5-url.sh: needs sha1sum, shasum or openssl" >&2; return 2
    fi
}
# 6ba7b811-9dad-11d1-80b4-00c04fd430c8, the URL namespace (RFC 9562 §6.6).
h="$( { printf '\x6b\xa7\xb8\x11\x9d\xad\x11\xd1\x80\xb4\x00\xc0\x4f\xd4\x30\xc8'
        printf '%s' "$1"; } | sha1 )" || exit 2
[[ "$h" =~ ^[0-9a-f]{40} ]] || { echo "uuid5-url.sh: the SHA-1 tool printed '$h'" >&2; exit 2; }
printf '%s-%s-5%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" \
    $(( (16#${h:16:1} & 3) | 8 )) "${h:17:3}" "${h:20:12}"
