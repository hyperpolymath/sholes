#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# pin-container-digests.sh — turn a floating Containerfile into a pinned one.
#
# The template used to ship `FROM …:latest` twice and let the reader work out
# that `:latest` is a moving target. A template that ships it makes every child
# fail `container-images-pinned` until a human pins digests, so the fix has to be
# mechanical and it has to refuse to pretend:
#
#   * a digest is exactly 64 lowercase hex characters, and nothing else is
#     accepted — a truncated digest is a reference that resolves to nothing;
#   * `pin` rewrites every FROM in the named files, leaving `scratch` and
#     stage-relative FROMs alone;
#   * with no digest it FAILS and says how to resolve one, because "pinned by
#     default at some later date" is how the defect survived in the first place.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   pin-container-digests.sh --root DIR --base <64hex> [--runtime <64hex>] FILE...
#
#   --base D      digest for the FIRST (builder) FROM
#   --runtime D   digest for the remaining FROMs (default: --base)
#   FILE...       Containerfiles to rewrite, relative to --root
#
# Resolve a digest on a machine that can pull:
#   podman pull cgr.dev/chainguard/wolfi-base:latest
#   podman image inspect --format '{{index .RepoDigests 0}}' cgr.dev/chainguard/wolfi-base:latest
#   -> cgr.dev/chainguard/wolfi-base@sha256:<64 hex>
#
# Exit: 0 = rewritten (or already pinned); 1 = no/invalid digest or bad FROM;
#       2 = usage error.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE=""
RUNTIME=""
FILES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --root)    ROOT="${2:-}"; shift 2 ;;
        --base)    BASE="${2:-}"; shift 2 ;;
        --runtime) RUNTIME="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*)       echo "pin-container-digests: unknown option: $1" >&2; exit 2 ;;
        *)         FILES+=("$1"); shift ;;
    esac
done

[ -d "$ROOT" ] || { echo "pin-container-digests: not a directory: $ROOT" >&2; exit 2; }
[ ${#FILES[@]} -gt 0 ] || { echo "pin-container-digests: no Containerfile named" >&2; exit 2; }

hex64() { case "${1:-}" in (*[!0-9a-f]*) return 1 ;; esac; [ ${#1} -eq 64 ]; }

if ! hex64 "$BASE"; then
    echo "FAIL: --base must be a 64-character lowercase hex digest (got '${BASE}')" >&2
    echo "" >&2
    echo "Resolve it where the image can be pulled:" >&2
    echo "  podman pull cgr.dev/chainguard/wolfi-base:latest" >&2
    echo "  podman image inspect --format '{{index .RepoDigests 0}}' cgr.dev/chainguard/wolfi-base:latest" >&2
    echo "" >&2
    echo "A Containerfile is not shipped unpinned, and this script will not invent" >&2
    echo "a digest: a wrong digest is a build that fails later, on someone else's" >&2
    echo "machine, with a supply-chain claim attached to it." >&2
    exit 1
fi
[ -n "$RUNTIME" ] || RUNTIME="$BASE"
hex64 "$RUNTIME" || { echo "FAIL: --runtime must be 64 lowercase hex characters" >&2; exit 1; }

rewrite_one() {
    local path="$1" idx=0 tmp stages=" " head rest flag ref after base stage
    [ -f "$path" ] || { echo "pin-container-digests: no such file: $path" >&2; return 1; }
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//')"
        case "$stripped" in
            [Ff][Rr][Oo][Mm][[:space:]]*) ;;
            *) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        idx=$((idx + 1))
        # Split the instruction into FROM + flags + reference + whatever follows,
        # so only the reference is ever rewritten. The previous sed replaced the
        # tail of the whole line, which turned `FROM build` and `FROM scratch`
        # into `build@sha256:…` / `scratch@sha256:…` — corrupting exactly the
        # multi-stage files it should leave alone — and rewrote `AS <stage>`
        # whenever its spacing differed from the two forms the regex knew.
        head="${stripped%%[[:space:]]*}"
        rest="${stripped#"$head"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        while :; do
            case "$rest" in
                --*) flag="${rest%%[[:space:]]*}"
                     head="$head $flag"
                     rest="${rest#"$flag"}"
                     rest="${rest#"${rest%%[![:space:]]*}"}" ;;
                *) break ;;
            esac
        done
        ref="${rest%%[[:space:]]*}"
        after="${rest#"$ref"}"
        stage=""
        case "$after" in
            [[:space:]]*[Aa][Ss][[:space:]]*) stage="${after##*[[:space:]]}" ;;
        esac
        # `FROM scratch` builds from nothing, and `FROM <earlier stage>` builds
        # from a stage: neither names a remote image, so neither takes a digest.
        case "$ref" in
            scratch) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        case "$stages" in
            *" $ref "*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        [ -n "$stage" ] && stages="$stages$stage "
        # A build-time variable is the file telling us the pin lives elsewhere.
        case "$ref" in
            *'$'*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        if printf '%s' "$ref" | grep -q '@sha256:[0-9a-f]\{64\}$'; then
            printf '%s\n' "$line" >> "$tmp"; continue
        fi
        base="${ref%%@sha256:*}"
        case "${base##*:}" in
            *[!0-9]*) base="${base%:*}" ;;   # a tag, not a registry port
        esac
        case "${ref##*@}" in
            sha256:*) : ;;                    # partial/malformed digest: drop it
        esac
        if [ "$idx" -eq 1 ]; then
            printf '%s %s@sha256:%s%s\n' "$head" "$base" "$BASE" "$after" >> "$tmp"
        else
            printf '%s %s@sha256:%s%s\n' "$head" "$base" "$RUNTIME" "$after" >> "$tmp"
        fi
    done < "$path"
    if ! cmp -s "$tmp" "$path"; then
        cp "$tmp" "$path"
        echo "pinned: ${path#"$ROOT"/} (${idx} FROM line(s))"
    else
        echo "already pinned: ${path#"$ROOT"/}"
    fi
    rm -f "$tmp"
    return 0
}

rc=0
for f in "${FILES[@]}"; do
    case "$f" in /*) rewrite_one "$f" || rc=1 ;; *) rewrite_one "$ROOT/$f" || rc=1 ;; esac
done
exit "$rc"
