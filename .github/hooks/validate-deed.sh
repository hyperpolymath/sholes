#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# validate-deed.sh — DEED manifest validation script
#
# Scans for .deed files and validates the checks below. A .a2ml file is an
# error on sight: the format is retired estate-wide and its facts belong in
# the repo deed. Checks:
#   1. Required fields: agent-id or pedigree name, version
#   2. SPDX-License-Identifier header presence
#   3. Attestation block structure (if present)
#   4. Section heading syntax ([section] or ## section)
#
# Environment variables:
#   INPUT_PATH   — Directory to scan (default: .)
#   INPUT_STRICT — Promote warnings to errors (default: false)
#
# Exit codes:
#   0 — All files valid (or only warnings in non-strict mode)
#   1 — Validation errors found

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCAN_PATH="${INPUT_PATH:-.}"
STRICT="${INPUT_STRICT:-false}"
PATHS_IGNORE_RAW="${INPUT_PATHS_IGNORE:-}"
GITHUB_OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/null}"

# Parse paths-ignore: newline-separated fragments, blank lines and # comments
# stripped. Each fragment is a substring match against the file path. Pattern
# adopted from hyperpolymath/hypatia#243 — content-pattern validators must
# distinguish a target from a vendored / fixture file that legitimately
# contains the very pattern being checked.
PATHS_IGNORE=()
while IFS= read -r _frag; do
    # Strip leading and trailing whitespace (canonical bash idiom).
    _frag="${_frag#"${_frag%%[![:space:]]*}"}"
    _frag="${_frag%"${_frag##*[![:space:]]}"}"
    [[ -z "$_frag" || "$_frag" == \#* ]] && continue
    PATHS_IGNORE+=("$_frag")
done <<< "$PATHS_IGNORE_RAW"

# Returns 0 if path should be skipped (matches any ignore fragment)
path_ignored() {
    local p="$1" frag
    for frag in "${PATHS_IGNORE[@]}"; do
        [[ "$p" == *"$frag"* ]] && return 0
    done
    return 1
}

# Counters
FILES_SCANNED=0
ERRORS=0
WARNINGS=0

# ---------------------------------------------------------------------------
# Helper: emit GitHub annotation
# ---------------------------------------------------------------------------
# Usage: annotate <level> <file> <line> <message>
#   level: error | warning | notice
annotate() {
    local level="$1" file="$2" line="$3" message="$4"
    echo "::${level} file=${file},line=${line}::${message}"
}

# ---------------------------------------------------------------------------
# Helper: report issue (respects strict mode)
# ---------------------------------------------------------------------------
# Usage: report_issue <severity> <file> <line> <message>
#   severity: error | warning
report_issue() {
    local severity="$1" file="$2" line="$3" message="$4"

    if [[ "$severity" == "warning" && "$STRICT" == "true" ]]; then
        severity="error"
    fi

    annotate "$severity" "$file" "$line" "$message"

    if [[ "$severity" == "error" ]]; then
        ERRORS=$((ERRORS + 1))
    else
        WARNINGS=$((WARNINGS + 1))
    fi
}

# ---------------------------------------------------------------------------
# Validator: check a single .deed file
# ---------------------------------------------------------------------------
validate_deed() {
    local file="$1"
    FILES_SCANNED=$((FILES_SCANNED + 1))

    # --- Check 1: SPDX header ---
    # The SPDX-License-Identifier should appear in the first 10 lines
    local has_spdx=false
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [[ $line_num -gt 10 ]]; then
            break
        fi
        if [[ "$line" == *"SPDX-License-Identifier"* ]]; then
            has_spdx=true
            break
        fi
    done < "$file"

    if [[ "$has_spdx" == "false" ]]; then
        report_issue "warning" "$file" 1 \
            "Missing SPDX-License-Identifier in first 10 lines"
    fi

    # --- Check 2: Required identity fields ---
    # DEED files must contain either:
    #   - agent-id = "..." or agent_id = "..."
    #   - pedigree block with name field
    #   - name = "..." at top level (for AI manifests)
    local has_identity=false
    local has_version=false
    local first_form_seen=false
    line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Check for identity fields (various DEED patterns)
        # TOML/kv form: `name = "..."`, `project = "..."`, `agent-id = "..."`.

        if [[ "$line" =~ ^[[:space:]]*(agent[-_]id|name|project|archetype)[[:space:]]*= ]]; then
            has_identity=true
        fi
        # S-expression form: `(name "...")`, `(project "...")`,
        # `(agent-id "...")`. Some DEED dialects (audit registries,
        # classification stores) use Lisp-style s-expressions for the
        # metadata block instead of TOML. Identity carries the same
        # semantics; only the syntax differs. Match at any indent so it
        # also picks up entries nested under `(metadata ...)`.
        if [[ "$line" =~ ^[[:space:]]*\([[:space:]]*(agent[-_]id|name|project)[[:space:]]+\" ]]; then
            has_identity=true
        fi
        # Colon / brace-block form: `name: "..."`, `id: "..."`, `project: "..."`.
        # YAML-ish and brace-block DEED dialects (e.g. `Trust { name: "..." }`,
        # `id: "tsdm-standard"`) carry the same identity semantics; only the
        # delimiter (`:` vs `=`) differs. `id` is the brace-block spelling of an
        # identity key.
        if [[ "$line" =~ ^[[:space:]]*(agent[-_]id|name|project|id)[[:space:]]*: ]]; then
            has_identity=true
        fi
        # DEED s-expression head form: `(estate-deed`, `(repo-deed`,
        # `(estate-atlas-deed`, `(praxis-deed`. Per DEED-GRAMMAR-SPEC
        # <<identity>>, a file whose first form is one of the four declared
        # heads is a deed of that kind, and the head satisfies the structural
        # half of identity. Only the FIRST form is eligible — checking every
        # line would let a malformed file open with some other form and append
        # a deed head lower down to buy identity. Ported from
        # hyperpolymath/deed-ecosystem validate-action/validate-a2ml.sh so the
        # local hook and the CI action agree on what a deed is.
        if [[ "$first_form_seen" == "false" && "$line" =~ ^[[:space:]]*\( ]]; then
            first_form_seen=true
            if [[ "$line" =~ ^[[:space:]]*\((estate-deed|repo-deed|estate-atlas-deed|praxis-deed)([[:space:]]|$) ]]; then
                has_identity=true
            fi
        fi
        # DEED keyword identity form: `:canonical-name "..."` and the two other
        # identity keywords the spec names. Leading colon: none of the forms
        # above match it, because they test the bare words.
        if [[ "$line" =~ ^[[:space:]]*:(canonical-name|estate-authority|agent-id)[[:space:]] ]]; then
            has_identity=true
        fi
        # Check for version field — TOML form
        if [[ "$line" =~ ^[[:space:]]*(version|schema_version)[[:space:]]*= ]]; then
            has_version=true
        fi
        # Version field — s-expression form
        if [[ "$line" =~ ^[[:space:]]*\([[:space:]]*(version|schema_version)[[:space:]]+\" ]]; then
            has_version=true
        fi
        # Version field — colon / brace-block form
        if [[ "$line" =~ ^[[:space:]]*(version|schema_version)[[:space:]]*: ]]; then
            has_version=true
        fi
        # DEED keyword version form: `:schema-version "1.0.0"` — leading colon,
        # hyphenated, REQUIRED on all four deed heads. The three patterns above
        # spell it `schema_version` with no leading colon, so a conforming deed
        # matched none of them. `:registry-version` is a distinct, optional
        # atlas field and never satisfies the version requirement.
        if [[ "$line" =~ ^[[:space:]]*:schema-version[[:space:]] ]]; then
            has_version=true
        fi
    done < "$file"

    # Canonical structured DEED tree. Everything under a `.machine_readable/`
    # directory is a typed agent-readable doc (CLADE, ANCHOR, STATE,
    # ECOSYSTEM, bot_directives/{debt,coverage,methodology}, ai/AI,
    # policies/*, integrations/*, …). Per the RSR convention these carry
    # identity structurally — owning repo + path + filename — not via an
    # in-file `name`/`agent-id`. This generalises the `.machine_readable/descriptiles/`
    # rationale above to the whole tree: rsr-template-repo itself ships these
    # files without an in-file identity key, so requiring one produces
    # estate-wide false positives on every repo built from the canonical
    # template. Files outside `.machine_readable/` are still validated.
    local is_structural_identity=false
    if [[ "$file" == *"/.machine_readable/"* || "$file" == "./.machine_readable/"* || "$file" == ".machine_readable/"* ]]; then
        is_structural_identity=true
    fi

    if [[ "$has_identity" == "false" && "$is_structural_identity" == "false" ]]; then
        report_issue "error" "$file" 1 \
            "Missing required identity field (agent-id, name, or project)"
    fi

    if [[ "$has_version" == "false" && "$is_structural_identity" == "false" ]]; then
        report_issue "warning" "$file" 1 \
            "Missing version or schema_version field"
    fi

    # --- Check 3: Attestation block structure ---
    # If file contains [attestation] or ## ATTESTATION, validate it has
    # required sub-fields: proof or signature
    local in_attestation=false
    local attestation_line=0
    local attestation_has_content=false
    line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Detect attestation section start
        if [[ "$line" =~ ^\[attestation\] ]] || [[ "$line" =~ ^##[[:space:]]+[Aa]ttestation ]] || [[ "$line" =~ ^##[[:space:]]+ATTESTATION ]]; then
            in_attestation=true
            attestation_line=$line_num
            continue
        fi

        # Detect next section (ends attestation block)
        if [[ "$in_attestation" == "true" ]]; then
            if [[ "$line" =~ ^\[.+\] ]] || [[ "$line" =~ ^##[[:space:]] ]]; then
                in_attestation=false
                continue
            fi
            # Check for content in attestation block
            if [[ "$line" =~ (proof|signature|verified|hash)[[:space:]]*= ]]; then
                attestation_has_content=true
            fi
        fi
    done < "$file"

    if [[ $attestation_line -gt 0 && "$attestation_has_content" == "false" ]]; then
        report_issue "warning" "$file" "$attestation_line" \
            "Attestation block found but missing proof/signature/hash fields"
    fi

    # --- Check 4: Section heading syntax ---
    # Validate that [section] headings are well-formed (no unclosed brackets)
    line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        # Lines starting with [ should have a matching ]
        if [[ "$line" =~ ^\[ && ! "$line" =~ ^\[.+\] ]]; then
            # Exclude markdown-style links and multi-line values
            if [[ ! "$line" =~ ^\[.*\]\( && ! "$line" =~ ^\[TODO && ! "$line" =~ ^\[YOUR ]]; then
                report_issue "warning" "$file" "$line_num" \
                    "Possibly malformed section heading: unclosed bracket"
            fi
        fi
    done < "$file"
}

# ---------------------------------------------------------------------------
# Main: refuse retired .a2ml files, then discover and validate .deed files
# ---------------------------------------------------------------------------

echo "::group::DEED Manifest Validation"
echo "Scanning ${SCAN_PATH} for .deed files..."
echo ""

# The .a2ml format is retired: every such file is an error, whatever its content.
mapfile -t a2ml_files < <(find "$SCAN_PATH" -iname '*.a2ml' -not -path '*/.git/*' -type f | sort)
for _f in "${a2ml_files[@]}"; do
    path_ignored "$_f" && continue
    report_issue "error" "$_f" 1 "Retired .a2ml file: move its facts into the repo deed and delete it"
done

# Find all deed manifests, excluding .git
mapfile -t deed_candidates < <(find "$SCAN_PATH" -name '*.deed' -not -path '*/.git/*' -type f | sort)

# Apply paths-ignore filter
deed_files=()
SKIPPED=0
for _f in "${deed_candidates[@]}"; do
    if path_ignored "$_f"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    deed_files+=("$_f")
done

if [[ $SKIPPED -gt 0 ]]; then
    echo "::notice::Skipped ${SKIPPED} file(s) matching paths-ignore"
fi

if [[ ${#deed_files[@]} -eq 0 ]]; then
    echo "::notice::No .deed files found in ${SCAN_PATH}"
    echo "files_scanned=0" >> "$GITHUB_OUTPUT_FILE" 2>/dev/null || true
    echo "errors=${ERRORS}" >> "$GITHUB_OUTPUT_FILE" 2>/dev/null || true
    echo "warnings=0" >> "$GITHUB_OUTPUT_FILE" 2>/dev/null || true
    echo "::endgroup::"
    # A retired .a2ml file is still an error when no deed is present.
    [[ $ERRORS -eq 0 ]] || exit 1
    exit 0
fi

echo "Found ${#deed_files[@]} .deed file(s)"
echo ""

for file in "${deed_files[@]}"; do
    echo "  Validating: ${file}"
    validate_deed "$file"
done

echo ""
echo "────────────────────────────────────────"
echo "Files scanned: ${FILES_SCANNED}"
echo "Errors:        ${ERRORS}"
echo "Warnings:      ${WARNINGS}"
echo "Strict mode:   ${STRICT}"
echo "────────────────────────────────────────"

# Write outputs for GitHub Actions
{
    echo "files_scanned=${FILES_SCANNED}"
    echo "errors=${ERRORS}"
    echo "warnings=${WARNINGS}"
} >> "$GITHUB_OUTPUT_FILE" 2>/dev/null || true

echo "::endgroup::"

# Exit with failure if errors were found
if [[ $ERRORS -gt 0 ]]; then
    echo "::error::DEED validation failed with ${ERRORS} error(s)"
    exit 1
fi

echo "DEED validation passed."
exit 0
