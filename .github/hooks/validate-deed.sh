#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# validate-deed.sh — pre-push deed check, through the canonical linter.
#
# One validator per family (hyperpolymath/standards,
# docs/CONTRACTILE-DESCRIPTILE-VALIDATION.adoc): the grep checks that used to
# live here were a second validator. This runs 1-formats/deed/tools/deed_lint.js
# (Bun) from a standards checkout over the tracked .deed files, as the
# deed-conformance lane does in CI (.github/workflows/dogfood-gate.yml). The
# lane is the gate; this is the early warning.
#
# A2ML is retired estate-wide (D99, D312); its facts belong in the repo deed.
# Without a ledger, any tracked A2ML file is an error on sight. A repository
# that still carries legacy A2ML lists each file, by exact path, in the
# shrink-only ledger .machine_readable/a2ml-legacy-allow.txt (owner decision
# 2026-11-04), and the A2ML check is then the canonical gate,
# scripts/check-a2ml-archived.sh from the same standards checkout: a file
# outside the ledger and outside 9-archive/ fails, and so does an entry whose
# file is gone. With A2ML_BASE set to a ref (CI sets the PR base), an entry
# the base ledger did not list also fails, so the ledger can only shrink.
#
# Environment variables:
#   INPUT_PATH     — Repository to check (default: .)
#   STANDARDS_DIR  — A hyperpolymath/standards checkout
#                    (default: ../standards beside the repository)
#   A2ML_BASE      — Ref whose ledger this one may not grow beyond (optional)
#
# Exit codes:
#   0 — Every tracked deed lints and the A2ML check passes, or no linter is
#       available (skipped with a notice: CI still runs the lane)
#   1 — A deed failed, or an A2ML file is not accounted for

set -euo pipefail

REPO="${INPUT_PATH:-.}"
STANDARDS_DIR="${STANDARDS_DIR:-$(cd "$REPO/.." && pwd)/standards}"
case "$STANDARDS_DIR" in
    /*) ;;
    *) STANDARDS_DIR="$PWD/$STANDARDS_DIR" ;;
esac
LINTER="$STANDARDS_DIR/1-formats/deed/tools/deed_lint.js"
A2ML_GATE="$STANDARDS_DIR/scripts/check-a2ml-archived.sh"
LEDGER=".machine_readable/a2ml-legacy-allow.txt"

cd "$REPO"
errors=0

if [ -f "$LEDGER" ]; then
    if [ -f "$A2ML_GATE" ]; then
        echo "  A2ML: checking against the shrink-only ledger $LEDGER"
        if ! bash "$A2ML_GATE" ${A2ML_BASE:+--base "$A2ML_BASE"} .; then
            errors=$((errors + 1))
        fi
    else
        echo "::notice::A2ML: $LEDGER is present but the canonical gate is not ($A2ML_GATE); the deed-conformance lane checks it in CI"
    fi
else
    mapfile -t a2ml < <(git ls-files | grep -E '\.a2ml(\.in|\.template|\.v[0-9]+\.template)?$' | grep -v '^9-archive/' || true)
    for f in "${a2ml[@]}"; do
        echo "::error file=$f::.a2ml is retired; move its facts into the repo deed and delete it, or list it in $LEDGER"
        errors=$((errors + 1))
    done
fi

if [ ! -f "$LINTER" ] || ! command -v bun >/dev/null 2>&1; then
    echo "::notice::DEED: no deed linter here (needs Bun and a standards checkout at $STANDARDS_DIR; set STANDARDS_DIR); the deed-conformance lane lints in CI"
    [ "$errors" -eq 0 ] || exit 1
    exit 0
fi

mapfile -t deeds < <(git ls-files -- '*.deed' | sort)
for f in "${deeds[@]}"; do
    echo "  Linting: $f"
    if ! bun "$LINTER" "$f"; then
        errors=$((errors + 1))
    fi
done

echo "DEED: ${#deeds[@]} file(s), ${errors} failing (linter: $LINTER)"
[ "$errors" -eq 0 ] || { echo "::error::DEED validation failed for ${errors} file(s)"; exit 1; }
echo "DEED validation passed."
