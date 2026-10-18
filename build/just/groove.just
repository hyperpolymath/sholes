# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# GROOVE PROTOCOL
#
# Imported by ../../Justfile via `import? "build/just/groove.just"`.
# Recipes here configure and validate the Groove protocol manifest — the
# (integrations (groove …)) clause of the repo deed: port assignment, API
# surface flags (REST/gRPC/GraphQL/WebSocket/SSE), and template-placeholder
# hygiene. Every write goes through scripts/deed-clause.sh, one clause at a
# time. The manifest is consumed by the Groove bridge / zig-unified-api-adapter.

# Configure Groove protocol manifest (port assignment, API surfaces)
groove-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    DEED="$(bash scripts/deed-field.sh --find .)" || { echo "Error: no single *_chora.deed here. Run 'just repo-init' first."; exit 1; }
    MANIFEST="$DEED (integrations (groove))"
    if ! bash scripts/deed-field.sh --has "$DEED" integrations/groove; then
        echo "Error: $DEED has no (integrations (groove)) clause."
        exit 1
    fi

    echo "═══════════════════════════════════════════════════"
    echo "  Groove Protocol Setup"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "Check PORT-REGISTRY.md before assigning a port:"
    echo "  https://github.com/hyperpolymath/standards/blob/main/PORT-REGISTRY.md"
    echo ""

    read -rp "Primary port for this service: " PORT
    [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$PORT" -le 65535 ] || { echo "Error: port must be an integer 1-65535"; exit 1; }

    echo ""
    echo "Which API surfaces does this project expose?"
    read -rp "  REST API? [Y/n]: " REST
    read -rp "  gRPC? [y/N]: " GRPC
    read -rp "  GraphQL? [y/N]: " GRAPHQL
    read -rp "  WebSocket? [y/N]: " WS
    read -rp "  SSE (Server-Sent Events)? [y/N]: " SSE

    bash scripts/deed-clause.sh set "$DEED" integrations/groove port "$PORT"

    # surface NAME ANSWER DEFAULT — write :enabled for one API surface from a
    # y/n answer, DEFAULT (y or n) applying to an empty answer.
    surface() {
        local a="${2:-$3}" v='#f'
        [[ "${a,,}" == y* ]] && v='#t'
        bash scripts/deed-clause.sh set "$DEED" "integrations/groove/api-surfaces/$1" enabled "$v"
    }
    surface rest "$REST" y
    surface grpc "$GRPC" n
    surface graphql "$GRAPHQL" n
    surface websocket "$WS" n
    surface sse "$SSE" n

    echo ""
    echo "Groove manifest updated: $MANIFEST"
    echo "Port ${PORT} assigned. Add to PORT-REGISTRY.md if not already there."

# Check for template placeholders that haven't been replaced
verify-template:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Checking for unreplaced template placeholders..."
    FOUND=0

    # Check for double-brace placeholder patterns
    HITS=$(grep -rn '{{'{{'}}[A-Z_]*{{'}}'}}' --include="*.adoc" --include="*.md" --include="*.deed" \
           --include="*.scm" --include="*.toml" --include="*.yml" --include="*.yaml" \
           . 2>/dev/null | grep -v 'node_modules\|\.git/' | grep -v 'PLACEHOLDERS.adoc' || true)
    if [ -n "$HITS" ]; then
        echo ""
        echo "⚠ Unreplaced placeholders found:"
        echo "$HITS" | head -20
        FOUND=1
    fi

    # Check for template defaults still present
    if grep -q 'rsr-template-repo' Justfile 2>/dev/null; then
        echo "⚠ Justfile still references 'rsr-template-repo' — update project name"
        FOUND=1
    fi

    # Check for port 0 in Groove manifest
    DEED="$(bash scripts/deed-field.sh --find . 2>/dev/null || true)"
    if [ -n "$DEED" ] && [ "$(bash scripts/deed-field.sh "$DEED" integrations/groove port 2>/dev/null)" = 0 ]; then
        echo "⚠ Groove manifest has port 0 — run 'just groove-setup' to assign a port"
        FOUND=1
    fi

    # Check the repo deed for unfilled template placeholders
    for f in *_chora.deed; do
        if [ -f "$f" ] && grep -q '{{'{{'}}' "$f" 2>/dev/null; then
            echo "⚠ $f still has template placeholders"
            FOUND=1
        fi
    done

    if [ $FOUND -eq 0 ]; then
        echo "✓ No template placeholders found — project is properly customised."
    else
        echo ""
        echo "Run 'just repo-init' to replace placeholders, or edit files manually."
        exit 1
    fi
