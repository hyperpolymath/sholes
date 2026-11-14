#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-mint-tools.sh — refuse a mint BEFORE it writes anything when a tool the
# mint needs later is missing.
#
# `just repo-init` rewrites the tree first (archetype overlay, prune, the
# placeholder sed pass) and only then reaches two tools:
#   * a KYAML-capable mikefarah yq, for scripts/format-container-kyaml.sh;
#   * nickel, for .machine_readable/arrival-pack/generate.sh (`nickel export`).
# Without this check a missing tool stopped the mint after 100+ files were
# already rewritten. This reads and writes nothing.
#
# Which tools are demanded follows which steps are REACHED, not the mint kind.
# Archetype and chain mints reach the same two steps as a plain mint (the
# formatter is called unconditionally; the arrival pack is regenerated whenever
# generate.sh exists), so no mint kind is exempt. A tool is demanded only when
# its step can run: the formatter's own --preflight exits 0 when the tree has
# no container configs, and nickel is demanded only if generate.sh is present.
#
# Required versions are reported from the repo's own pins, never hard-coded
# here: mise.toml (when it names a concrete version), else the pin the CI
# install step / devcontainer uses. mise.toml provides yq ("latest"); it does
# not provide nickel, which CI and the devcontainer install by pinned release.
#
# Usage: check-mint-tools.sh [REPO_ROOT]
# Exit:  0 every needed tool is present; 1 one or more are missing (all listed).
set -uo pipefail

ROOT="${1:-.}"
cd "$ROOT" || { echo "error: cannot enter $ROOT" >&2; exit 1; }

# pin NAME FALLBACK_FILE FALLBACK_REGEX — a concrete mise.toml version wins;
# otherwise the first capture of FALLBACK_REGEX in FALLBACK_FILE; else "".
pin() {
    local name="$1" file="$2" re="$3" v=""
    if [ -f mise.toml ]; then
        v="$(sed -n -E "s/^${name}[[:space:]]*=[[:space:]]*\"([0-9][^\"]*)\".*/\1/p" mise.toml | head -1)"
    fi
    if [ -z "$v" ] && [ -f "$file" ]; then
        v="$(sed -n -E "s/.*${re}.*/\1/p" "$file" | head -1)"
    fi
    printf '%s' "$v"
}

missing=()

# (a) yq: the formatter's own preflight is the single definition of "capable".
if [ -f scripts/format-container-kyaml.sh ]; then
    if ! bash scripts/format-container-kyaml.sh --preflight . >/dev/null 2>&1; then
        v="$(pin yq .github/workflows/estate-rules.yml 'mikefarah\/yq\/releases\/download\/v([0-9.]+)\/')"
        missing+=("yq: a KYAML-capable mikefarah yq (>= ${v:-4.53.3}) is required for scripts/format-container-kyaml.sh; provided by mise (mise.toml: yq) — run 'mise install'")
    fi
fi

# (b) nickel: only when the arrival pack will be regenerated.
if [ -f .machine_readable/arrival-pack/generate.sh ]; then
    if ! command -v nickel >/dev/null 2>&1 || ! nickel --version >/dev/null 2>&1; then
        v="$(pin nickel .devcontainer/Containerfile 'ARG NICKEL_VERSION=([0-9.]+)')"
        missing+=("nickel: required by .machine_readable/arrival-pack/generate.sh (\`nickel export\`); pinned version ${v:-unknown}. mise.toml does not provide it: install the pinned Nickel release (see .devcontainer/Containerfile and the 'Install verified Nickel' step in .github/workflows/estate-rules.yml)")
    fi
fi

if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: mint aborted before writing anything — missing tool(s):" >&2
    for m in "${missing[@]}"; do echo "  - $m" >&2; done
    exit 1
fi
exit 0
