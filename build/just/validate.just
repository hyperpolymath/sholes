# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# VALIDATION & COMPLIANCE
#
# Imported by ../../Justfile via `import? "build/just/validate.just"`.
# Recipes here check that this repo conforms to the RSR (Rhodium Standard
# Repository) skeleton: required files, METAdata, AI install guide
# completeness, etc. Run via `just validate`.

# Validate RSR compliance
validate-rsr:
    #!/usr/bin/env bash
    cd "{{justfile_directory()}}"
    echo "=== RSR Compliance Check ==="
    MISSING=""
    for f in .editorconfig .gitignore Justfile README.adoc LICENSE; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    # The repo deed's filename carries the repo slug (<stem>_chora.deed), so
    # this is a glob.
    ls *_chora.deed >/dev/null 2>&1 || MISSING="$MISSING repo-deed (*_chora.deed)"
    # .a2ml is retired: a repo carrying one is non-conformant, whatever else holds.
    bash scripts/check-no-a2ml.sh . >/dev/null || MISSING="$MISSING no-a2ml(run scripts/check-no-a2ml.sh)"
    bash scripts/check-internal-links.sh . >/dev/null || MISSING="$MISSING internal-links(run scripts/check-internal-links.sh)"
    for f in docs/legal/EXHIBIT-A-ETHICAL-USE.txt docs/legal/EXHIBIT-B-QUANTUM-SAFE.txt LICENSES/MPL-2.0.txt; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    # The polyglot seam (Idris2 ABI over a Zig FFI) is INHERITED from the
    # template's spine, not required of every repository: an archetype whose
    # preset declares neither the abi nor the ffi capability prunes src/interface/
    # at mint (ADR-0003, archetypes/<name>/prune.txt). A minted Rust CLI is not
    # incomplete for lacking a seam it did not ask for. So: a tree that carries
    # the seam must carry all of it; a tree that carries none of it is complete
    # without it. Deleting one part of a present seam still fails.
    if [ -d src/interface ]; then
        if [ ! -d "src/interface/abi" ] && [ ! -d "src/interface/Abi" ]; then
            MISSING="$MISSING src/interface/abi"
        fi
        for f in src/interface/ffi src/interface/generated; do
            [ -d "$f" ] || MISSING="$MISSING $f"
        done
    fi
    for f in docs/governance/MAINTENANCE-CHECKLIST.adoc docs/governance/SOFTWARE-DEVELOPMENT-APPROACH.adoc; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    # Identity, lifecycle, maintenance axes, the anchor and the maintenance
    # policies are all clauses of the repo deed (rsr-template-repo#209).
    DEED=$(bash scripts/deed-field.sh --find . || true)
    if [ -n "$DEED" ] && bash scripts/deed-field.sh --has "$DEED" status; then
        # Prints the field, or nothing when it is absent.
        field() { bash scripts/deed-field.sh "$DEED" "$1" "$2" || true; }
        # Adds a MISSING entry unless deed field CLAUSE KEY equals the expected value.
        want() {
            [ "$(field "$1" "$2")" = "$3" ] || MISSING="$MISSING $DEED:$1:$2"
        }
        # Identity is the chora (standards A1, rulings R4, U1 to U4, V1): one
        # :repo-uuid on the deed header, minted once from the repo's birth
        # path and carried as the opaque literal #uuid"<lowercase RFC 9562>",
        # version 5 or 8. The legacy name literals #u5"…" and #u8"…" are still
        # read and are reported, not failed: their cutover date is the owner's.
        RAW_UUID="$(sed -n -E 's/^[[:space:]]*:repo-uuid[[:space:]]+(#(uuid|u5|u8)"[^"]*").*/\1/p' "$DEED" | head -1)"
        case "$RAW_UUID" in
            '#uuid"'*)
                printf '%s' "$RAW_UUID" | grep -Eq '^#uuid"[0-9a-f]{8}-[0-9a-f]{4}-[58][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"$' \
                    || MISSING="$MISSING $DEED:repo-uuid(#uuid literal is not a lowercase v5/v8 RFC 9562 id)"
                # A version 5 id is v5-identity (standards A1 C10, T30): a warning
                # here, an error with RSR_STRICT=1. The chora id is version 8 (V8).
                case "$RAW_UUID" in
                    '#uuid"'????????-????-5*)
                        if [ "${RSR_STRICT:-0}" = 1 ]; then
                            MISSING="$MISSING $DEED:repo-uuid(v5-identity)"
                        else
                            echo "WARNING: v5-identity: $DEED :repo-uuid $RAW_UUID is a version 5 id; the chora id is #uuid\"<v8 id of the birth path>\" (standards A1 V8). RSR_STRICT=1 makes this an error."
                        fi ;;
                esac ;;
            '#u5"'?*|'#u8"'?*)
                echo "NOTE: $DEED :repo-uuid is the legacy literal $RAW_UUID; the chora id is #uuid\"<v8 id of the birth path>\" (standards A1, V1)." ;;
            *) MISSING="$MISSING $DEED:repo-uuid" ;;
        esac
        bash scripts/deed-field.sh --has "$DEED" identity || MISSING="$MISSING $DEED:(identity)"
        [ -n "$(field identity primary-forge)" ] || MISSING="$MISSING $DEED:identity:primary-forge"
        # Clade placements are identity facts, never the id and never an edict
        # (standards A1 §11, ruling W10): no clause and no prefixed name are
        # required. A clade that IS declared must still be one of the 12 and agree
        # with its name, so a placement cannot point at the wrong shelf.
        if bash scripts/deed-field.sh --has "$DEED" clade; then
            case "$(field clade primary)|$(field clade primary-name)" in
                "fv|Formal Verification & Proofs"|"nl|Nextgen Languages"|"rm|Repo Management & Tooling"|\
                "gv|Governance & Standards"|"db|Databases"|"ap|Applications"|"ix|Infrastructure & Cloud"|\
                "dx|Developer Ecosystem"|"pt|Protocols & Interop"|"ax|AI & Neurosymbolic"|\
                "gm|Games & Interactive"|"sc|Security") ;;
                "UNASSIGNED|UNASSIGNED"|"|")
                    echo "NOTE: $DEED (clade …) names no clade; it is optional, so choose one or delete the clause." ;;
                *) MISSING="$MISSING $DEED:clade(primary/primary-name not one of the 12, or they disagree)" ;;
            esac
        fi
        # CLADE-004/005: the lifecycle phase is a closed set.
        case "$(field status phase)" in
            reserved|incubating|active|dormant|merged|superseded|archived|extinct) ;;
            *) MISSING="$MISSING $DEED:status:phase" ;;
        esac
        case "$(field maturity level)" in
            experimental|alpha|beta|production|lts) ;;
            *) MISSING="$MISSING $DEED:maturity:level" ;;
        esac
        # The ecosystem clause names the repo the deed's header names.
        # Both empty would compare equal; an identity must be present.
        [ -n "$(field "" canonical-name)" ] \
            && [ "$(field ecosystem project)" = "$(field "" canonical-name)" ] \
            || MISSING="$MISSING $DEED:ecosystem:project"
        want meta axis-1 "must > intend > like"
        want meta axis-2 "corrective > adaptive > perfective"
        want meta axis-3 "systems > compliance > effects"
        want meta scoping-first true
        want meta/scoping idris-unsound-scan "believe_me/assert_total"
        want meta/axis-3 audit-focus "systems in place, documentation explains actual state, safety/security accounted for, observed effects reviewed"
        want meta/axis-3 compliance-focus "seams/compromises/exception register, bounded exceptions, anti-drift checks"
        want meta/axis-3 effects-evidence "benchmark execution/results and maintainer status dialogue/review"
        for c in anchor policies/maintenance-axes policies/maintenance-checklist policies/software-development-approach; do
            bash scripts/deed-field.sh --has "$DEED" "$c" || MISSING="$MISSING $DEED:($c)"
        done
        want policies/maintenance-axes/axis-3-audit compliance-tooling "panic-attack"
        want policies/maintenance-axes/axis-3-audit effects-tooling "ecological checking with sustainabot guidance"
        want policies/maintenance-checklist/metadata source-human "docs/governance/MAINTENANCE-CHECKLIST.adoc"
        want policies/software-development-approach/metadata source-human "docs/governance/SOFTWARE-DEVELOPMENT-APPROACH.adoc"
    else
        MISSING="$MISSING repo-deed:(status …)-clause"
    fi
    if [ -n "$MISSING" ]; then
        echo "MISSING:$MISSING"
        exit 1
    fi
    echo "RSR compliance: PASS"

# Validate the repo's lifecycle state: the deed's (status …) and
# (maturity …) clauses.
validate-state:
    #!/usr/bin/env bash
    cd "{{justfile_directory()}}"
    DEED=$(bash scripts/deed-field.sh --find . || true)
    if [ -n "$DEED" ] && bash scripts/deed-field.sh --has "$DEED" status; then
        phase=$(bash scripts/deed-field.sh "$DEED" status phase || true)
        level=$(bash scripts/deed-field.sh "$DEED" maturity level || true)
        # The same closed sets validate-rsr enforces (CLADE-004/005): a
        # misspelt phase or level is not a state.
        case "$phase" in
            reserved|incubating|active|dormant|merged|superseded|archived|extinct) ;;
            *) echo "$DEED: INVALID (status :phase '$phase' is not one of reserved|incubating|active|dormant|merged|superseded|archived|extinct)"; exit 1 ;;
        esac
        case "$level" in
            experimental|alpha|beta|production|lts) ;;
            *) echo "$DEED: INVALID (maturity :level '$level' is not one of experimental|alpha|beta|production|lts)"; exit 1 ;;
        esac
        echo "$DEED: valid (phase $phase, maturity $level)"
    else
        echo "No repo state found: the repo deed has no (status …) clause"
        exit 1
    fi

validate-ai-install:
    #!/usr/bin/env bash
    cd "{{justfile_directory()}}"
    echo "=== AI Installation Guide Check ==="
    GUIDE="docs/AI_INSTALLATION_GUIDE.adoc"
    README="README.adoc"
    ERRORS=0

    # Check guide exists
    if [ ! -f "$GUIDE" ]; then
        echo "MISSING: $GUIDE (create from template: docs/AI_INSTALLATION_GUIDE.adoc)"
        ERRORS=$((ERRORS + 1))
    else
        # Check for unfilled TODO markers
        TODOS=$(grep -c '\[TODO-AI-INSTALL' "$GUIDE" 2>/dev/null || true)
        if [ "$TODOS" -gt 0 ]; then
            echo "INCOMPLETE: $GUIDE has $TODOS unfilled [TODO-AI-INSTALL] markers:"
            grep -n '\[TODO-AI-INSTALL' "$GUIDE" | head -10
            ERRORS=$((ERRORS + 1))
        else
            echo "$GUIDE: complete (no TODO markers)"
        fi

        # Check AI implementation section exists
        if ! grep -q 'ai-implementation' "$GUIDE" 2>/dev/null; then
            echo "MISSING: [[ai-implementation]] anchor in $GUIDE"
            ERRORS=$((ERRORS + 1))
        fi

        # Check privacy notice exists
        if ! grep -qi 'privacy' "$GUIDE" 2>/dev/null; then
            echo "MISSING: Privacy notice in $GUIDE"
            ERRORS=$((ERRORS + 1))
        fi

        # Check install commands exist (not just placeholders)
        if ! grep -q 'git clone' "$GUIDE" 2>/dev/null; then
            echo "WARNING: No git clone command found in $GUIDE -- install commands may be incomplete"
        fi
    fi

    # Check README has AI install section
    if [ -f "$README" ]; then
        if ! grep -qi 'AI-Assisted Installation' "$README" 2>/dev/null; then
            echo "MISSING: AI-Assisted Installation section in $README"
            echo "  Copy from docs/AI-INSTALL-README-SECTION.adoc"
            ERRORS=$((ERRORS + 1))
        fi

        # Check README for unfilled TODO markers
        README_TODOS=$(grep -c '\[TODO-AI-INSTALL' "$README" 2>/dev/null || true)
        if [ "$README_TODOS" -gt 0 ]; then
            echo "INCOMPLETE: $README has $README_TODOS unfilled [TODO-AI-INSTALL] markers"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # The rest of the provisioning set's AI and manual-setup documents. Their
    # locations come from the provisioning engine, so this check and `just doctor`
    # agree on where the warm-ups live (root, docs/onboarding/ or docs/).
    if [ -f build/just/provision-lib.sh ]; then
        for d in $(bash build/just/provision-lib.sh set-files | grep -E '(^|/)(SETUP|llm-warmup-[a-z]+)\.adoc$'); do
            if [ ! -f "$d" ]; then
                echo "MISSING: $d"
                ERRORS=$((ERRORS + 1))
            fi
        done
        if ! grep -q '^\[\[ai-install\]\]' "$README" 2>/dev/null; then
            echo "MISSING: [[ai-install]] anchor in $README (see build/just/provision.just ai-setup)"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    if [ "$ERRORS" -gt 0 ]; then
        echo ""
        echo "AI install guide: FAIL ($ERRORS issues)"
        exit 1
    fi
    echo "AI install guide: PASS"

# Full validation suite
validate: validate-rsr validate-state validate-ai-install
    @echo "All validations passed!"
