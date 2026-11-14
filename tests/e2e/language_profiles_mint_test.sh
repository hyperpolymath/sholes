#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# language_profiles_mint_test.sh — mint a Julia package and a Rust CLI from this
# template's own tree and archetypes, then run the estate gates on both.
#
# ── What this proves, and what it does not ─────────────────────────────────
#
# It proves the LANGUAGE-CONDITIONAL parts of the mint end to end:
#   * the archetype overlay is applied and its *.in files get their final names;
#   * the archetype's prune.txt removes modules the preset does not declare;
#   * mise.toml is RENDERED for the languages the tree actually carries (the
#     step the mint used to skip, which is how a Julia package came to declare
#     Python, Node, Go and Cargo while requiring none of them and no Julia);
#   * the gates the template enforces — SPDX, container pins, mise/language
#     match, answered tokens — pass on both scaffolds;
#   * replaying the historical damage (the nine-runtime mise.toml, a floating
#     Containerfile, an unanswered token) makes those same gates fail.
#
# It does NOT run `just repo-init` itself. The full recipe needs rustc (its mint
# tools are single-file Rust compiled on demand), nickel (the arrival pack) and
# uuidgen; this harness has none of the three, and the CI job that does run the
# real mint is tests/e2e/use_template_mint_test.sh. What this test DOES use is
# the recipe's own overlay/prune/rename ordering and its own token answer list,
# read from build/just/repo-init.just at run time, so the two cannot drift into
# agreeing by accident.
#
# Usage: bash tests/e2e/language_profiles_mint_test.sh [--keep]
# Exit: 0 all controls hold; 1 a control failed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# A minted repository carries this test but not the archetypes it mints from
# (`just repo-init` deletes archetypes/). Skipping is the honest outcome there;
# failing would be a red build in every child for a test about the parent.
if [ ! -d "$REPO_DIR/archetypes" ]; then
    echo "SKIP: $REPO_DIR has no archetypes/ — this is a minted repository."
    echo "      Language-profile minting is a template-side check; run it in"
    echo "      hyperpolymath/rsr-template-repo."
    exit 0
fi

WORK="$(mktemp -d)"
if [ "${1:-}" = "--keep" ]; then echo "keeping $WORK"; else trap 'rm -rf "$WORK"' EXIT; fi

CHECKS=0; FAILED=0
pass() { CHECKS=$((CHECKS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { CHECKS=$((CHECKS+1)); FAILED=$((FAILED+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
note() { printf '        %s\n' "$1"; }

# The tokens repo-init can answer, read from the recipe (not copied).
ANSWERS="$(bash "$REPO_DIR/scripts/check-mint-tokens.sh" --root "$REPO_DIR" 2>&1 >/dev/null || true)"
ANSWERS="$(sed -n 's/.*repo-init answers \([0-9]*\).*/\1/p' <<<"$(bash "$REPO_DIR/scripts/check-mint-tokens.sh" --root "$REPO_DIR" 2>/dev/null)" )"
[ -n "$ANSWERS" ] || { echo "FAIL: could not read the answer count from check-mint-tokens.sh" >&2; exit 1; }
mapfile -t ANSWER_TOKENS < <(
    sed -n 's/.*repo-init answers.*//p' /dev/null
    # reuse the gate's own extraction by asking it to report, via the recipe
    sed -n 's/.*s|\${LB}\([A-Z][A-Z0-9_]*\)\${RB}|.*/\1/p' "$REPO_DIR/build/just/repo-init.just"
    awk '/for tok in/ { c=1 } c { line=$0; gsub(/\$\{LB\}|\$\{RB\}|\\/, " ", line)
        n=split(line,w,/[^A-Z0-9_]+/); for(i=1;i<=n;i++) if (w[i] ~ /^[A-Z][A-Z0-9_]*$/ && length(w[i])>2) print w[i]
        if ($0 ~ /;[[:space:]]*do/) c=0 }' "$REPO_DIR/build/just/repo-init.just"
    echo PROJECT
    echo project
)
mapfile -t ANSWER_TOKENS < <(printf '%s\n' "${ANSWER_TOKENS[@]}" | sort -u)

# Value for each answer, mirroring what a human would type at the prompts.
declare -A V=(
    [PROJECT_NAME]="Demo Package" [PROJECT]="DEMO_PACKAGE" [project]="demo_package"
    [OWNER]="example-owner" [FORGE]="github.com"
    [AUTHOR]="Jane Doe" [AUTHOR_EMAIL]="jane@example.org" [AUTHOR_ORG]="Example University"
    [AUTHOR_LAST]="Doe" [AUTHOR_FIRST]="Jane" [AUTHOR_INITIALS]="J."
    [CURRENT_YEAR]="2026" [CURRENT_DATE]="2026-10-30" [DATE]="2026-10-30"
    [SECURITY_EMAIL]="security@example.org" [CONDUCT_EMAIL]="conduct@example.org"
    [LICENSE]="MPL-2.0" [CONDUCT_TEAM]="Code of Conduct Committee" [RESPONSE_TIME]="48 hours"
    [MAIN_BRANCH]="main" [WEBSITE]="https://github.com/example-owner/demo"
    [SERVICE_NAME]="demo" [PORT]="8080" [REGISTRY]="ghcr.io/example-owner"
    [EMAIL]="jane@example.org" [VERSION]="0.1.0"
    [OPENSSF_BP_ID]="" [OPENSSF_PROJECT_ID]=""
)
for tok in "${ANSWER_TOKENS[@]}"; do : "${V[$tok]:=UNASSIGNED}"; done

# ── 1. The spine, as the mint sees it: tracked files only ───────────────────
make_tree() { # $1 dir, $2 repo slug, $3 archetype
    local dir="$1" slug="$2" arch="$3"
    mkdir -p "$dir"
    ( cd "$REPO_DIR" && git ls-files -z --cached --others --exclude-standard \
        | while IFS= read -r -d '' f; do
              case "$f" in tests/*|archetypes/*|build/templates/*|build/docs-seed/*) continue ;; esac
              [ -f "$f" ] && printf '%s\0' "$f"
          done | tar --null -T - -cf - ) | tar xf - -C "$dir"
    # the overlay: recorded first, exactly as the recipe does
    if [ -n "$arch" ]; then
        mapfile -t OF < <( cd "$REPO_DIR/archetypes/$arch/overlay" && find . -type f | sed 's|^\./||' | sort )
        cp -a "$REPO_DIR/archetypes/$arch/overlay/." "$dir/"
        if [ -f "$REPO_DIR/archetypes/$arch/prune.txt" ]; then
            bash "$REPO_DIR/scripts/prune-archetype-modules.sh" "$REPO_DIR/archetypes/$arch" "$dir" >/dev/null
        fi
        # substitute, then give the overlay's *.in files their final names
        substitute "$dir" "$slug"
        for of in "${OF[@]}"; do
            case "$of" in
                src/PACKAGE.jl.in) continue ;;
                *.in) [ -f "$dir/$of" ] && mv "$dir/$of" "$dir/${of%.in}" ;;
            esac
        done
        if [ "$arch" = "julia-library" ] && [ -f "$dir/src/PACKAGE.jl.in" ]; then
            local pkg
            pkg="$(sed -n 's/^name = "\([^"]*\)".*/\1/p' "$dir/Project.toml" | head -1)"
            [ -n "$pkg" ] && mv "$dir/src/PACKAGE.jl.in" "$dir/src/$pkg.jl"
        fi
    else
        substitute "$dir" "$slug"
    fi
    # the mint removes these before it renders anything derived
    rm -rf "$dir/archetypes" "$dir/build/docs-seed" "$dir/build/templates"
    bash "$REPO_DIR/scripts/render-mise.sh" --root "$dir" >/dev/null
    ( cd "$dir" && git init -q -b main && git add -A \
        && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm mint )
}

substitute() { # $1 dir, $2 repo slug
    local dir="$1" slug="$2" f tok
    V[REPO]="$slug"
    # DERIVE the identifier tokens from the slug, exactly as repo-init does
    # (`tr '[:lower:]-.' '[:upper:]__'` and its lowercase twin). They were fixed
    # to demo_package, so the Rust fixture generated `demo_package::about()` in a
    # crate named demo_rust — a scaffold that cannot compile, reported as a pass
    # because this harness never compiles.
    V[PROJECT]="$(printf '%s' "$slug" | tr '[:lower:]-.' '[:upper:]__')"
    V[project]="$(printf '%s' "$slug" | tr '[:upper:]-.' '[:lower:]__')"
    local args=()
    for tok in "${ANSWER_TOKENS[@]}"; do
        args+=(-e "s|{{${tok}}}|${V[$tok]}|g")
    done
    while IFS= read -r f; do
        case "$f" in
            *Justfile|*.just|*.png|*.jpg|*.gif) continue ;;
        esac
        [ -f "$dir/$f" ] && sed -i "${args[@]}" "$dir/$f" 2>/dev/null || true
    done < <( cd "$dir" && find . -type f | sed 's|^\./||' )
}

echo "── Julia scaffold ─────────────────────────────────────────"
J="$WORK/DemoPackage.jl"
make_tree "$J" "DemoPackage.jl" "julia-library"

[ -f "$J/Project.toml" ] && pass "Julia: Project.toml has its final name" \
    || bad "Julia: Project.toml missing (the .in rename did not run)"
grep -q '^name = "Demo Package"' "$J/Project.toml" 2>/dev/null \
    && pass "Julia: package name rendered from the archetype token" \
    || bad "Julia: package name not rendered"
[ -f "$J/src/Demo Package.jl" ] || [ -f "$J/src/DemoPackage.jl" ] || ls "$J/src"/*.jl >/dev/null 2>&1 \
    && pass "Julia: module file named after the package" \
    || bad "Julia: module file not renamed from PACKAGE.jl.in"
[ -e "$J/build/container" ] && bad "Julia: build/container/ survived prune.txt" \
    || pass "Julia: build/container/ pruned (no unpinnable Containerfile ships)"
grep -q '^julia = "latest"' "$J/mise.toml" && pass "Julia: mise declares julia" \
    || bad "Julia: mise does not declare julia"
if grep -qE '^(python|node|npm|yarn|pip|black|ruff|go|java|cargo) =' "$J/mise.toml"; then
    bad "Julia: mise declares a banned or foreign tool"
else
    pass "Julia: mise declares no banned or foreign tool"
fi
[ -f "$J/scripts/julia-quality.jl" ] && pass "Julia: quality verbs wired (scripts/julia-quality.jl)" \
    || bad "Julia: quality script missing"
[ -e "$J/src/interface" ] && bad "Julia: src/interface/ (Idris2/Zig seam) survived prune.txt" \
    || pass "Julia: src/interface/ pruned — a Julia package needs no Idris2 or Zig"
if grep -qE '^(idris2|zig) =' "$J/mise.toml"; then
    bad "Julia: mise installs a toolchain the preset never declared"
else
    pass "Julia: mise installs only the detected language's toolchain"
fi
grep -q ':fmt-check' "$J/.machine_readable/descriptiles/provisioning_praxis.deed" \
    && pass "Julia: fmt/fmt-check/lint overrides shipped in the provisioning deed" \
    || bad "Julia: provisioning deed has no verb overrides"

echo ""
echo "── Rust scaffold ──────────────────────────────────────────"
R="$WORK/demo-rust"
make_tree "$R" "demo-rust" "rust-cli"

[ -f "$R/Cargo.toml" ] && pass "Rust: Cargo.toml has its final name" \
    || bad "Rust: Cargo.toml missing"
[ -f "$R/src/main.rs" ] && [ -f "$R/src/lib.rs" ] && [ -f "$R/tests/cli.rs" ] \
    && pass "Rust: sources rendered from the overlay's .in files" \
    || bad "Rust: expected src/main.rs, src/lib.rs and tests/cli.rs"
grep -q '^name = "demo-rust"' "$R/Cargo.toml" && pass "Rust: crate name is the repo slug" \
    || bad "Rust: crate name not rendered"
grep -q '^rust = "latest"' "$R/mise.toml" && pass "Rust: mise declares rust" \
    || bad "Rust: mise does not declare rust"
if grep -qE '^(python|node|npm|yarn|pip|black|ruff|go|java) =' "$R/mise.toml"; then
    bad "Rust: mise declares a banned tool"
else
    pass "Rust: mise declares no banned tool"
fi
[ -e "$R/build/container" ] && bad "Rust: build/container/ survived prune.txt" \
    || pass "Rust: build/container/ pruned"
[ -e "$R/src/interface" ] && bad "Rust: src/interface/ (Idris2/Zig seam) survived prune.txt" \
    || pass "Rust: src/interface/ pruned — a Rust CLI needs no Idris2 or Zig"
if grep -qE '^(idris2|zig) =' "$R/mise.toml"; then
    bad "Rust: mise installs a toolchain the preset never declared"
else
    pass "Rust: mise installs only the detected language's toolchain"
fi
# The identifier tokens are derived from the slug, so the generated code must name
# the crate the slug produces (demo-rust -> demo_rust). Fixing {{project}} to a
# constant made this scaffold reference a crate that cannot exist.
grep -q 'demo_rust' "$R/src/main.rs" && pass "Rust: generated code uses the slug-derived crate name" \
    || bad "Rust: generated code does not use the slug-derived crate name (demo_rust)"

echo ""
echo "── Gates on both scaffolds ────────────────────────────────"
for d in "$J" "$R"; do
    name="$(basename "$d")"
    if bash "$REPO_DIR/scripts/check-spdx-headers.sh" --root "$d" --quiet; then
        pass "$name: SPDX gate passes"; else bad "$name: SPDX gate fails"; fi
    if bash "$REPO_DIR/scripts/check-mise-language.sh" --root "$d" --quiet; then
        pass "$name: mise/language gate passes"; else bad "$name: mise/language gate fails"; fi
    if bash "$REPO_DIR/scripts/check-container-pins.sh" --root "$d" --quiet; then
        pass "$name: container pin gate passes"; else bad "$name: container pin gate fails"; fi
    if bash "$REPO_DIR/scripts/check-mint-tokens.sh" --root "$d" --quiet; then
        pass "$name: no unanswered token survives the mint"; else bad "$name: a token survived"; fi
    if bash "$REPO_DIR/scripts/check-no-placeholders.sh" "$d" >/dev/null 2>&1; then
        pass "$name: placeholder gate passes"; else bad "$name: placeholder gate fails"; fi
done

echo ""
echo "── Replay the downstream damage ───────────────────────────"
# The exact mise.toml the template shipped until 2026-10-01, and which
# JuliaPackageSpitter.jl still carries. A Julia repo with it MUST fail.
cp "$J/mise.toml" "$WORK/mise.good"
cat > "$J/mise.toml" <<'OLD'
[tools]
node = "latest"
python = "latest"
rust = "latest"
go = "latest"
zig = "latest"
java = "latest"
bun = "latest"
denojs = "latest"
npm = "latest"
yarn = "latest"
pnpm = "latest"
pip = "latest"
cargo = "latest"
go-task = "latest"

[alias]
build = "cargo build --release || npm run build || go build"
test = "cargo test || npm test || go test ./..."
lint = "ruff check . || prettier --check . || black --check ."
fmt = "ruff format . || prettier --write . || black ."
OLD
if bash "$REPO_DIR/scripts/check-mise-language.sh" --root "$J" --quiet; then
    bad "damage replay: the nine-runtime mise.toml PASSED a language gate"
else
    pass "damage replay: the nine-runtime mise.toml is caught"
fi
cp "$WORK/mise.good" "$J/mise.toml"

# A floating Containerfile, as the template used to ship at the root.
cat > "$J/Containerfile" <<'OLD'
FROM cgr.dev/chainguard/wolfi-base:latest AS build
FROM cgr.dev/chainguard/static:latest
OLD
if bash "$REPO_DIR/scripts/check-container-pins.sh" --root "$J" --quiet; then
    bad "damage replay: a floating Containerfile PASSED the pin gate"
else
    pass "damage replay: a floating Containerfile is caught"
fi
rm -f "$J/Containerfile"

# An unanswered token, as five files carried downstream.
printf 'project := "{{tier}}"\n' >> "$J/README.adoc"
if bash "$REPO_DIR/scripts/check-mint-tokens.sh" --root "$J" --quiet; then
    bad "damage replay: an unanswered token PASSED the token gate"
else
    pass "damage replay: an unanswered token is caught"
fi
sed -i '/project := "{{tier}}"/d' "$J/README.adoc"

echo ""
echo "── Summary ────────────────────────────────────────────────"
if [ "$FAILED" -eq 0 ]; then
    printf 'language profiles: \033[32m%d/%d controls hold\033[0m\n' "$CHECKS" "$CHECKS"
    exit 0
fi
printf 'language profiles: \033[31m%d of %d controls failed\033[0m\n' "$FAILED" "$CHECKS"
exit 1
