#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# rust-tool.sh — compile-on-demand runner for the single-file Rust mint tools.
#
# Ruby was the previous implementation of these tools; it is not an
# estate-authorised language, so they are Rust now. Each tool is a single
# std-only file, which `rustc` compiles in well under a second with no
# dependency resolution and no build system.
#
# Binaries are cached, and rebuilt only when the source is newer, so a machine
# pays the compile cost once rather than once per mint. Override the cache
# location with RSR_MINT_TOOL_CACHE.
#
# Usage: scripts/rust-tool.sh <tool-name> [args...]

set -euo pipefail

name="${1:-}"
[ -n "$name" ] || { echo "rust-tool: usage: rust-tool.sh <tool-name> [args...]" >&2; exit 2; }
shift

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$scripts_dir/$name.rs"

[ -f "$src" ] || { echo "rust-tool: no such tool: $src" >&2; exit 2; }

cache="${RSR_MINT_TOOL_CACHE:-${TMPDIR:-/tmp}/rsr-mint-tools}"
mkdir -p "$cache"
# The binary is named by the CONTENT of its source, not by the tool name and
# a modification time. Keyed by name with an mtime check, two checkouts with
# different versions of a tool shared one binary, and a source whose mtime
# was older than the cached build (any fresh clone or checkout can produce
# one) silently ran the OTHER version. strip-instruction-blocks changed its
# interface in #251 (files, not a directory), so a stale binary would now
# mis-run a mint rather than merely differ.
if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$src" | cut -c1-16)"
else
    digest="$(shasum -a 256 "$src" | cut -c1-16)"
fi
bin="$cache/$name-$digest"

# Compile only when no binary exists for this exact source, so the common
# case is a straight exec. Build to a temporary name and rename, so a
# concurrent mint never executes a half-written binary.
if [ ! -x "$bin" ]; then
    # The toolchain is needed to BUILD, not to RUN. Checking for rustc up
    # front made a cached binary unusable on a machine without one, which is
    # the common case in CI: the run is a straight exec. Only ask for rustc
    # when a build actually has to happen.
    command -v rustc >/dev/null 2>&1 || {
        echo "rust-tool: rustc not found, and $name is not built yet." >&2
        echo "           The mint tools are Rust and need a Rust toolchain." >&2
        echo "           Install one from https://rustup.rs, then re-run." >&2
        exit 2
    }
    tmp_bin="$bin.tmp.$$"
    rustc -O -o "$tmp_bin" "$src" >&2 || {
        rm -f "$tmp_bin"
        echo "rust-tool: failed to compile $src" >&2
        exit 2
    }
    mv -f "$tmp_bin" "$bin"
fi

exec "$bin" "$@"
