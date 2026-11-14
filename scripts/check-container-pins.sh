#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-container-pins.sh — every base image in a Containerfile is pinned by
# digest, and no Dockerfile is shipped.
#
# ── Why this exists ─────────────────────────────────────────────────────────
#
# The estate's Trustfile carries a check called `container-images-pinned`. Its
# probe, as shipped, was:
#
#     test ! -f Containerfile || grep -q 'cgr.dev\|@sha256:' Containerfile
#
# which passes on `FROM cgr.dev/chainguard/wolfi-base:latest`. It asks "is one of
# the good registries named anywhere in the file", not "is every base image
# pinned", so the gate could not fail on the exact case it was named for — and a
# template that shipped two floating `:latest` stages passed it in every repo
# minted from it.
#
# A digest is the only reference that cannot move. A tag is a pointer the
# upstream may repoint at any time; `:latest` is a pointer that is *meant* to be
# repointed. So:
#
#   * every FROM must carry `@sha256:<64 hex>`;
#   * `FROM scratch` and `FROM <earlier stage>` are allowed (there is no remote
#     image to pin);
#   * a variable/ARG base is a FAIL: the pin would live at build time, outside
#     the file the gate reads, so the check could not see it;
#   * a Dockerfile is a FAIL (estate convention: Containerfile).
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   check-container-pins.sh [--root DIR] [--quiet]
#
# Exit: 0 = pinned (or no Containerfile); 1 = findings; 2 = usage error.
#
# A repository that ships NO Containerfile passes: shipping one is the repo's
# choice, and the template now only ships it to archetypes that declare the
# `container` capability. What is not allowed is shipping a floating one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)    ROOT="${2:-}"; shift 2 ;;
        --quiet)   QUIET=1; shift ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "check-container-pins: unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -d "$ROOT" ] || { echo "check-container-pins: not a directory: $ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"

ok()   { [ "$QUIET" -eq 1 ] || printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
note() { [ "$QUIET" -eq 1 ] || printf '        %s\n' "$1"; }

# Absolute paths, whichever source they came from. `git -C DIR ls-files` emits
# paths relative to DIR, so a relative result only resolved while the caller's
# cwd happened to BE the repository: `--root /elsewhere` silently found no
# Containerfiles at all and reported "nothing to pin". Measured while minting,
# where the gate runs from the template's cwd against a child tree.
list_files() {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$ROOT" ls-files -z --cached --others --exclude-standard \
            | while IFS= read -r -d '' f; do printf '%s\0' "$ROOT/$f"; done
    else
        find "$ROOT" -type f -print0
    fi | while IFS= read -r -d '' f; do
        case "$f" in */.git/*|*/node_modules/*|*/target/*|*/_build/*|*/deps/*) continue ;; esac
        # The index is not the work tree: the mint gates a tree it has already
        # pruned but not yet committed, so git still lists paths that are gone.
        [ -f "$f" ] || continue
        printf '%s\n' "$f"
    done
}

mapfile -t FILES < <(list_files | sort -u)

# Scope, stated rather than implied:
#   * a DEV container (.devcontainer/) is a rebuild-daily development
#     environment, not an artifact that ships, so it is out of this gate's
#     remit — the same scope the estate's own Trustfile probe has (it reads the
#     ROOT Containerfile only). It is named here so the exclusion is visible;
#   * build/container/Containerfile, if a repository has one, is CARRIER data
#     carried over from the template's container module: the template ships the
#     module (not the Containerfile — see build/container/README.adoc), and
#     prunes it from every archetype that declares no `container` capability.
#     While this tree is the template (archetypes/ present), that path is not
#     deployed from it.
IS_TEMPLATE=0
[ -d "$ROOT/archetypes" ] && IS_TEMPLATE=1

CONTAINERFILES=()
DOCKERFILES=()
SKIPPED=()
for f in "${FILES[@]}"; do
    rel="${f#"$ROOT"/}"
    case "$rel" in
        .devcontainer/*|*/.devcontainer/*)
            case "${rel##*/}" in
                Containerfile|Containerfile.*|*.Containerfile) SKIPPED+=("$rel (dev container)") ;;
            esac
            continue ;;
    esac
    case "$rel" in
        build/container/Containerfile|container/Containerfile)
            if [ "$IS_TEMPLATE" -eq 1 ]; then SKIPPED+=("$rel (carrier: template only)"); continue; fi ;;
    esac
    case "${rel##*/}" in
        Dockerfile|Dockerfile.*|*.Dockerfile) DOCKERFILES+=("$rel") ;;
        Containerfile|Containerfile.*|*.Containerfile|*.containerfile) CONTAINERFILES+=("$rel") ;;
    esac
done

FAILS=0

if [ ${#DOCKERFILES[@]} -gt 0 ]; then
    bad "${#DOCKERFILES[@]} Dockerfile(s) — the estate spelling is Containerfile"
    for f in "${DOCKERFILES[@]}"; do printf '        %s\n' "$f"; done
    note "Rename to Containerfile and update the engine invocation (podman -f)."
    FAILS=$((FAILS + 1))
fi

if [ "$QUIET" -eq 0 ] && [ ${#SKIPPED[@]} -gt 0 ]; then
    for s in "${SKIPPED[@]}"; do printf '  \033[34minfo\033[0m  out of scope: %s\n' "$s"; done
fi

if [ ${#CONTAINERFILES[@]} -eq 0 ]; then
    # FAILS is already non-zero when a Dockerfile was found above. Taking the
    # "nothing to pin" success path there reported PASS for the one repository
    # shape this branch exists to catch.
    if [ "$FAILS" -ne 0 ]; then
        note "Why: TRUST-DEFAULTS-POLICY §containers, Trustfile check container-images-pinned."
        exit 1
    fi
    ok "no shipped Containerfile — nothing to pin (shipping one is optional)"
    exit 0
fi

# A reference is pinned when it names a digest and nothing else can move it.
is_pinned() {
    local ref="$1"
    case "$ref" in
        *'$'*|*'@'*) : ;;   # a variable or a digest: judged below
    esac
    case "$ref" in
        *'$'*) return 1 ;;                          # build-time pin: not visible here
        *@sha256:*) 
            local d="${ref##*@sha256:}"
            case "$d" in
                *[!0-9a-f]*) return 1 ;;
                *) [ ${#d} -eq 64 ] && return 0 || return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

for cf in "${CONTAINERFILES[@]}"; do
    STAGES=" "
    HAD_FROM=0
    while IFS= read -r line; do
        # FROM is case-insensitive and may carry --platform=; comments ignored.
        stripped="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e '/^#/d')"
        case "$stripped" in [Ff][Rr][Oo][Mm][[:space:]]*) ;; *) continue ;; esac
        HAD_FROM=1
        # shellcheck disable=SC2086
        set -- $stripped
        shift                                  # drop FROM
        while [ $# -gt 0 ]; do                 # drop --platform=… and friends
            case "$1" in --*) shift ;; *) break ;; esac
        done
        ref="${1:-}"
        stage=""
        if [ "${2:-}" = "AS" ] || [ "${2:-}" = "as" ]; then stage="${3:-}"; fi
        # Register the stage name FIRST: `FROM image@sha256:… AS build` is a
        # pinned line, so it `continue`s below, and a later `FROM build` then
        # looked like an unpinned remote image because its stage had never been
        # recorded. Measured on the ordinary multi-stage shape.
        [ -n "$stage" ] && STAGES="$STAGES$stage "
        if [ -z "$ref" ]; then
            bad "$cf: FROM with no image reference"
            FAILS=$((FAILS + 1))
            continue
        fi
        case "$ref" in
            scratch) continue ;;
        esac
        case "$STAGES" in *" $ref "*) continue ;; esac   # a previous stage, not an image
        if is_pinned "$ref"; then
            continue
        fi
        case "$ref" in
            *:latest|*:latest@*)
                bad "$cf: floating base image '$ref'"
                note "pin: $ref@sha256:<digest> — resolve the digest with podman image inspect <image>" ;;
            *'$'*)
                bad "$cf: base image from a variable '$ref' — the pin lives outside this file"
                note "use a literal <repo>@sha256:<digest>, or the gate cannot see the pin" ;;
            *@sha256:*)
                bad "$cf: malformed digest in '$ref' (need exactly 64 lowercase hex)"
                note "digests look like: cgr.dev/chainguard/wolfi-base@sha256:$(printf '0%.0s' $(seq 1 64))" ;;
            *:*)
                bad "$cf: base image '$ref' has a tag but no digest"
                note "a tag can be repointed; add @sha256:<digest> beside it" ;;
            *)
                bad "$cf: base image '$ref' has no tag and no digest (implicit :latest)"
                note "add @sha256:<digest>" ;;
        esac
        FAILS=$((FAILS + 1))
    done < "$ROOT/$cf"
    if [ "$HAD_FROM" -eq 0 ]; then
        bad "$cf: no FROM line — this file builds nothing"
        FAILS=$((FAILS + 1))
    fi
done

if [ "$FAILS" -eq 0 ]; then
    ok "container base images pinned by digest (${#CONTAINERFILES[@]} Containerfile(s))"
    exit 0
fi
note "Why: TRUST-DEFAULTS-POLICY §containers, Trustfile check container-images-pinned."
exit 1
