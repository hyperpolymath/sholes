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
    for f in docs/legal/EXHIBIT-A-ETHICAL-USE.txt docs/legal/EXHIBIT-B-QUANTUM-SAFE.txt LICENSES/MPL-2.0.txt; do
        [ -f "$f" ] || MISSING="$MISSING $f"
    done
    if [ ! -d "src/interface/abi" ] && [ ! -d "src/interface/Abi" ]; then
        MISSING="$MISSING src/interface/abi"
    fi
    for f in src/interface/ffi src/interface/generated; do
        [ -d "$f" ] || MISSING="$MISSING $f"
    done
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
        [ -n "$(field "" repo-uuid)" ] || MISSING="$MISSING $DEED:repo-uuid"
        # CLADE-003/006 on the deed: a closed code set, and the code must agree
        # with its name. UNASSIGNED fails on purpose: an unchosen clade must
        # never be mistakable for a chosen one.
        case "$(field clade primary)|$(field clade primary-name)" in
            "fv|Formal Verification & Proofs"|"nl|Nextgen Languages"|"rm|Repo Management & Tooling"|\
            "gv|Governance & Standards"|"db|Databases"|"ap|Applications"|"ix|Infrastructure & Cloud"|\
            "dx|Developer Ecosystem"|"pt|Protocols & Interop"|"ax|AI & Neurosymbolic"|\
            "gm|Games & Interactive"|"sc|Security") ;;
            *) MISSING="$MISSING $DEED:clade(primary/primary-name unset or mismatched)" ;;
        esac
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
        [ "$(field ecosystem project)" = "$(field "" canonical-name)" ] \
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
        if [ -n "$phase" ] && [ -n "$level" ]; then
            echo "$DEED: valid (phase $phase, maturity $level)"
        else
            echo "$DEED: INVALID (needs (status :phase …) and (maturity :level …))"
            exit 1
        fi
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
