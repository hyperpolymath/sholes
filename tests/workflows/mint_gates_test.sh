#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# mint_gates_test.sh — every gate the template ships must be able to FAIL, and
# the failure must be demonstrated on a fixture.
#
# The estate has been bitten repeatedly by gates that read as coverage while
# changing no outcome: the SPDX check that globbed one language's extensions and
# passed in every other language; the container check that passed on
# `FROM …:latest` because it only asked whether `cgr.dev` appeared; a `quality`
# recipe that echoed "All quality checks passed!" over verbs that ran nothing.
# Each of those is a check with no failing input, and a check with no failing
# input cannot be reviewed by reading it.
#
# So each gate gets a POSITIVE fixture (must exit 0) and a NEGATIVE fixture (must
# exit 1). A gate that stops failing turns this test red — which is the only way
# a gate stays a gate.
#
# Usage: bash tests/workflows/mint_gates_test.sh
# Exit: 0 all controls hold; 1 a control failed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CHECKS=0
FAILED=0

pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

# expect_pass LABEL CMD… — the command must exit 0.
expect_pass() {
    local label="$1"; shift
    if "$@" >"$WORK/out" 2>&1; then pass "$label"; else
        bad "$label (expected exit 0, got $?)"
        sed 's/^/        /' "$WORK/out" | tail -20
    fi
}
# expect_fail LABEL CMD… — the command must exit NON-zero (any non-zero counts;
# 2 is a usage/environment error and would be a test bug, so it is called out).
expect_fail() {
    local label="$1"; shift
    local st=0
    "$@" >"$WORK/out" 2>&1 || st=$?
    if [ "$st" -eq 0 ]; then
        bad "$label (expected a failure, got exit 0)"
        sed 's/^/        /' "$WORK/out" | tail -10
    elif [ "$st" -eq 2 ]; then
        bad "$label (exit 2 is a usage or environment error, not a finding)"
        sed 's/^/        /' "$WORK/out" | tail -10
    else
        pass "$label"
    fi
}

spdx() { bash "$REPO_DIR/scripts/check-spdx-headers.sh" --quiet "$@"; }
pins() { bash "$REPO_DIR/scripts/check-container-pins.sh" --quiet "$@"; }
mise() { bash "$REPO_DIR/scripts/check-mise-language.sh" --quiet "$@"; }

echo "── SPDX (language-derived) ────────────────────────────────"

# Positive: the template itself.
expect_pass "SPDX passes on the template tree" spdx --root "$REPO_DIR"

# Negative 1: a Julia package whose only source has no header.
J="$WORK/jl-nohdr"; mkdir -p "$J/src"
printf 'name = "Demo"\n' > "$J/Project.toml"
printf 'module Demo\nend\n' > "$J/src/Demo.jl"
expect_fail "SPDX fails on a Julia file with no header" spdx --root "$J"

# Negative 2: the language is declared but no source of it exists — the exact
# shape the old fixed glob produced in a Julia repo (nothing scanned, PASS).
E="$WORK/jl-empty"; mkdir -p "$E"
printf 'name = "Demo"\n' > "$E/Project.toml"
expect_fail "SPDX fails when a declared language has no files" spdx --root "$E"

# Negative 3: nothing to scan at all — a gate that examined nothing is not a pass.
Z="$WORK/empty"; mkdir -p "$Z"
expect_fail "SPDX fails when it matches zero files" spdx --root "$Z" --langs docs

# Negative 4: a banned language present (Python), header or not.
P="$WORK/py"; mkdir -p "$P"
printf '# SPDX-License-Identifier: MPL-2.0\nprint(1)\n' > "$P/tool.py"
expect_fail "SPDX fails on banned-language source (.py)" spdx --root "$P" --langs docs

# Positive 2: header present → pass, and every declared extension is scanned.
OK="$WORK/jl-ok"; mkdir -p "$OK/src" "$OK/test"
printf 'name = "Demo"\n' > "$OK/Project.toml"
printf '# SPDX-License-Identifier: MPL-2.0\nmodule Demo\nend\n' > "$OK/src/Demo.jl"
printf '#!/usr/bin/env bash\n# SPDX-License-Identifier: MPL-2.0\ntrue\n' > "$OK/run.sh"
expect_pass "SPDX passes on a well-formed Julia fixture" spdx --root "$OK"

# Negative 5: a tracked file that no longer exists must not be counted as a
# finding. `just repo-init` prunes paths and gates the tree BEFORE committing, so
# the index still lists them; reading those paths made the gate report "3 files
# carry no header" for files that were already gone, and the mint aborted.
D="$WORK/deleted"; mkdir -p "$D/src"
printf '# SPDX-License-Identifier: MPL-2.0\nmodule Keep\nend\n' > "$D/src/keep.jl"
printf 'module Gone\nend\n' > "$D/src/gone.jl"
( cd "$D" && git init -q && git add -A \
    && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm x ) >/dev/null 2>&1
rm -f "$D/src/gone.jl"
expect_pass "SPDX ignores a tracked file that has been deleted" spdx --root "$D"

# A language whose mapping lists ALTERNATIVE extensions is present when any one
# of them is: an Elixir tree with .ex and no .exs was failed for a language it is
# written in, because emptiness was judged per extension instead of per language.
E="$WORK/elixir"; mkdir -p "$E/lib"
printf '# SPDX-License-Identifier: MPL-2.0\ndefmodule A do\nend\n' > "$E/lib/a.ex"
expect_pass "SPDX accepts any alternative extension of a declared language" \
    spdx --root "$E" --langs elixir --exts ex

echo ""
echo "── Container image pins ───────────────────────────────────"

D64="$(printf 'a%.0s' $(seq 1 64))"

C="$WORK/container"; mkdir -p "$C"
printf 'FROM cgr.dev/chainguard/wolfi-base:latest\n' > "$C/Containerfile"
expect_fail "pin gate fails on a floating :latest" pins --root "$C"

# …and it must find it from a FOREIGN cwd too. `git -C DIR ls-files` emits paths
# relative to DIR, so a fixture that is a git repository only worked while the
# caller's cwd was inside it; the mint runs these gates from the template's cwd
# against the child tree, which is exactly the case that slipped through.
G="$WORK/container-git"; mkdir -p "$G"
printf 'FROM cgr.dev/chainguard/wolfi-base:latest\n' > "$G/Containerfile"
( cd "$G" && git init -q && git add -A \
    && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm x ) >/dev/null 2>&1
expect_fail "pin gate fails on a floating :latest in a git tree, from a foreign cwd" pins --root "$G"

printf 'FROM cgr.dev/chainguard/wolfi-base:2026.10.30\n' > "$C/Containerfile"
expect_fail "pin gate fails on a tag without a digest" pins --root "$C"

printf 'FROM cgr.dev/chainguard/wolfi-base@sha256:%s\n' "$D64" > "$C/Containerfile"
expect_pass "pin gate passes on a digest-pinned image" pins --root "$C"

printf 'ARG BASE\nFROM ${BASE}\n' > "$C/Containerfile"
expect_fail "pin gate fails when the pin lives in a build argument" pins --root "$C"

printf 'FROM cgr.dev/chainguard/wolfi-base@sha256:deadbeef\n' > "$C/Containerfile"
expect_fail "pin gate fails on a truncated digest" pins --root "$C"

printf 'FROM cgr.dev/chainguard/wolfi-base@sha256:%s AS build\nFROM scratch\n' "$D64" > "$C/Containerfile"
expect_pass "pin gate allows a stage name and scratch" pins --root "$C"

printf 'FROM cgr.dev/chainguard/wolfi-base@sha256:%s\n' "$D64" > "$C/Dockerfile"
printf 'FROM cgr.dev/chainguard/wolfi-base@sha256:%s\n' "$D64" > "$C/Containerfile"
expect_fail "pin gate fails on a Dockerfile" pins --root "$C"
rm -f "$C/Dockerfile"

rm -f "$C/Containerfile"
expect_pass "pin gate passes when no Containerfile ships" pins --root "$C"

# The pinner: refuses to invent a digest, and rewrites a real one.
PI="$WORK/pinme"; mkdir -p "$PI"
printf 'FROM cgr.dev/chainguard/wolfi-base:latest AS builder\nFROM cgr.dev/chainguard/static:latest\n' > "$PI/Containerfile"
expect_fail "pinner refuses without a digest" \
    bash "$REPO_DIR/scripts/pin-container-digests.sh" --root "$PI" Containerfile
expect_pass "pinner rewrites both FROM lines" \
    bash "$REPO_DIR/scripts/pin-container-digests.sh" --root "$PI" --base "$D64" --runtime "$D64" Containerfile
expect_pass "pin gate passes after the pinner ran" pins --root "$PI"
if grep -q ':latest' "$PI/Containerfile"; then
    bad "pinner left a floating tag behind"
else
    pass "pinner removed the floating tag"
fi

# The pinner must not rewrite what is not a remote image: `FROM scratch` and
# `FROM <earlier stage>` take no digest, and rewriting them produced
# `build@sha256:…` — a Containerfile the companion gate then accepted.
RT="$WORK/pin-roundtrip"; mkdir -p "$RT"
B64="$(printf 'a%.0s' $(seq 1 64))"; R64="$(printf 'b%.0s' $(seq 1 64))"
cat > "$RT/Containerfile" <<'OLD'
FROM --platform=$BUILDPLATFORM cgr.dev/chainguard/wolfi-base:latest AS build
RUN true
FROM scratch
COPY --from=build /x /x
FROM build AS test
FROM cgr.dev/chainguard/static:latest
OLD
bash "$REPO_DIR/scripts/pin-container-digests.sh" --root "$RT" --base "$B64" --runtime "$R64" "$RT/Containerfile" >/dev/null 2>&1
grep -qx 'FROM scratch' "$RT/Containerfile" && pass "pinner leaves FROM scratch alone" \
    || bad "pinner rewrote FROM scratch"
grep -qx 'FROM build AS test' "$RT/Containerfile" && pass "pinner leaves a stage reference alone" \
    || bad "pinner rewrote a stage reference"
expect_pass "the pinned round-trip passes the pin gate" pins --root "$RT"

echo ""
echo "── mise.toml matches the declared languages ───────────────"

M="$WORK/mise"; mkdir -p "$M"
printf '[tools]\njulia = "latest"\njust = "latest"\n' > "$M/mise.toml"
expect_pass "mise gate passes when the toolchain matches" mise --root "$M" --langs julia --tools "julia just"

printf '[tools]\njulia = "latest"\njust = "latest"\npython = "latest"\n' > "$M/mise.toml"
expect_fail "mise gate fails on a banned tool" mise --root "$M" --langs julia --tools "julia just"

printf '[tools]\njust = "latest"\n' > "$M/mise.toml"
expect_fail "mise gate fails when the language tool is missing" mise --root "$M" --langs julia --tools "julia just"

printf '[tools]\njulia = "latest"\njust = "latest"\nzig = "latest"\n' > "$M/mise.toml"
expect_fail "mise gate fails on a tool no language needs" mise --root "$M" --langs julia --tools "julia just"

printf '[tools]\n' > "$M/mise.toml"
expect_fail "mise gate fails on an empty [tools] table" mise --root "$M" --langs julia --tools "julia just"

rm -f "$M/mise.toml"
expect_fail "mise gate fails when mise.toml is missing" mise --root "$M" --langs julia --tools "julia just"

# The template's own toolchain must match its own languages.
if bash "$REPO_DIR/scripts/is-template-tree.sh" "$REPO_DIR"; then
    expect_pass "mise gate passes on the template tree" mise --root "$REPO_DIR"
else
    echo "  SKIP  mise gate on the template tree (not the template tree)"
fi

# A backend-qualified tool MUST be a quoted TOML key ("npm:prettier"), so a
# parser that only read bare keys could never see the banned tool this gate
# exists to catch.
Q="$WORK/quoted"; mkdir -p "$Q"
printf '[tools]\njust = "latest"\nshellcheck = "latest"\ntrivy = "latest"\nrust = "latest"\ncargo = "latest"\nrustc = "latest"\n"npm:prettier" = "latest"\n' > "$Q/mise.toml"
printf '[package]\nname = "x"\n' > "$Q/Cargo.toml"
expect_fail "mise gate reads a quoted backend-qualified key" \
    mise --root "$Q" --langs rust --tools "just shellcheck trivy rust cargo rustc"

# --detect must look where provision-lib.sh looks. The template's own seam puts
# Idris2 at src/interface/abi.ipkg and Zig at src/interface/ffi/build.zig; a
# root-only mirror called such a tree `docs` and graded it against the wrong
# toolchain (this is the state every pre-engine repository is surveyed in).
DD="$WORK/detect-depth"; mkdir -p "$DD/src/interface/ffi"
printf '[package]\nname = "x"\n' > "$DD/Cargo.toml"
printf 'package x\n' > "$DD/src/interface/abi.ipkg"
printf 'x\n' > "$DD/src/interface/ffi/build.zig"
printf '[tools]\njust = "latest"\nshellcheck = "latest"\nyq = "latest"\ntrivy = "latest"\nrust = "latest"\nidris2 = "latest"\nzig = "latest"\n' > "$DD/mise.toml"
expect_pass "--detect finds markers below the root, as provision-lib does" \
    mise --root "$DD" --detect

# A Julia package whose Project.toml is not at the root (src/julia/Project.toml,
# depth 3) must be detected by BOTH detectors, with the same answer; one under an
# excluded tree (node_modules) must not be.
JD="$WORK/julia-depth"; mkdir -p "$JD/src/julia" "$JD/build/just"
cp "$REPO_DIR/build/just/provision-lib.sh" "$JD/build/just/"
printf 'name = "Demo"\n' > "$JD/src/julia/Project.toml"
printf '[tools]\njust = "latest"\nshellcheck = "latest"\nyq = "latest"\njulia = "latest"\n' > "$JD/mise.toml"
expect_pass "mise gate (engine) detects julia at src/julia/Project.toml" mise --root "$JD"
rm -rf "$JD/build"
printf '[tools]\njust = "latest"\nshellcheck = "latest"\nyq = "latest"\ntrivy = "latest"\njulia = "latest"\n' > "$JD/mise.toml"
expect_pass "mise gate (--detect mirror) detects julia at src/julia/Project.toml" mise --root "$JD" --detect
# Same julia mise.toml, but the only Project.toml sits under node_modules: julia is
# then declared for no detected language, which is the finding to look for.
JV="$WORK/julia-vendored"; mkdir -p "$JV/node_modules/dep" "$JV/build/just"
cp "$REPO_DIR/build/just/provision-lib.sh" "$JV/build/just/"
printf 'name = "Dep"\n' > "$JV/node_modules/dep/Project.toml"
printf '[tools]\njust = "latest"\nshellcheck = "latest"\nyq = "latest"\ntrivy = "latest"\njulia = "latest"\n' > "$JV/mise.toml"
out_v="$(mise --root "$JV" 2>&1)"
if grep -q 'declared for no detected language: julia' <<<"$out_v"; then
    pass "mise gate (engine) ignores a vendored Project.toml"
else bad "mise gate (engine) ignores a vendored Project.toml"; fi
rm -rf "$JV/build"
out_v="$(mise --root "$JV" --detect 2>&1)"
if grep -q 'declared for no detected language: julia' <<<"$out_v"; then
    pass "mise gate (--detect mirror) ignores a vendored Project.toml"
else bad "mise gate (--detect mirror) ignores a vendored Project.toml"; fi

echo ""
echo "── Mint tokens ────────────────────────────────────────────"

if bash "$REPO_DIR/scripts/is-template-tree.sh" "$REPO_DIR"; then
expect_pass "token gate passes on the template" \
    bash "$REPO_DIR/scripts/check-mint-tokens.sh" --quiet --root "$REPO_DIR"
else
    echo "  SKIP  token gate on the template (not the template tree)"
fi

T="$WORK/tokens"; mkdir -p "$T/scripts" "$T/build/just" "$T/.machine_readable"
cp "$REPO_DIR/build/just/repo-init.just" "$T/build/just/"
: > "$T/.machine_readable/mint-verbatim.txt"
printf '# SPDX-License-Identifier: MPL-2.0\nproject := "{{PROJECT_NAME}}"\n' > "$T/Justfile"
expect_pass "token gate ignores just's own interpolation" \
    bash "$REPO_DIR/scripts/check-mint-tokens.sh" --quiet --root "$T"

printf '# SPDX-License-Identifier: MPL-2.0\nname: {{PROJECT_NAME}}\nport: {{NOT_ANSWERED}}\n' > "$T/settings.yml"
expect_fail "token gate fails on a token with no answer" \
    bash "$REPO_DIR/scripts/check-mint-tokens.sh" --quiet --root "$T"

# A MINTED tree keeps the generator: repo-init.just is carried verbatim into every
# child (.machine_readable/mint-verbatim.txt) and the child's Justfile imports it.
# "Minted" is therefore the absence of archetypes/, not of the recipe — testing
# for the recipe made every child look like the template, and an unfilled
# {{PROJECT_NAME}} they could never answer passed this gate.
M2="$WORK/minted-with-recipe"; mkdir -p "$M2/build/just"
cp "$REPO_DIR/build/just/repo-init.just" "$M2/build/just/"
printf '# SPDX-License-Identifier: MPL-2.0\nname: {{PROJECT_NAME}}\n' > "$M2/README.adoc"
expect_fail "token gate fails on an answerable token in a minted tree that still carries the generator" \
    bash "$REPO_DIR/scripts/check-mint-tokens.sh" --quiet --root "$M2"

echo ""
echo "── Archetype prune ────────────────────────────────────────"

PR="$WORK/prune"; mkdir -p "$PR/arch/build/container" "$PR/tree/build/container"
printf '# SPDX-License-Identifier: MPL-2.0\nbuild/container/\n' > "$PR/arch/prune.txt"
: > "$PR/tree/build/container/Containerfile"
expect_pass "prune script runs" \
    bash "$REPO_DIR/scripts/prune-archetype-modules.sh" "$PR/arch" "$PR/tree"
if [ -e "$PR/tree/build/container" ]; then
    bad "prune left a listed path behind"
else
    pass "prune removed the listed path"
fi

echo ""
echo "── Summary ────────────────────────────────────────────────"
if [ "$FAILED" -eq 0 ]; then
    printf 'mint gates: \033[32m%d/%d controls hold\033[0m\n' "$CHECKS" "$CHECKS"
    exit 0
fi
printf 'mint gates: \033[31m%d of %d controls failed\033[0m\n' "$FAILED" "$CHECKS"
exit 1
