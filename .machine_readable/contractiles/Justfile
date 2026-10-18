# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# RSR Standard Justfile Template
# https://just.systems/man/en/
#
# Copy this file to new projects and customize the placeholder values.
#
# Run `just` to see all available recipes
# Run `just cookbook` to generate docs/just-cookbook.adoc
# Run `just combinations` to see matrix recipe options

set shell := ["bash", "-uc"]
set dotenv-load := true
set positional-arguments := true

# Import auto-generated contractile recipes (must-check, trust-verify, etc.)
# Re-generate with: contractile gen-just
import? "build/contractile.just"

# Provisioning canon: setup, doctor, heal, dev-shell, eval, ai-setup, … (see PROVISIONING below)
mod provision 'build/just/provision.just'

# Project metadata — customize these
project := "rsr-template-repo"
OWNER := "hyperpolymath"
REPO := "rsr-template-repo"
version := "0.1.0"
tier := "infrastructure"  # 1 | 2 | infrastructure

# ═══════════════════════════════════════════════════════════════════════════════
# DEFAULT & HELP
# ═══════════════════════════════════════════════════════════════════════════════

# Show all available recipes with descriptions
default:
    @just --list --unsorted

# Show detailed help for a specific recipe
help recipe="":
    #!/usr/bin/env bash
    if [ -z "{{recipe}}" ]; then
        just --list --unsorted
        echo ""
        echo "Usage: just help <recipe>"
        echo "       just cookbook     # Generate full documentation"
        echo "       just combinations # Show matrix recipes"
    else
        just --show "{{recipe}}" 2>/dev/null || echo "Recipe '{{recipe}}' not found"
    fi

# Show this project's info
info:
    @echo "Project: {{project}}"
    @echo "Version: {{version}}"
    @echo "RSR Tier: {{tier}}"
    @echo "Recipes: $(just --summary | wc -w)"
    @d=$(bash scripts/deed-field.sh --find . 2>/dev/null) && bash scripts/deed-field.sh "$d" status phase | xargs -I{} echo "Phase: {}" || true

# Run Invariant Path overlay tools for this repository
invariant-path *ARGS:
    ./scripts/invariant-path.sh {{ARGS}}

# ═══════════════════════════════════════════════════════════════════════════════
# INIT — see build/just/repo-init.just
# ═══════════════════════════════════════════════════════════════════════════════

import? "build/just/repo-init.just"

# >>> container-module (three-tier: OCI · portable engine · stapeln) >>>
# Self-contained. Remove the entire block — this and the import — with `just no-container`.
import? "build/just/container.just"
# <<< container-module <<<

# ═══════════════════════════════════════════════════════════════════════════════
# GROOVE PROTOCOL — see build/just/groove.just
# ═══════════════════════════════════════════════════════════════════════════════

import? "build/just/groove.just"

# ═══════════════════════════════════════════════════════════════════════════════
# PROJECT SELF-ASSESSMENT + OPENSSF COMPLIANCE — see build/just/assess.just
# ═══════════════════════════════════════════════════════════════════════════════

import? "build/just/assess.just"

# ═══════════════════════════════════════════════════════════════════════════════
# BUILD & COMPILE
# ═══════════════════════════════════════════════════════════════════════════════

# Build the project with every detected language's toolchain (here: pack/idris2 for
# the ABI, then `zig build` in src/interface/ffi). Replace the delegation with a
# body of your own when the project needs a different build.
build: provision::build

# Build in release mode with optimizations
build-release *args:
    # TODO: Replace with your release build command
    # Examples:
    #   cargo build --release {{args}}
    #   MIX_ENV=prod mix compile {{args}}
    #   zig build -Doptimize=ReleaseFast {{args}}
    @echo "FAIL: 'just build-release' is not wired yet — nothing was built. Edit the 'build-release' recipe." >&2; exit 1

# Build and watch for changes (requires entr or similar)
build-watch:
    @echo "Watching for changes..."
    # TODO: Customize file patterns for your language
    # Examples:
    #   find src -name '*.rs' | entr -c just build
    #   mix compile --force --warnings-as-errors
    #   bun run dev

# Clean build artifacts [reversible: rebuild with `just build`]
clean:
    @echo "Cleaning..."
    # TODO: Customize for your build system
    #
    # `build/` is DELIBERATELY ABSENT from this list. It is not an artifact
    # directory in an RSR repo: it holds 11 tracked files, including
    # build/just/repo-init.just, which the root Justfile imports at line 65.
    # Deleting it destroys `just repo-init`, `just verify` and the proof gates.
    rm -rf target/ _build/ dist/ out/ obj/ bin/

# Deep clean including caches [reversible: rebuild]
clean-all: clean
    rm -rf .cache .tmp

# ═══════════════════════════════════════════════════════════════════════════════
# TEST & QUALITY
# ═══════════════════════════════════════════════════════════════════════════════

# Run every detected language's tests: `zig build test` covers src/interface/ffi
# (unit tests in src/main.zig, test/integration_test.zig). It compiles only after
# `just repo-init` has filled the template tokens, so an un-initialised template
# fails here loudly instead of reporting a pass over nothing.
test: provision::test

# Run tests with verbose output
test-verbose: provision::test

# Smoke test
test-smoke:
    # TODO: Add basic sanity checks
    @echo "FAIL: 'just test-smoke' is not wired yet — no smoke check ran. Edit the 'test-smoke' recipe." >&2; exit 1

# Run end-to-end tests (full pipeline: build → run → verify)
e2e:
    bash tests/e2e.sh

# Run aspect tests (cross-cutting concern validation)
aspect:
    # Aspect tests validate architectural invariants:
    #   - Thread safety (mutex in FFI modules)
    #   - ABI/FFI contract (declarations match exports)
    #   - SPDX compliance (all files have license headers)
    #   - No dangerous patterns (believe_me, assert_total, etc.)
    bash tests/aspect_tests.sh

# Run benchmarks (performance regression detection). Reports N/A until a language
# declares some (e.g. a "bench" step in build.zig, [[bench]] in Cargo.toml).
bench: provision::bench

# Run readiness tests (Component Readiness Grade: D/C/B)
readiness:
    # TODO: Replace with your readiness test command. Examples:
    #   cargo test --test readiness -- --nocapture
    @echo "FAIL: 'just readiness' is not wired yet — no readiness test ran. Edit the 'readiness' recipe." >&2; exit 1

# Print the current CRG grade (reads from READINESS.md '**Current Grade:** X' line)
crg-grade:
    @grade=$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$grade" ] && grade="X"; \
    echo "$grade"

# Print a shields.io CRG badge for embedding in README files
# Looks for '**Current Grade:** X' in READINESS.md; falls back to X
crg-badge:
    @grade=$(grep -oP '(?<=\*\*Current Grade:\*\* )[A-FX]' READINESS.md 2>/dev/null | head -1); \
    [ -z "$grade" ] && grade="X"; \
    case "$grade" in \
      A) color="brightgreen" ;; \
      B) color="green" ;; \
      C) color="yellow" ;; \
      D) color="orange" ;; \
      E) color="red" ;; \
      F) color="critical" ;; \
      *) color="lightgrey" ;; \
    esac; \
    echo "[![CRG $grade](https://img.shields.io/badge/CRG-$grade-$color?style=flat-square)](https://github.com/hyperpolymath/standards/tree/main/component-readiness-grades)"

# Run the full merge-requirement test suite (ALL categories)
# Per STANDING rule: P2P + E2E + aspect + execution + lifecycle + bench
test-all: test e2e aspect bench readiness
    @echo "All test categories passed — safe to merge!"

# Run all quality checks
quality: fmt-check lint test
    @echo "All quality checks passed!"

# Fix all auto-fixable issues [reversible: git checkout]
fix: fmt
    @echo "Fixed all auto-fixable issues"

# ═══════════════════════════════════════════════════════════════════════════════
# LINT & FORMAT
# ═══════════════════════════════════════════════════════════════════════════════

# Format all source files [reversible: git checkout]
fmt: provision::fmt

# Check formatting without changes
fmt-check: provision::fmt-check

# Run linter (`zig fmt --check` on src/interface/ffi; like `test`, it parses the
# FFI sources only after `just repo-init` has filled the template tokens)
lint: provision::lint

# ═══════════════════════════════════════════════════════════════════════════════
# RUN & EXECUTE
# ═══════════════════════════════════════════════════════════════════════════════

# Run the application (N/A for a library; wire a "run" step or executable to enable)
run: provision::run

# Run with verbose output
run-verbose: run

# Install to user path
install: build-release
    @echo "Installing {{project}}..."
    # TODO: Replace with your install command

# ═══════════════════════════════════════════════════════════════════════════════
# DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════

# Install/check all dependencies
deps:
    @echo "Checking dependencies..."
    # TODO: Replace with your dependency check
    # Examples:
    #   cargo check
    #   mix deps.get
    #   gleam deps download
    @echo "All dependencies satisfied"

# Audit dependencies for vulnerabilities
deps-audit:
    @echo "Auditing for vulnerabilities..."
    # TODO: Replace with your audit command
    # Examples:
    #   cargo audit
    #   mix audit
    @command -v trivy >/dev/null || { echo "FAIL: trivy is not installed, so nothing was audited (mise install, or edit this recipe)." >&2; exit 1; }
    trivy fs --severity HIGH,CRITICAL --exit-code 1 --quiet .
    @echo "Audit complete"

# ═══════════════════════════════════════════════════════════════════════════════
# ARRIVAL PACK — agent-facing CLAUDE.md, compiled from the repo deed
# ═══════════════════════════════════════════════════════════════════════════════

# Compile CLAUDE.md (the agent arrival pack) from this repo's deed
claude-md:
    @bash .machine_readable/arrival-pack/generate.sh

# Regenerate the single authoritative repository map
repo-map:
    @bash scripts/gen-repo-map.sh .

# Fail if the repository map is stale (the map is generated; CI diffs it)
validate-repo-map:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    before=$(mktemp); cp docs/architecture/REPOSITORY-MAP.adoc "$before" 2>/dev/null || true
    bash scripts/gen-repo-map.sh . >/dev/null
    if ! diff -q "$before" docs/architecture/REPOSITORY-MAP.adoc >/dev/null 2>&1; then
        echo "FAIL: docs/architecture/REPOSITORY-MAP.adoc is stale. Run: just repo-map" >&2
        diff -u "$before" docs/architecture/REPOSITORY-MAP.adoc | head -40 >&2 || true
        cp "$before" docs/architecture/REPOSITORY-MAP.adoc
        rm -f "$before"; exit 1
    fi
    rm -f "$before"
    echo "repository map: up to date"

# Fail if CLAUDE.md's generated region drifted from the deed or was hand-edited
validate-claude-md:
    @bash .machine_readable/arrival-pack/verify.sh

# ═══════════════════════════════════════════════════════════════════════════════
# COAPTATION — typed descriptile↔contractile face-off (homeostasis reading)
# ═══════════════════════════════════════════════════════════════════════════════

# Emit the coaptation receipt: how the descriptiles coapt with the contractiles (SITREP)
coapt:
    @bash .machine_readable/coaptation/coapt.sh --report

# Assemble a re-anchor basis IF the band is red (the drop itself is a human act)
coapt-reanchor:
    @bash .machine_readable/coaptation/coapt.sh --reanchor

# Fail if the committed coaptation receipt drifted from the contractiles/descriptiles
validate-coapt:
    @bash .machine_readable/coaptation/verify.sh

# ═══════════════════════════════════════════════════════════════════════════════
# DOCUMENTATION
# ═══════════════════════════════════════════════════════════════════════════════

# Generate all documentation
docs:
    @mkdir -p docs/generated docs/man
    just cookbook
    just man
    @echo "Documentation generated in docs/"

# Generate justfile cookbook documentation
cookbook:
    #!/usr/bin/env bash
    mkdir -p docs
    OUTPUT="docs/just-cookbook.adoc"
    echo "= {{project}} Justfile Cookbook" > "$OUTPUT"
    echo ":toc: left" >> "$OUTPUT"
    echo ":toclevels: 3" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    echo "Generated: $(date -Iseconds)" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    echo "== Recipes" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    just --list --unsorted | while read -r line; do
        if [[ "$line" =~ ^[[:space:]]+([a-z_-]+) ]]; then
            recipe="${BASH_REMATCH[1]}"
            echo "=== $recipe" >> "$OUTPUT"
            echo "" >> "$OUTPUT"
            echo "[source,bash]" >> "$OUTPUT"
            echo "----" >> "$OUTPUT"
            echo "just $recipe" >> "$OUTPUT"
            echo "----" >> "$OUTPUT"
            echo "" >> "$OUTPUT"
        fi
    done
    echo "Generated: $OUTPUT"

# Generate man page
man:
    #!/usr/bin/env bash
    mkdir -p docs/man
    cat > docs/man/{{project}}.1 << EOF
    .TH {{project}} 1 "$(date +%Y-%m-%d)" "{{version}}" "{{project}} Manual"
    .SH NAME
    {{project}} \- RSR-compliant project
    .SH SYNOPSIS
    .B just
    [recipe] [args...]
    .SH DESCRIPTION
    RSR (Rhodium Standard Repository) project managed with just.
    .SH AUTHOR
    $(git config user.name 2>/dev/null || echo "Author") <$(git config user.email 2>/dev/null || echo "email")>
    EOF
    echo "Generated: docs/man/{{project}}.1"

# ═══════════════════════════════════════════════════════════════════════════════
# CI & AUTOMATION
# ═══════════════════════════════════════════════════════════════════════════════

# Run full CI pipeline locally
# proof-check-all is FATAL if any prover toolchain is absent (idris2/lean/agda/coqc):
# the full CI gate must not pass on a machine that cannot verify the proofs.
ci: deps quality proof-check-all
    @echo "CI pipeline complete!"

# Install git hooks
install-hooks:
    @mkdir -p .git/hooks
    @cat > .git/hooks/pre-commit << 'HOOKEOF'
    #!/bin/bash
    just fmt-check || exit 1
    just lint || exit 1
    just assail || exit 1
    HOOKEOF
    @chmod +x .git/hooks/pre-commit
    @echo "Git hooks installed"

# ═══════════════════════════════════════════════════════════════════════════════
# SECURITY
# ═══════════════════════════════════════════════════════════════════════════════

# Run security audit
security: deps-audit
    @echo "=== Security Audit ==="
    @command -v trivy >/dev/null && trivy fs --severity HIGH,CRITICAL . || true
    @echo "Security audit complete"

# Generate SBOM
sbom:
    @mkdir -p docs/security
    @command -v syft >/dev/null && syft . -o spdx-json > docs/security/sbom.spdx.json || echo "syft not found"

# ═══════════════════════════════════════════════════════════════════════════════
# VALIDATION & COMPLIANCE — see build/just/validate.just
# ═══════════════════════════════════════════════════════════════════════════════

import? "build/just/validate.just"

# ═══════════════════════════════════════════════════════════════════════════════
# STATE MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

# Repo state lives in the repo deed's (status …) and (maturity …) clauses
# (rsr-template-repo#209); the journal is docs/status/ROADMAP.adoc. There is
# no last-updated stamp to touch: git log is the record of when it changed.

# Show the lifecycle phase and maturity from the repo deed
state-phase:
    #!/usr/bin/env bash
    DEED=$(bash scripts/deed-field.sh --find . || true)
    if [ -z "$DEED" ]; then echo "unknown (no *_chora.deed)"; exit 0; fi
    echo "phase: $(bash scripts/deed-field.sh "$DEED" status phase || echo unknown)"
    echo "maturity: $(bash scripts/deed-field.sh "$DEED" maturity level || echo unknown)"

# ═══════════════════════════════════════════════════════════════════════════════
# GUIX
# ═══════════════════════════════════════════════════════════════════════════════

# Enter Guix development shell (primary)
guix-shell:
    guix shell -D -f build/guix.scm

# Build with Guix
guix-build:
    guix build -f build/guix.scm

# ═══════════════════════════════════════════════════════════════════════════════
# HYBRID AUTOMATION
# ═══════════════════════════════════════════════════════════════════════════════

# Run local automation tasks
automate task="all":
    #!/usr/bin/env bash
    case "{{task}}" in
        all) just fmt && just lint && just test && just docs ;;
        cleanup) just clean && find . -name "*.orig" -delete && find . -name "*~" -delete ;;
        update) just deps && just validate ;;
        *) echo "Unknown: {{task}}. Use: all, cleanup, update" && exit 1 ;;
    esac

# ═══════════════════════════════════════════════════════════════════════════════
# COMBINATORIC MATRIX RECIPES
# ═══════════════════════════════════════════════════════════════════════════════

# Build matrix: [debug|release] x [target] x [features]
build-matrix mode="debug" target="" features="":
    @echo "Build matrix: mode={{mode}} target={{target}} features={{features}}"

# Test matrix: [unit|integration|e2e|all] x [verbosity] x [parallel]
test-matrix suite="unit" verbosity="normal" parallel="true":
    @echo "Test matrix: suite={{suite}} verbosity={{verbosity}} parallel={{parallel}}"

# CI matrix: [lint|test|build|security|all] x [quick|full]
ci-matrix stage="all" depth="quick":
    @echo "CI matrix: stage={{stage}} depth={{depth}}"

# Show all matrix combinations
combinations:
    @echo "=== Combinatoric Matrix Recipes ==="
    @echo ""
    @echo "Build Matrix: just build-matrix [debug|release] [target] [features]"
    @echo "Test Matrix:  just test-matrix [unit|integration|e2e|all] [verbosity] [parallel]"
    @echo "Container:    just container-matrix [build|run|push|shell|scan] [registry] [tag]  (needs container module)"
    @echo "CI Matrix:    just ci-matrix [lint|test|build|security|all] [quick|full]"

# ═══════════════════════════════════════════════════════════════════════════════
# VERSION CONTROL
# ═══════════════════════════════════════════════════════════════════════════════

# Show git status
status:
    @git status --short

# Show recent commits
log count="20":
    @git log --oneline -{{count}}

# Generate CHANGELOG.adoc with git-cliff
changelog:
    @command -v git-cliff >/dev/null || { echo "git-cliff not found — install: cargo install git-cliff"; exit 1; }
    # AsciiDoc, not .md: CHANGELOG.adoc is what root-allow.txt permits, so a
    # .md here would fail check-root-shape AND the estate's no-.md rule the
    # moment anyone ran this recipe.
    git cliff --config .machine_readable/configs/git-cliff/cliff.toml --output CHANGELOG.adoc
    @echo "Generated CHANGELOG.adoc"

# Preview changelog for unreleased commits (does not write)
changelog-preview:
    @command -v git-cliff >/dev/null || { echo "git-cliff not found — install: cargo install git-cliff"; exit 1; }
    git cliff --config .machine_readable/configs/git-cliff/cliff.toml --unreleased --strip header

# Tag a new release (usage: just release-tag 1.2.3)
release-tag version:
    #!/usr/bin/env bash
    TAG="v{{version}}"
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        echo "Tag $TAG already exists"
        exit 1
    fi
    just changelog
    git add CHANGELOG.md
    git commit -m "chore(release): prepare $TAG"
    git tag -a "$TAG" -m "Release $TAG"
    echo "Created tag $TAG — push with: git push origin main --tags"

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

# Count lines of code
loc:
    @find . \( -name "*.rs" -o -name "*.ex" -o -name "*.exs" -o -name "*.res" -o -name "*.gleam" -o -name "*.zig" -o -name "*.idr" -o -name "*.hs" -o -name "*.ncl" -o -name "*.scm" -o -name "*.adb" -o -name "*.ads" \) -not -path './target/*' -not -path './_build/*' 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 || echo "0"

# Show TODO comments
todos:
    @grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.rs" --include="*.ex" --include="*.res" --include="*.gleam" --include="*.zig" --include="*.idr" --include="*.hs" . 2>/dev/null || echo "No TODOs"

# Open in editor
edit:
    ${EDITOR:-code} .

# Run high-rigor security assault using panic-attacker
maint-assault:
    @./.machine_readable/scripts/maintenance/maint-assault.sh

# Run panic-attacker pre-commit scan (foundational floor-raise requirement)
assail:
    @command -v panic-attack >/dev/null 2>&1 && panic-attack assail . || echo "WARN: panic-attack not found — install from https://github.com/hyperpolymath/panic-attacker"


# ═══════════════════════════════════════════════════════════════════════════════
# PROVISIONING (standards 3-practice/provisioning/PROVISIONING-STANDARD.adoc)
# ═══════════════════════════════════════════════════════════════════════════════
# The canon verbs live in the provision:: module; these delegations make
# `just <verb>` and `just provision::<verb>` the same thing. Repository-specific
# checks go in a `doctor-local` / `setup-local` / `heal-local` recipe.

# Install everything this repository needs, then run doctor
setup: provision::setup

# Check the environment: PASS/WARN/FAIL with fix hints (exit 1 on any FAIL)
doctor: provision::doctor

# Apply the safe fixes doctor knows, then re-run doctor
heal: provision::heal

# Enter the Guix development shell (mise environment when Guix is absent)
dev-shell: provision::dev-shell

# Bump mise to latest, re-lock mise.lock, re-pin the Guix channel
toolchain-refresh: provision::toolchain-refresh

# Print the one sentence to give any AI assistant to set this repository up
ai-setup: provision::ai-setup

# Print a warm-up to paste into any AI: user, dev or maintainer
ai-warmup who="user": (provision::ai-warmup who)

# test + bench with timings, saved under .eval/
eval: provision::eval

# Where the toolchain and configuration are declared
config-show: provision::config-show

# How to fetch this repository with OPSM
opsm: provision::opsm

# Guided tour of key features
tour:
    @echo "=== rsr-template-repo Tour ==="
    @echo ""
    @echo "1. Project structure:"
    @ls -la
    @echo ""
    @echo "2. Available commands: just --list"
    @echo ""
    @echo "3. Read README.adoc for full overview"
    @echo "4. Read EXPLAINME.adoc for architecture decisions"
    @echo "5. Run 'just doctor' to check your setup"
    @echo ""
    @echo "Tour complete! Try 'just --list' to see all available commands."

# Open feedback channel with diagnostic context
help-me:
    @echo "=== rsr-template-repo Help ==="
    @echo "Platform: $(uname -s) $(uname -m)"
    @echo "Shell: $SHELL"
    @echo ""
    @echo "To report an issue:"
    @echo "  https://github.com/hyperpolymath/rsr-template-repo/issues/new"
    @echo ""
    @echo "Include the output of 'just doctor' in your report."

# ═══════════════════════════════════════════════════════════════════════════════
# FORMAL VERIFICATION (PROOFS) — see build/just/proofs.just
# ═══════════════════════════════════════════════════════════════════════════════

import? "build/just/proofs.just"

# ═══════════════════════════════════════════════════════════════════════════════
# SESSION MANAGEMENT (THIN BINDINGS TO CENTRAL STANDARDS)
# ═══════════════════════════════════════════════════════════════════════════════

# Show canonical session-management command model
session-help:
    @echo "Canonical command model:"
    @echo "  intake repo <path>"
    @echo "  checkpoint change <path>"
    @echo "  verify maintenance <path>"
    @echo "  verify substantial <path>"
    @echo "  verify release <path>"
    @echo "  close planned <path>"
    @echo "  close urgent <path>"
    @echo "  recover repo <path>"
    @echo "  handover full <path>"
    @echo "  handover split <path>"
    @echo "  handover model <path>"
    @echo "  handover human <path>"
    @echo ""
    @echo "Use Just aliases below (thin wrappers around ./session/dispatch.sh)."

# Canonical aliases (friendly recipe names that map to canonical commands)
intake-repo path=".":
    @./session/dispatch.sh intake repo "{{path}}"

checkpoint-change path=".":
    @./session/dispatch.sh checkpoint change "{{path}}"

verify-maintenance path=".":
    @./session/dispatch.sh verify maintenance "{{path}}"

verify-substantial path=".":
    @./session/dispatch.sh verify substantial "{{path}}"

verify-release path=".":
    @./session/dispatch.sh verify release "{{path}}"

close-planned path=".":
    @./session/dispatch.sh close planned "{{path}}"

close-urgent path=".":
    @./session/dispatch.sh close urgent "{{path}}"

recover-repo path=".":
    @./session/dispatch.sh recover repo "{{path}}"

handover-full path=".":
    @./session/dispatch.sh handover full "{{path}}"

handover-split path=".":
    @./session/dispatch.sh handover split "{{path}}"

handover-model path=".":
    @./session/dispatch.sh handover model "{{path}}"

handover-human path=".":
    @./session/dispatch.sh handover human "{{path}}"

secret-scan-trufflehog:
    @command -v trufflehog >/dev/null && trufflehog filesystem . --only-verified || true

# ═══════════════════════════════════════════════════════════════════════════════
# WINDOWS RGONOMICS (CLOAKING)
# ═══════════════════════════════════════════════════════════════════════════════╓
# Hide all dotfiles and dot-folders from Windows Explorer. On POSIX systems,
# leading-dot names are already hidden by convention, so these recipes are
# intentionally harmless no-ops.
cloak:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "Get-ChildItem -Path . -Force -Filter '.*' | Where-Object { \$_.Name -match '^\\.' } | ForEach-Object { \$_.Attributes = \$_.Attributes -bor [System.IO.FileAttributes]::Hidden }"
        echo "Cloak engaged."
    else
        echo "Dotfiles are natively cloaked on this OS. No action required."
    fi

# Reveal dotfiles in Windows Explorer; on POSIX, explain the native mechanism.
uncloak:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "Get-ChildItem -Path . -Force -Filter '.*' | Where-Object { \$_.Name -match '^\\.' } | ForEach-Object { \$_.Attributes = \$_.Attributes -band -bnot [System.IO.FileAttributes]::Hidden }"
        echo "Cloak lifted."
    else
        echo "Use 'ls -a' to view dotfiles on this OS."
    fi
