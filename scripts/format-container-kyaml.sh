#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# format-container-kyaml.sh — reformat the container KYAML configs after
# their tokens are filled.
#
# The template quotes every token, keys included, because a brace token is
# not a plain YAML scalar. Once `repo-init` or `container-init` fills one,
# the quoting is no longer what canonical KYAML writes (a filled service-name
# key needs none), and Estate Rules' "Converted YAML stays KYAML" fails the
# child. Both recipes call this after their substitution pass.
#
# The formatter needs a yq that writes KYAML (mikefarah yq; mise.toml provides
# it). `container-init` runs `--preflight` before it writes; `repo-init` runs it
# through scripts/check-mint-tools.sh, before it writes anything, so a missing
# yq stops either with the tree untouched instead of half-minted.
#
# The values fill double-quoted KYAML scalars, so a quote or backslash in one
# would leave a file the formatter refuses after the tree is written. Both
# recipes run `--check-values` on the answers before they write anything.
#
# Usage: format-container-kyaml.sh [--preflight] [REPO_ROOT]
#        format-container-kyaml.sh --check-values SERVICE_NAME PORT REGISTRY
#   --preflight     write nothing; fail when configs are present and no
#                   KYAML-capable yq is on PATH.
#   --check-values  fail unless SERVICE_NAME is a DNS label (lower-case
#                   letters, digits and inner hyphens, at most 63), PORT is
#                   1-65535 and REGISTRY is an image prefix (a host or an
#                   [IPv6] address in RFC 4291 text, an optional :port from
#                   1 to 65535, then
#                   lower-case path components).
# Exit: 0 = formatted (or nothing to format: an archetype may prune
#       build/container/), or values accepted; 1 = no KYAML-capable yq, a
#       value refused, or the formatter refused a file (unparseable, data
#       change), with the reason on stderr.
set -euo pipefail
if [ "${1:-}" = --check-values ]; then
    name="${2:-}" port="${3:-}" registry="${4:-}" bad=0
    # The service name is an image name component, a compose service key, a
    # bare TOML table key (stapeln/compose.toml) and the backend's hostname on
    # the container network (http://NAME:PORT). A DNS label is valid as all
    # four; a dot would nest the TOML table and an underscore is no hostname.
    [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
        || { echo "error: service name '$name' is not a DNS label (lower-case letters, digits and inner hyphens, at most 63)." >&2; bad=1; }
    in_port_range() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; }
    in_port_range "$port" \
        || { echo "error: port '$port' is not a number from 1 to 65535." >&2; bad=1; }
    # A registry is the image prefix: a host (DNS labels, or a bracketed IPv6
    # address), an optional :port, then lower-case path components, as the
    # distribution reference grammar has it.
    label='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
    host="($label(\.$label)*|\[[A-Fa-f0-9:]+\])"
    comp='[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*'
    # The grammar takes any digits as the port; a usable one is 1-65535. An
    # IPv6 host ends in "]", so a trailing ":digits" before the path is a port.
    registry_port=""
    if [[ "${registry%%/*}" =~ :([0-9]+)$ ]]; then registry_port="${BASH_REMATCH[1]}"; fi
    # The grammar's bracket form is any hex and colons; an address is RFC 4291
    # text: eight groups of 1-4 hex digits, or fewer around a single "::".
    is_ipv6() {
        local a="$1" g n=0 groups
        [[ "$a" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
        [[ "$a" != *:::* ]] || return 1
        [[ "$a" != :* || "$a" == ::* ]] || return 1
        [[ "$a" != *: || "$a" == *:: ]] || return 1
        IFS=: read -ra groups <<< "$a"
        for g in "${groups[@]}"; do
            [ -n "$g" ] || continue
            [ "${#g}" -le 4 ] || return 1
            n=$((n + 1))
        done
        case "$a" in
            *::*::*) return 1 ;;
            *::*) [ "$n" -le 7 ] ;;
            *) [ "$n" -eq 8 ] ;;
        esac
    }
    registry_v6=""
    if [[ "$registry" == \[* ]]; then registry_v6="${registry#\[}"; registry_v6="${registry_v6%%\]*}"; fi
    if ! [[ "$registry" =~ ^$host(:[0-9]+)?(/$comp)*$ ]] \
        || { [ -n "$registry_port" ] && ! in_port_range "$registry_port"; } \
        || { [[ "$registry" == \[* ]] && ! is_ipv6 "$registry_v6"; }; then
        echo "error: registry '$registry' is not an image prefix: a host or [IPv6] address, an optional :port from 1 to 65535, then lower-case path components (letters, digits, . _ -)." >&2; bad=1
    fi
    exit "$bad"
fi
PREFLIGHT=0
if [ "${1:-}" = --preflight ]; then PREFLIGHT=1; shift; fi
cd "${1:-.}"

files=()
for f in build/container/compose.yaml build/container/compose.example.yaml \
         build/container/stapeln/.gatekeeper.yaml; do
    if [ -f "$f" ]; then files+=("$f"); fi
done
[ "${#files[@]}" -gt 0 ] || exit 0

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q mikefarah || ! printf 'a: 1\n' | yq -p yaml -o kyaml '.' >/dev/null 2>&1; then
    {
        echo "error: the container configs need a yq that writes KYAML (mikefarah yq"
        echo "  v4.53.3+) once their tokens are filled, and the yq on PATH is not one (or none is)."
        echo "  Run 'mise install' (mise.toml provides yq), or install mikefarah yq."
    } >&2
    exit 1
fi
[ "$PREFLIGHT" -eq 0 ] || exit 0

if ! bash scripts/kyaml-format.sh "${files[@]}"; then
    echo "error: the KYAML formatter refused a container config (see above)." >&2
    exit 1
fi
