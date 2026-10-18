# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# INIT — Bootstrap a new project from this template
#
# Imported by ../../Justfile via `import? "build/just/repo-init.just"`.
# Variables (project, OWNER, REPO, version, tier) and the `set shell` directive
# are inherited from the root Justfile.

# Interactive project bootstrap — replaces all {{PLACEHOLDER}} tokens
# Optional archetype argument (e.g. `just repo-init julia-library`) applies an
# archetype overlay: see archetypes/README.adoc and ADR-0003.
repo-init archetype="":
    #!/usr/bin/env bash
    set -euo pipefail

    # ask PROMPT VAR — every prompt below goes through this, never through a
    # bare `read`. Interactive: read VAR from the terminal. Non-interactive
    # (RSR_NON_INTERACTIVE set, the scaffoldia / CI path): touch no stdin and
    # keep VAR's value from the environment, or empty when it has none.
    #
    # This replaced `read() { return 0; }`, which shadowed the builtin for the
    # WHOLE recipe. Measured 2026-10-14 minting resource-algebra:
    #   * a prompt the environment did not answer left its variable unset, so
    #     `set -u` killed the mint at OPENSSF_BP_ID, after docs/ had already
    #     been overwritten by the seed;
    #   * every `while read -r` loop below inherited the no-op, which succeeds
    #     without reading, so the substitution pass spun forever on an unbound
    #     `file`.
    # The non-interactive mint could therefore never complete, and the e2e test
    # drove only the interactive path, so nothing noticed.
    ask() {
        if [ -n "${RSR_NON_INTERACTIVE:-}" ]; then
            printf -v "$2" '%s' "${!2:-}"
        else
            read -rp "$1" "$2"
        fi
    }

    echo "═══════════════════════════════════════════════════"
    echo "  RSR Project Bootstrap"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # --- Archetype overlay data (ADR-0003) ---
    ARCHETYPE='{{archetype}}'
    ARCH_FILE=""
    ARCH_PRESET=""
    if [ -n "$ARCHETYPE" ]; then
        ARCH_FILE="archetypes/${ARCHETYPE}/${ARCHETYPE}_praxis.deed"
        if [ ! -f "$ARCH_FILE" ]; then
            echo "Error: unknown archetype '${ARCHETYPE}'. Available:"
            ls -1 archetypes 2>/dev/null | grep -v 'README' || echo "  (none)"
            exit 1
        fi
        ARCH_PRESET=$(bash scripts/deed-field.sh "$ARCH_FILE" capability preset || true)
        echo "Archetype: ${ARCHETYPE}${ARCH_PRESET:+  (capability preset: $ARCH_PRESET)}"
        echo ""
    fi

    # --- Load defaults from config (if exists) ---
    # Create yours: ~/.config/rsr/defaults
    # Format: OWNER=myorg  AUTHOR="My Name"  AUTHOR_EMAIL=me@example.org ...
    #         AUTHOR_ORCID=0000-0002-1825-0097 (optional)
    DEFAULTS="${XDG_CONFIG_HOME:-$HOME/.config}/rsr/defaults"
    if [ -f "$DEFAULTS" ]; then
        echo "Loading defaults from $DEFAULTS"
        # shellcheck source=/dev/null
        source "$DEFAULTS"
        echo ""
    fi

    # --- Required values (pre-filled from defaults if available) ---
    ask "Project name (human-readable, e.g. My Project): " PROJECT_NAME
    [ -z "$PROJECT_NAME" ] && echo "Error: project name required" && exit 1

    ask "Repository slug (e.g. my-project): " REPO
    [ -z "$REPO" ] && echo "Error: repo slug required" && exit 1
    # A Julia package repo is named after its package: `<Name>.jl`, where
    # <Name> is the package's own identifier (UpperCamelCase by Julia
    # convention). The julia-library archetype accepts that form as well as
    # the estate slug; every other mint takes the estate slug only.
    if [[ "$ARCHETYPE" = "julia-library" && "$REPO" =~ ^[A-Z][A-Za-z0-9]*\.jl$ ]]; then
        :
    elif [[ ! "$REPO" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
        echo "Error: repo slug must be lowercase alphanumeric words separated by single hyphens"
        [ "$ARCHETYPE" = "julia-library" ] && echo "       (or, for a Julia package, <Name>.jl with <Name> in UpperCamelCase)"
        exit 1
    fi

    ask "Owner [${OWNER:-}]: " _OWNER
    OWNER="${_OWNER:-${OWNER:-}}"
    [ -z "$OWNER" ] && echo "Error: owner required" && exit 1

    ask "Author full name [${AUTHOR:-}]: " _AUTHOR
    AUTHOR="${_AUTHOR:-${AUTHOR:-}}"
    [ -z "$AUTHOR" ] && echo "Error: author name required" && exit 1

    ask "Author email [${AUTHOR_EMAIL:-}]: " _AUTHOR_EMAIL
    AUTHOR_EMAIL="${_AUTHOR_EMAIL:-${AUTHOR_EMAIL:-}}"
    [ -z "$AUTHOR_EMAIL" ] && echo "Error: email required" && exit 1

    # --- Optional values (pre-filled from defaults if available) ---
    ask "Author organization [${AUTHOR_ORG:-none}]: " _AUTHOR_ORG
    AUTHOR_ORG="${_AUTHOR_ORG:-${AUTHOR_ORG:-}}"

    ask "Previous/alt email [${AUTHOR_EMAIL_ALT:-none}]: " _AUTHOR_EMAIL_ALT
    AUTHOR_EMAIL_ALT="${_AUTHOR_EMAIL_ALT:-${AUTHOR_EMAIL_ALT:-}}"

    # ORCID iD for CITATION.cff. Defaults from AUTHOR_ORCID in the defaults
    # file, then `git config user.orcid`, so an author sets it once:
    #     git config --global user.orcid 0000-0002-1825-0097
    # Blank drops the orcid line below. An all-zeros placeholder is worse than
    # no line: citation tools resolve it and attribute the work to nobody.
    AUTHOR_ORCID="${AUTHOR_ORCID:-$(git config --get user.orcid 2>/dev/null || true)}"
    ask "Author ORCID iD [${AUTHOR_ORCID:-none}]: " _AUTHOR_ORCID
    AUTHOR_ORCID="${_AUTHOR_ORCID:-${AUTHOR_ORCID:-}}"
    AUTHOR_ORCID="${AUTHOR_ORCID#http*://orcid.org/}"
    if [ -n "$AUTHOR_ORCID" ]; then
        if [[ ! "$AUTHOR_ORCID" =~ ^[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{3}[0-9X]$ ]]; then
            echo "Error: ORCID iD must look like 0000-0002-1825-0097 (got '${AUTHOR_ORCID}')"
            exit 1
        fi
        # ISO 7064 MOD 11-2 check digit, as ORCID specifies: a transposed
        # digit is a valid-looking iD that belongs to someone else.
        _orcid_digits="${AUTHOR_ORCID//-/}"
        _orcid_total=0
        for ((i = 0; i < 15; i++)); do
            _orcid_total=$(( (_orcid_total + ${_orcid_digits:i:1}) * 2 ))
        done
        _orcid_check=$(( (12 - _orcid_total % 11) % 11 ))
        [ "$_orcid_check" = 10 ] && _orcid_check=X
        if [ "$_orcid_check" != "${_orcid_digits:15:1}" ]; then
            echo "Error: ORCID iD ${AUTHOR_ORCID} fails its check digit (expected ${_orcid_check})"
            exit 1
        fi
    fi

    ask "Project description []: " PROJECT_DESCRIPTION

    ask "Forge domain [${FORGE:-github.com}]: " _FORGE
    FORGE="${_FORGE:-${FORGE:-github.com}}"

    ask "Security contact email [${SECURITY_EMAIL:-$AUTHOR_EMAIL}]: " _SECURITY_EMAIL
    SECURITY_EMAIL="${_SECURITY_EMAIL:-${SECURITY_EMAIL:-$AUTHOR_EMAIL}}"

    ask "Conduct contact email [${CONDUCT_EMAIL:-$AUTHOR_EMAIL}]: " _CONDUCT_EMAIL
    CONDUCT_EMAIL="${_CONDUCT_EMAIL:-${CONDUCT_EMAIL:-$AUTHOR_EMAIL}}"

    ask "Project type (library|binary|monorepo|service|website) [library]: " PROJECT_TYPE
    PROJECT_TYPE="${PROJECT_TYPE:-library}"

    ask "Website URL [https://${FORGE}/${OWNER}/${REPO}]: " WEBSITE
    WEBSITE="${WEBSITE:-https://${FORGE}/${OWNER}/${REPO}}"

    ask "OpenSSF Best Practices project ID (blank if not yet registered) []: " OPENSSF_BP_ID

    # --- Container values (optional — only relevant if build/container/ exists) ---
    # The default service name is the slug in lower case: an OCI image name
    # may not contain capitals, and a Julia slug (`<Name>.jl`) has them.
    if [ -d "build/container" ]; then
        echo ""
        echo "── Container configuration (optional) ─────────"
        ask "Service name [${SERVICE_NAME:-${REPO,,}}]: " _SERVICE_NAME
        SERVICE_NAME="${_SERVICE_NAME:-${SERVICE_NAME:-${REPO,,}}}"
        ask "Primary port [${PORT:-8080}]: " _PORT
        PORT="${_PORT:-${PORT:-8080}}"
        ask "Container registry [${REGISTRY:-ghcr.io/${OWNER}}]: " _REGISTRY
        REGISTRY="${_REGISTRY:-${REGISTRY:-ghcr.io/${OWNER}}}"
    else
        SERVICE_NAME="${SERVICE_NAME:-${REPO,,}}"
        PORT="${PORT:-8080}"
        REGISTRY="${REGISTRY:-ghcr.io/${OWNER}}"
    fi

    # --- Derived values ---
    # The PROJECT and project tokens land in identifiers (Zig, Idris, C macros),
    # so every character an identifier cannot hold maps to an underscore: the
    # hyphens of a slug and the dot of a Julia slug alike.
    PROJECT_UPPER=$(echo "$REPO" | tr '[:lower:]-.' '[:upper:]__')
    PROJECT_LOWER=$(echo "$REPO" | tr '[:upper:]-.' '[:lower:]__')
    CURRENT_YEAR=$(date +%Y)
    CURRENT_DATE=$(date +%Y-%m-%d)
    VERSION="0.1.0"

    # --- Derive the repo's uuid --------------------------------------------
    # THE UUID IS DERIVED, NOT ALLOCATED (gv-clade-index:
    # docs/SPEC-clade-verisim-portal.adoc §Identity Model):
    #     uuid = UUIDv5(namespace = URL, name = "github.com/<owner>/<name>")
    # We know OWNER and REPO, so this is computable here and must never be
    # guessed or copied. The owner segment is part of the derived name, so it is
    # part of the identity — a repo hosted elsewhere derives a different uuid.
    if command -v uuidgen >/dev/null 2>&1; then
        REPO_UUID=$(uuidgen --sha1 --namespace @url --name "${FORGE}/${OWNER}/${REPO}")
    else
        REPO_UUID="UNASSIGNED"
    fi

    # Derive citation name parts (best-effort split on last space)
    AUTHOR_LAST="${AUTHOR##* }"
    AUTHOR_FIRST="${AUTHOR% *}"
    FIRST_INITIAL="${AUTHOR_FIRST:0:1}."
    if [ "$AUTHOR_LAST" = "$AUTHOR_FIRST" ]; then
        AUTHOR_FIRST="$AUTHOR"
        AUTHOR_LAST=""
        FIRST_INITIAL=""
    fi

    echo ""
    echo "── Summary ──────────────────────────────────────"
    echo "  Project:     $PROJECT_NAME"
    echo "  Repo:        $REPO"
    echo "  Owner:       $OWNER"
    echo "  Author:      $AUTHOR <$AUTHOR_EMAIL>"
    [ -n "$AUTHOR_ORG" ] && echo "  Organization: $AUTHOR_ORG"
    [ -n "$AUTHOR_ORCID" ] && echo "  ORCID:       $AUTHOR_ORCID"
    echo "  Forge:       $FORGE"
    echo "  Year:        $CURRENT_YEAR"
    echo "────────────────────────────────────────────────"
    echo ""
    ask "Proceed? [Y/n] " CONFIRM
    [[ "${CONFIRM:-Y}" =~ ^[Nn] ]] && echo "Aborted." && exit 0

    echo ""
    echo "Replacing placeholders..."

    # Apply archetype overlay files (if any) BEFORE substitution, so overlay
    # files are rendered along with the rest of the tree.
    if [ -n "$ARCHETYPE" ] && [ -d "archetypes/${ARCHETYPE}/overlay" ]; then
        cp -a "archetypes/${ARCHETYPE}/overlay/." .
        echo "  applied overlay: archetypes/${ARCHETYPE}/overlay/"
    fi

    # An archetype's workflows bring their lock records as a fragment beside
    # the overlay, never as an overlay file: an overlay actions.lock REPLACES
    # the spine's lock, and every spine workflow then dies at startup with no
    # record. Merge the fragment in; a conflicting record stops the mint.
    if [ -n "$ARCHETYPE" ] && [ -f "archetypes/${ARCHETYPE}/actions.lock" ]; then
        bash scripts/rust-tool.sh merge-actions-lock \
            .github/workflows/actions.lock "archetypes/${ARCHETYPE}/actions.lock"
    fi

    # Seed docs/ from the documentation seed, BEFORE substitution so the seed's
    # own placeholder tokens are rendered along with everything else.
    #
    # This is an OVERLAY, not a replacement. The seed's four perspective docs
    # and its ADR template win on collision, because they are the
    # downstream-facing shape; everything else the spine ships under docs/
    # survives -- notably docs/governance/ and docs/legal/, which
    # build/just/validate.just hard-requires, so a wholesale replace would
    # break the minted repo's own validate gate.
    #
    # The seed's own README.adoc is instructions-for-use ("copy this, replace
    # the placeholders, delete this README"), not content, so it is not copied.
    # tar is used rather than cp so that existing docs/ subdirectories MERGE
    # instead of nesting (cp -a decisions docs/ would yield docs/decisions/decisions).
    if [ -d "build/docs-seed" ]; then
        mkdir -p docs
        ( cd build/docs-seed && tar cf - --exclude=README.adoc . ) | ( cd docs && tar xf - )
        echo "  seeded docs/ from build/docs-seed/ (its own README omitted)"
    fi

    # Brace tokens as variables (hex avoids just interpolation)
    LB=$(printf '\x7b\x7b')
    RB=$(printf '\x7d\x7d')

    # Build the sed expression list
    # Note: using | as delimiter since URLs contain /
    SED_ARGS=(
        -e "s|${LB}PROJECT_NAME${RB}|${PROJECT_NAME}|g"
        -e "s|${LB}PROJECT_DESCRIPTION${RB}|${PROJECT_DESCRIPTION}|g"
        -e "s|${LB}PROJECT${RB}|${PROJECT_UPPER}|g"
        -e "s|${LB}project${RB}|${PROJECT_LOWER}|g"
        -e "s|${LB}REPO${RB}|${REPO}|g"
        -e "s|${LB}OWNER${RB}|${OWNER}|g"
        -e "s|${LB}AUTHOR${RB}|${AUTHOR}|g"
        -e "s|${LB}AUTHOR_EMAIL${RB}|${AUTHOR_EMAIL}|g"
        -e "s|${LB}AUTHOR_ORG${RB}|${AUTHOR_ORG}|g"
        -e "s|${LB}AUTHOR_LAST${RB}|${AUTHOR_LAST}|g"
        -e "s|${LB}AUTHOR_FIRST${RB}|${AUTHOR_FIRST}|g"
        -e "s|${LB}AUTHOR_INITIALS${RB}|${FIRST_INITIAL}|g"
        -e "s|${LB}FORGE${RB}|${FORGE}|g"
        -e "s|${LB}CURRENT_YEAR${RB}|${CURRENT_YEAR}|g"
        -e "s|${LB}CURRENT_DATE${RB}|${CURRENT_DATE}|g"
        -e "s|${LB}DATE${RB}|${CURRENT_DATE}|g"
        -e "s|${LB}SECURITY_EMAIL${RB}|${SECURITY_EMAIL}|g"
        -e "s|${LB}CONDUCT_EMAIL${RB}|${CONDUCT_EMAIL}|g"
        -e "s|${LB}LICENSE${RB}|MPL-2.0|g"
        -e "s|${LB}CONDUCT_TEAM${RB}|Code of Conduct Committee|g"
        -e "s|${LB}RESPONSE_TIME${RB}|48 hours|g"
        -e "s|${LB}MAIN_BRANCH${RB}|main|g"
        -e "s|${LB}PROJECT_PURPOSE${RB}|${PROJECT_DESCRIPTION}|g"
        -e "s|${LB}PROJECT_ROLE${RB}|${PROJECT_TYPE}|g"
        -e "s|${LB}PROJECT_TYPE${RB}|${PROJECT_TYPE}|g"
        -e "s|${LB}WEBSITE${RB}|${WEBSITE}|g"
        -e "s|${LB}SERVICE_NAME${RB}|${SERVICE_NAME}|g"
        -e "s|${LB}PORT${RB}|${PORT}|g"
        -e "s|${LB}REGISTRY${RB}|${REGISTRY}|g"
        -e "s|${LB}IMAGE${RB}|${REGISTRY}/${SERVICE_NAME}|g"
        -e "s|${LB}VERSION${RB}|${VERSION}|g"
        -e "s|${LB}EMAIL${RB}|${AUTHOR_EMAIL}|g"
        -e "s|${LB}UUID${RB}|${REPO_UUID}|g"
        -e "s|${LB}DESCRIPTION${RB}|${PROJECT_DESCRIPTION}|g"
    )
    [ -n "$AUTHOR_EMAIL_ALT" ] && SED_ARGS+=(-e "s|${LB}AUTHOR_EMAIL_ALT${RB}|${AUTHOR_EMAIL_ALT}|g")
    [ -n "$AUTHOR_ORCID" ] && SED_ARGS+=(-e "s|${LB}AUTHOR_ORCID${RB}|${AUTHOR_ORCID}|g")
    [ -n "$OPENSSF_BP_ID" ] && SED_ARGS+=(-e "s|${LB}OPENSSF_BP_ID${RB}|${OPENSSF_BP_ID}|g")
    [ -n "$OPENSSF_BP_ID" ] && SED_ARGS+=(-e "s|${LB}OPENSSF_PROJECT_ID${RB}|${OPENSSF_BP_ID}|g")

    # Archetype-determined tokens (ADR-0003): the archetype contract fills
    # what it can honestly determine. Added BEFORE the UNASSIGNED fallback
    # below — sed applies expressions in order, so a token the archetype
    # answers never reaches the fallback, and one it omits still fails loudly.
    if [ -n "$ARCH_FILE" ]; then
        # The archetype's (tokens) clause: every :KEY "value" pair, read through
        # deed-field.sh so string escapes are decoded by the one reader.
        while IFS= read -r arch_tok; do
            arch_val=$(bash scripts/deed-field.sh "$ARCH_FILE" tokens "$arch_tok" || true)
            { [ -n "$arch_tok" ] && [ -n "$arch_val" ]; } || continue
            case "$arch_val" in *'|'*)
                echo "WARN: archetype token $arch_tok contains '|' (the sed delimiter) — skipped, stays UNASSIGNED"
                continue ;;
            esac
            SED_ARGS+=(-e "s|${LB}${arch_tok}${RB}|${arch_val}|g")
        done < <(bash scripts/deed-field.sh --clause "$ARCH_FILE" tokens \
                   | awk 'prev ~ /^A:/ && /^S/ { print substr(prev, 3) } { prev = $0 }')
    fi

    # Tokens only the author can answer. init cannot know a project's unique
    # strength or its language stack, and guessing would write fiction into
    # the deed's (anchor) clause — the estate's semantic authority. They
    # become UNASSIGNED, the same marker `just repo-init` already writes for an
    # unchosen clade: honest, greppable, and obviously unfinished, whereas a
    # leftover brace token just looks like the template broke.
    #   grep -rn UNASSIGNED . — to find what still needs you
    # (Brace tokens are spelled via ${LB}/${RB} throughout this recipe: just
    #  interpolates literal double braces even inside comments.)
    for tok in PROJECT_KIND PROJECT_DOMAIN PROJECT_UNIQUE_STRENGTH \
               TARGET_AUDIENCE LANG_STACK BUILD_CMD TEST_CMD MUST_INVARIANTS \
               PACKAGE_NAME DEPS BUILD_OUTPUT_PATH MAIN_FUNCTION; do
        SED_ARGS+=(-e "s|${LB}${tok}${RB}|UNASSIGNED|g")
    done

    # julia-library archetype: mint the package uuid as UUIDv8 profile C
    # (ADR-008 amendment: the strict UUIDv8 gate rejects the UUIDv5 mint,
    # and D320 requires unregistered packages at v8). Profile C is
    # DETERMINISTIC: bytes 0..15 of SHA-256("julia-package-identity" ":"
    # "github.com/<owner>/<name>"), version nibble 8, variant 10 -- stable
    # across re-mints of the same repo, derivable by any operator machine
    # with python3 (or bun over standards' scripts/uuid-v8.js), never
    # colliding with the repo uuid. The domain is REGISTERED in standards'
    # ADR-008-profile-c-domains.json. No python3 and no bun -> UNASSIGNED
    # (the honest fallback at :437); Pkg then refuses the package loudly
    # until the owner assigns one.
    if [ "$ARCHETYPE" = "julia-library" ]; then
        # GitHub owner logins are case-insensitive; canonicalize to lowercase
        # before the preimage so owner casing cannot fork the UUID.
        OWNER_LC=$(printf '%s' "${OWNER}" | tr '[:upper:]' '[:lower:]')
        if command -v bun >/dev/null 2>&1 && [ -f "${STANDARDS_UUID_V8_JS:-}" ]; then
            PACKAGE_UUID=$(bun "${STANDARDS_UUID_V8_JS}" c julia-package-identity "github.com/${OWNER_LC}/${REPO}")
        elif command -v python3 >/dev/null 2>&1; then
            PACKAGE_UUID=$(python3 -c '
    import hashlib, sys
    pre = ("julia-package-identity:github.com/%s/%s" % (sys.argv[1], sys.argv[2])).encode()
    b = bytearray(hashlib.sha256(pre).digest()[:16])
    b[6] = (b[6] & 0x0F) | 0x80   # version 8
    b[8] = (b[8] & 0x3F) | 0x80   # variant 10
    h = b.hex()
    print(f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}")' "${OWNER_LC}" "${REPO}")
        else
            PACKAGE_UUID=UNASSIGNED
        fi
        SED_ARGS+=(-e "s|${LB}PACKAGE_UUID${RB}|${PACKAGE_UUID}|g")
        echo "  package uuid: ${PACKAGE_UUID} (derived from repo uuid ${REPO_UUID})"
    fi

    # Optional values with no answer: drop the line that depends on them rather
    # than leaving the token in place. An unfilled token is not a neutral
    # reminder — the OpenSSF line renders a broken badge image and a dead link
    # in the new repo's README, and it trips the placeholder gate on every
    # subsequent push, which trains people to ignore a red CI. No id yet means
    # no badge yet; add it when you register at bestpractices.dev.
    #
    # Line deletion is only safe where the line is the whole construct. It
    # used to run on docs/governance/TEMPLATE-STANDARDS-AUDIT.adoc too, where
    # the token's line is one CELL of a six-column table row: deleting it
    # left an incomplete row, asciidoctor reported "dropping cells from
    # incomplete row", and Estate Rules' render gate failed in every child
    # minted without an OpenSSF id (measured 2026-10-14 on resource-algebra).
    # That document names the README's tokens rather than using them, so it
    # now spells them as plain names and needs no pass here.
    if [ -z "$OPENSSF_BP_ID" ]; then
        sed -i "/bestpractices\.dev\/projects\/${LB}OPENSSF_BP_ID${RB}/d" README.adoc 2>/dev/null || true
    fi
    # Same rule for the ORCID iD: CFF makes `orcid` optional, a wrong one is not.
    if [ -z "$AUTHOR_ORCID" ]; then
        sed -i "/orcid\.org\/${LB}AUTHOR_ORCID${RB}/d" CITATION.cff 2>/dev/null || true
    fi
    # A .mailmap exists to map an alternate address onto the canonical one.
    # With no alternate address there is nothing to map, and the sole entry
    # would keep an unfilled alt-email token in the angle brackets, which is a
    # malformed mailmap rather than a harmless leftover.
    # git reads .mailmap from the WORKTREE ROOT only (or via mailmap.file /
    # mailmap.blob, which nothing here configures). The copy that used to live
    # under .github/ was therefore inert and was never filled.
    if [ -z "$AUTHOR_EMAIL_ALT" ]; then
        printf '# No alternate author address to map.\n' > .mailmap
    fi

    # Replace in all text files (skip .git, LICENSE text, and binaries)
    #
    # Skip just files too. In a Justfile or *.just module, double braces are
    # just's OWN interpolation syntax, never a template token: every one in
    # the template is a just variable or parameter. The lowercase project
    # token is spelled exactly like just's interpolation of the `project`
    # variable, so this pass used to freeze it into the identifier form.
    # Measured 2026-10-14 minting resource-algebra: 7 Justfile lines, the
    # contractile Justfile copy and container.just's image tag all became the
    # literal `resource_algebra` instead of following `project :=
    # "resource-algebra"` (docs/man/resource_algebra.1, an image tagged with
    # the underscored name). The self-name pass below still rewrites the
    # template literal in these files; that is the edit they actually need.
    find . -type f \
        -not -path './.git/*' \
        -not -name 'MPL-2.0.txt' \
        -not -name 'Justfile' -not -name '*.just' \
        -not -name '*.png' -not -name '*.jpg' -not -name '*.gif' \
        -not -name '*.woff' -not -name '*.woff2' \
        | while read -r file; do
        if file --brief "$file" | grep -qi 'text\|ascii\|utf'; then
            sed -i "${SED_ARGS[@]}" "$file"
        fi
    done

    # Also replace [YOUR-REPO-NAME] and [YOUR-NAME/ORG] in the repo deed
    # (the family-7 allocation manifest folded into it — standards#837 pilot).
    sed -i "s|\[YOUR-REPO-NAME\]|${PROJECT_NAME}|g" rsr-template-repo_chora.deed 2>/dev/null || true
    sed -i "s|\[YOUR-NAME/ORG\]|${OWNER}|g" rsr-template-repo_chora.deed 2>/dev/null || true

    # --- Instruction-block pass --------------------------------------------
    # Delete the "TEMPLATE INSTRUCTIONS (delete this block before publishing)"
    # comments. Nothing ever did, and 211 estate repos still carry one. The
    # block is self-detonating: its own first line names a LITERAL doubled-brace
    # token, so the sed pass above has nothing to match, yet every placeholder
    # gate greps exactly that shape — a repo with every real token correctly
    # substituted still trips its own gate. Rationale and measurements in
    # scripts/strip-instruction-blocks.rs.
    #
    # Runs AFTER substitution, so real tokens are already filled; only the
    # instructions go. Deliberately skipped for *-template-repo itself: the
    # template's own blocks ARE the product, and its gate exempts it by remote
    # name — the same protection the self-name pass below uses.
    if [ "$REPO" != "${REPO%-template-repo}" ]; then
        echo "  instruction blocks: skipped (this IS a template repo)"
    else
        bash scripts/rust-tool.sh strip-instruction-blocks .
    fi

    # --- Dependabot ecosystem pass -----------------------------------------
    # dependabot.yml ships every common ecosystem under "remove unused ones for
    # your project". Nothing removed them: measured estate-wide, 206/206 repos
    # declaring `pip` have no Python manifest, and each such entry fails on
    # every scheduled run. Prune on the ARCHETYPE rather than on file presence —
    # a freshly minted tree has no manifests yet, so presence would delete
    # everything. Rationale in scripts/prune-dependabot-ecosystems.rs.
    keep_eco="github-actions"
    case "${ARCH_PRESET:-}" in *rust*|*cargo*) keep_eco="$keep_eco cargo" ;; esac
    case "${ARCH_PRESET:-}" in *node*|*js*|*ts*|*deno*|*bun*|*web*) keep_eco="$keep_eco npm" ;; esac
    case "${ARCH_PRESET:-}" in *elixir*|*mix*) keep_eco="$keep_eco mix" ;; esac
    case "${ARCH_PRESET:-}" in *python*|*py*) keep_eco="$keep_eco pip" ;; esac
    bash scripts/rust-tool.sh prune-dependabot-ecosystems .github/dependabot.yml $keep_eco

    # --- Self-name pass (ADR-0003) -----------------------------------------
    # The template's own name is written as a LITERAL, not as a placeholder
    # token, so the substitution loop above never touched it. Measured on a
    # scratch mint of 346ae56: a repo minted as `mint-check-lib` still carried
    #     Justfile:                project := "rsr-template-repo"
    #     Justfile:                REPO    := "rsr-template-repo"
    #     sonar-project.properties sonar.projectKey=hyperpolymath_rsr-template-repo
    #     the deed's (status) / (ecosystem) project = "rsr-template-repo"
    # i.e. it declared that it WAS the template, and would have reported its
    # code analysis into the TEMPLATE's SonarCloud project. This is the same
    # failure the repo-identity splice below fixes for the uuid/canonical-name;
    # nothing generalised it to the rest of the tree. Confirmed in the wild:
    # hyperpolymath/cargo-zigbuild still carries both Justfile lines.
    #
    # Provenance must SURVIVE this pass — a minted repo is supposed to record
    # what it came from. Two protections: paths that are ABOUT the template
    # (ADRs, its changelog, its own audit, and this recipe itself — which
    # holds PARENT_SLUG) are skipped wholesale, and within every other file
    # any line that names the parent AS a parent is left byte-for-byte alone.
    #
    # A line that names the template as something to DETECT is protected too:
    # the deed's state-validation `:reject-if-contains ("rsr-template-repo")`
    # flags state files still carrying template text. Rewritten to the child's
    # own slug it rejected every legitimate state file of the child (measured
    # 2026-10-14 on resource-algebra) - the same "detector eaten by the
    # filling" defect the :reject-if-matches comment in the deed records for
    # tokens.
    #
    # An issue or PR reference `rsr-template-repo#N` names the TEMPLATE's own
    # issue, and stays so. Rewritten it pointed at an issue of the child that
    # does not exist, or worse, an unrelated one: resource-algebra carried 20
    # such references (`resource-algebra#209` for the deed-clause migration)
    # after its mint on 2026-10-14. tests/workflows/self_name_pass_test.sh
    # runs these two lines on fixtures.
    if [ "$REPO" != "rsr-template-repo" ]; then
        SELF_PROV='instantiated-from|parent|upstream|chain =|lineage|minted from|created from|Template: |reject-if-contains'
        SELF_NAME_SED="/${SELF_PROV}/!{s|rsr-template-repo#([0-9])|__RSR_TEMPLATE_ISSUE__\\1|g;s|hyperpolymath/rsr-template-repo|${OWNER}/${REPO}|g;s|rsr-template-repo|${REPO}|g;s|__RSR_TEMPLATE_ISSUE__|rsr-template-repo#|g;}"
        find . -type f \
            -not -path './.git/*' \
            -not -path './build/just/repo-init.just' \
            -not -path './docs/decisions/*' \
            -not -name 'CHANGELOG.md' \
            -not -name 'TEMPLATE-STANDARDS-AUDIT.adoc' \
            -not -name 'TEMPLATE-LINEAGE-AUDIT.adoc' \
            -not -name '*.png' -not -name '*.jpg' -not -name '*.gif' \
            -not -name '*.woff' -not -name '*.woff2' \
            | while read -r file; do
            grep -q 'rsr-template-repo' "$file" 2>/dev/null || continue
            file --brief "$file" | grep -qi 'text\|ascii\|utf' || continue
            # sed -i preserves the mode bit; rewriting via a temp file would not.
            sed -i -E "$SELF_NAME_SED" "$file"
        done
        echo "  self-name: rewrote template literal -> ${REPO} (provenance lines preserved)"

        # The repo deed's FILENAME carries the repo slug (deed dispatch:
        # <stem>_chora.deed — deed.abnf v1.0.0). The self-name pass rewrote
        # the slug inside the file; the file itself is renamed here. Plain mv:
        # mint runs before the new repo's first commit. Renames (not tokens)
        # are how filenames change — a {{REPO}} token in a FILENAME is the
        # brace-collapse hazard class repo-init has already been burnt by.
        if [ -f rsr-template-repo_chora.deed ]; then
            mv rsr-template-repo_chora.deed "${REPO}_chora.deed"
            echo "  repo deed: renamed rsr-template-repo_chora.deed -> ${REPO}_chora.deed"
        fi

        # ── self-OWNER pass ──────────────────────────────────────────────────
        #
        # Same class as the self-name leak above, and missed by it: the
        # template's own OWNER is a plain literal, so nothing rewrote it. A repo
        # minted under a different owner shipped:
        #
        #     Justfile                 OWNER := "hyperpolymath"
        #     sonar-project.properties sonar.projectKey=hyperpolymath_<repo>
        #
        # i.e. it declared the wrong owner and reported its code analysis into
        # the wrong SonarCloud project. Measured on a metadatastician mint.
        #
        # This pass is deliberately NARROW — three exact, identity-bearing
        # lines. A blanket `hyperpolymath` -> ${OWNER} rewrite would be WRONG:
        # `hyperpolymath/standards`, `hyperpolymath/proven` and the other estate
        # dependencies are real repos every child genuinely points at, and
        # rewriting those would break the child's canon, CI and badges.
        if [ "$OWNER" != "hyperpolymath" ]; then
            sed -i -E 's|^(OWNER[[:space:]]*:=[[:space:]]*)"hyperpolymath"|\1"'"${OWNER}"'"|' Justfile
            sed -i -E 's|^sonar\.organization=hyperpolymath$|sonar.organization='"${OWNER}"'|' sonar-project.properties
            sed -i -E 's|^sonar\.projectKey=hyperpolymath_|sonar.projectKey='"${OWNER}"'_|' sonar-project.properties
            echo "  self-owner: rewrote owner literal -> ${OWNER} (estate dependency paths preserved)"
            echo "  NOTE: confirm the SonarCloud ORG is really '${OWNER}' before provisioning —"
            echo "        the GitHub owner and the SonarCloud org are not always the same."
        fi
    fi

    echo ""
    echo "── Identity (repo deed) ─────────────────────────"

    # Write THIS repo's identity into its deed, replacing rsr-template-repo's own.
    #
    # The template ships its REAL identity — clade rm, the canonical-name
    # rsr-template-repo, a production maturity, its own ecosystem relations —
    # between the `>>> repo-identity` / `<<< repo-identity` markers of the deed.
    # Before #209 the same facts sat in descriptiles/CLADE.a2ml, which nothing
    # in SED_ARGS touched, so every repo created from this template inherited
    # uuid a5ea1382-… and canonical-name "rsr-template-repo" verbatim and told
    # every arriving agent it WAS the template. chronicles-of-slavia and
    # scaffoldia were corrected for exactly this on 2026-07-16.
    #
    # build/templates/identity.deed.in has already had its brace tokens filled
    # by the substitution loop above. It uses only tokens whose values cannot
    # break a deed string (slug, owner, forge, date); free text such as the
    # description stays UNASSIGNED for the author.
    # The split is the whole point:
    #   DERIVABLE -> computed, never guessed  (uuid name, owner, canonical-name)
    #   JUDGEMENT -> left UNASSIGNED, fails loudly until a human chooses (clade)
    ID_IN="build/templates/identity.deed.in"
    DEED="${REPO}_chora.deed"
    [ -f "$DEED" ] || DEED="rsr-template-repo_chora.deed"
    if [ -f "$ID_IN" ] && [ -f "$DEED" ]; then
        if [ "$(grep -c '^  ; >>> repo-identity' "$DEED")" != 1 ] \
           || [ "$(grep -c '^  ; <<< repo-identity' "$DEED")" != 1 ]; then
            echo "Error: $DEED must hold exactly one repo-identity marker pair."
            exit 1
        fi
        awk -v frag="$ID_IN" '
            /^  ; >>> repo-identity/ { while ((getline l < frag) > 0) print l; skip = 1; next }
            /^  ; <<< repo-identity/ { skip = 0; next }
            !skip
        ' "$DEED" > "$DEED.splice"
        cat "$DEED.splice" > "$DEED"     # keeps the file's mode
        rm -f "$DEED.splice"
        # The uuid5 name. The self-name pass already rewrote owner and slug in
        # it; the forge domain is set here, because nothing else knows it.
        sed -i -E 's|^(  :repo-uuid #u5")[^"]*"|\1'"${FORGE}/${OWNER}/${REPO}"'"|' "$DEED"
        # The template's journal is not the child's: install the stub.
        mkdir -p docs/status
        cp build/templates/ROADMAP.adoc.in docs/status/ROADMAP.adoc
        rm -rf build/templates          # template-only; not part of your repo
        if [ "$REPO_UUID" = "UNASSIGNED" ]; then
            echo "  uuid:  UNASSIGNED — uuidgen not found."
            echo "         Install util-linux (uuid-runtime), then check it with:"
            echo "           uuidgen --sha1 --namespace @url --name \"${FORGE}/${OWNER}/${REPO}\""
        else
            echo "  uuid:  $REPO_UUID"
            echo "         (uuid5 of ${FORGE}/${OWNER}/${REPO} — derived from the deed's"
            echo "          :repo-uuid name, recomputable, not stored, not invented)"
        fi
        echo "  clade: UNASSIGNED — a human must choose one of the 12."
        echo "         just validate-rsr FAILS until you do. That is deliberate:"
        echo "         an unchosen clade must not look like a chosen one."
        echo "         The taxonomy is listed in the (clade …) comment of $DEED."
    fi

    echo "── Profile & provenance (ADR-0003) ──────────────"

    # The template deed's own (rsr-profile) clause is deliberately MAXIMAL (it
    # is the dogfood target). A minted repo must NOT inherit it: declaring
    # capabilities the tree lacks makes the oracle score modules that are
    # absent (na-honesty, RSR-SPEC-v2 §scoring). Replace it minimally, below.

    # ── Canon pin (bind the canon) ──────────────────────────────────────────
    # Read the canon identity from the template deed's `(canon …)` clause. A
    # minted repo must record WHICH canon release it was cut from; without it
    # "which repos are on canon 1.x?" is a campaign across the whole estate
    # instead of a grep.
    #
    # The pin lives only in the deed (#215 moved it there from the retired
    # profile file, whose copy could not follow canon 2.1.2).
    # The deed was renamed to ${REPO}_chora.deed by the self-name pass above,
    # and its (canon …) clause is carried into the child unchanged, so the
    # child's deed and its PROVENANCE agree at mint.
    #
    # Count rather than guessed: a value here that silently became empty is the
    # same class of defect as an UNASSIGNED placeholder, and would let a repo
    # claim conformance to nothing.
    #
    # Deliberately backslash-free. The previous TOML reader first spelled its
    # section test as /^\[/ , which reached awk as a DOUBLE backslash followed
    # by an unterminated bracket expression; awk parsed a character class that
    # swallowed the rest of the program, matched nothing, and the pin came out
    # silently EMPTY. Bracket classes such as [(] cannot be mis-escaped.
    #
    # deed_canon <key> <deed-file>: print the value of :<key> from the
    # deed's one (canon …) clause, or nothing when the clause or key is
    # absent or the clause is not unique. A ";" outside a string starts a
    # comment that runs to line-end (deed.abnf), whole-line or inline. The SAME function is in
    # .github/workflows/dogfood-gate.yml and standards
    # scripts/check-canon-lockstep.sh; keep the three identical.
    deed_canon() {
        _clauses="$(awk 'BEGIN { bs = sprintf("%c", 92); dq = sprintf("%c", 34) } { o = ""; q = 0; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (q && c == bs) { o = o c substr($0, i + 1, 1); i++; continue } if (c == dq) q = !q; else if (!q && c == ";") break; o = o c } printf "%s ", o }' "$2" | grep -oE '[(]canon[[:space:]][^()]*[)]')" || true
        _n="$(echo "$_clauses" | grep -c '(canon' || true)"
        if [ "$_n" != "1" ]; then
            echo "deed_canon: $2 carries ${_n:-0} (canon …) clauses, need exactly 1" >&2
            return 0
        fi
        echo "$_clauses" | grep -oE ':'"$1"'[[:space:]]+"[^"]*"' | head -1 | sed -E 's/^[^"]*"//; s/"$//' || true
    }

    DEED_OUT="${REPO}_chora.deed"
    CANON_VERSION=""
    CANON_CRITERIA_SHA=""
    CANON_GATES_SHA=""
    if [ -f "$DEED_OUT" ]; then
        CANON_VERSION="$(deed_canon version "$DEED_OUT")"
        CANON_CRITERIA_SHA="$(deed_canon criteria-sha256 "$DEED_OUT")"
        CANON_GATES_SHA="$(deed_canon gates-sha256 "$DEED_OUT")"
    fi
    CANON_VERSION="${CANON_VERSION:-UNASSIGNED}"
    CANON_CRITERIA_SHA="${CANON_CRITERIA_SHA:-UNASSIGNED}"
    CANON_GATES_SHA="${CANON_GATES_SHA:-UNASSIGNED}"
    if [ ! -f "$DEED_OUT" ]; then
        echo "Error: $DEED_OUT not found after the self-name pass — cannot write the" >&2
        echo "       child's (rsr-profile) / (variant) / (provenance) clauses." >&2
        exit 1
    fi

    # put_clause NAME — write the clause read from stdin as the deed's
    # top-level (NAME …) clause: replace it when present, append it otherwise,
    # so a re-run of repo-init never leaves two.
    put_clause() {
        if bash scripts/deed-field.sh --has "$DEED_OUT" "$1"; then
            bash scripts/deed-clause.sh replace "$DEED_OUT" "$1" -
        else
            bash scripts/deed-clause.sh append "$DEED_OUT" "" -
        fi
    }

    DECLARES_AGAINST=$(bash scripts/deed-field.sh "$DEED_OUT" rsr-profile declares-against 2>/dev/null || true)
    {
        echo "  ; rsr-profile — this repo's declared RSR v2.0 capabilities."
        echo "  ; Written by just repo-init on ${CURRENT_DATE}. The template's maximal"
        echo "  ; profile was replaced at mint: declare only what this tree carries."
        echo "  (rsr-profile"
        echo "    :version \"1.0.0\""
        echo "    :spec \"rsr-criteria-v2\""
        echo "    :declares-against \"${DECLARES_AGAINST:-2.0.0-draft}\""
        if [ -n "$ARCH_PRESET" ]; then
            echo "    :preset \"${ARCH_PRESET}\")"
        else
            echo "    ; UNASSIGNED: declare capabilities (or a preset) — see standards"
            echo "    ; .machine_readable/template-capability-gates.toml"
            echo "    :capabilities ())"
        fi
    } | bash scripts/deed-clause.sh replace "$DEED_OUT" rsr-profile -
    echo "  profile:    $DEED_OUT (rsr-profile)${ARCH_PRESET:+  (preset $ARCH_PRESET)}"

    # Provenance — the estate's answer-file (ADR-0002 contract shape, used
    # per ADR-0003 with direction=generated-from-core).
    #
    # repo-init runs INSIDE the template checkout, so the LOCAL git state is
    # the truth about what was actually copied. Prefer it. The previous
    # implementation read the LIVE remote tip (`git ls-remote ... HEAD`),
    # which records where the remote is *now* rather than the tree in hand:
    # mint from a branch, or from a checkout with unpushed commits, and
    # PROVENANCE named a commit the child never contained. That defeated the
    # answer-file's whole purpose. Remote lookup remains only as a fallback,
    # and the symref form also recovers the source BRANCH, which was never
    # recorded at all (#203).
    PARENT_SLUG="hyperpolymath/rsr-template-repo"
    PARENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    PARENT_PIN=$(git rev-parse --verify -q HEAD 2>/dev/null || true)
    PARENT_TREE=$(git rev-parse --verify -q 'HEAD^{tree}' 2>/dev/null || true)

    if [ -z "$PARENT_PIN" ]; then
        # Not a checkout (tarball, shallow copy, or offline): fall back to the
        # remote, and recover the branch from the symref.
        PARENT_BRANCH=$(git ls-remote --symref "https://github.com/${PARENT_SLUG}.git" HEAD 2>/dev/null \
            | sed -n 's|^ref: refs/heads/\([^[:space:]]*\).*|\1|p' | head -1 || true)
        PARENT_PIN=$(git ls-remote "https://github.com/${PARENT_SLUG}.git" HEAD 2>/dev/null | cut -f1 || true)
    fi

    # Shape, not presence: a value that is not a 40-hex object name (an
    # ls-remote error body, a literal "HEAD" from an unborn branch) is not a pin.
    [[ "$PARENT_PIN" =~ ^[0-9a-f]{40}$ ]] || PARENT_PIN=""
    [[ "$PARENT_TREE" =~ ^[0-9a-f]{40}$ ]] || PARENT_TREE=""
    [ "$PARENT_BRANCH" != "HEAD" ] || PARENT_BRANCH=""
    PARENT_BRANCH="${PARENT_BRANCH:-UNASSIGNED}"
    PARENT_PIN="${PARENT_PIN:-UNASSIGNED}"
    PARENT_TREE="${PARENT_TREE:-UNASSIGNED}"

    # Recorded in the (provenance) clause. Non-interactive mints are the automated
    # path (scaffoldia / CI); interactive ones are a human at a prompt. The
    # distinction matters because #201 found a hand-minted instance whose
    # generated identity was stale, and nothing recorded which path ran.
    if [ -n "${RSR_NON_INTERACTIVE:-}" ]; then
        MINT_MODE="non-interactive"
    else
        MINT_MODE="interactive"
    fi

    {
        echo "  ; variant — provenance contract (ADR-0002 shape; ADR-0003 use)."
        echo "  ; Records what this repo was minted from so the drift gate"
        echo "  ; (scripts/check-variant-drift.sh <parent-checkout>) and future"
        echo "  ; re-templating tooling have a defined input. Placeholder rendering"
        echo "  ; means many files differ from the parent by design; folding rendered"
        echo "  ; answers into (normalise) is future work (ADR-0003), so the gate is"
        echo "  ; informational for minted repos until then."
        echo "  (variant"
        echo "    :project \"${REPO}\""
        echo "    :schema-version \"0.1.0\""
        echo "    :last-updated \"${CURRENT_DATE}\""
        echo "    :parent \"${PARENT_SLUG}\""
        echo "    ; template tip at mint"
        echo "    :parent-pin \"${PARENT_PIN}\""
        echo "    :role \"minted-repo\""
        echo "    :stack \"${ARCHETYPE:-unspecified}\""
        echo "    :direction \"generated-from-core\""
        echo "    (normalise :rules \"action-pins self-name\")"
        echo "    ; Files a minted repo owns from birth are (paths :diverged …)."
        echo "    (paths"
        echo "      :added ()"
        echo "      :removed ()"
        echo "      :diverged (\"${REPO}_chora.deed\" \"docs/status/ROADMAP.adoc\")))"
    } | put_clause variant
    if [ "$PARENT_PIN" = "UNASSIGNED" ]; then
        echo "  provenance: $DEED_OUT (variant) — parent-pin UNASSIGNED (offline?)"
        echo "              Set it to the template commit you minted from:"
        echo "              git ls-remote https://github.com/${PARENT_SLUG}.git HEAD"
    else
        echo "  provenance: $DEED_OUT (variant)  (parent-pin ${PARENT_PIN:0:12})"
    fi

    # ── (provenance) — the answer-file for the canon binding ─────────────────
    # ADR-0003 named this the single highest-leverage gap: "a minted repo does
    # not know which template commit it came from, so template improvements
    # cannot be propagated and drift cannot be detected." Copier/Cruft solved
    # it with an answer-file + update + check; this estate hand-simulated it as
    # recurring standardisation-PR campaigns. This is the answer-file.
    #
    # (variant) above records the TEMPLATE dimension (diffing against the
    # parent). This records the CANON dimension (which law the repo was cut
    # under). They are different questions and both are needed.
    # Flat keys only: a nested form headed "canon" would be counted by
    # deed_canon above and empty the pin.
    {
        echo "  ; provenance — what this repo was minted FROM. Written once, at mint,"
        echo "  ; by build/just/repo-init.just. Tools that want \"what is this repo\" read"
        echo "  ; the rest of the deed; tools that want \"where did it come from\" read this."
        echo "  (provenance"
        echo "    :minted-at \"${CURRENT_DATE}\""
        echo "    :template-repo \"${PARENT_SLUG}\""
        echo "    :template-branch \"${PARENT_BRANCH}\""
        echo "    :template-commit \"${PARENT_PIN}\""
        echo "    :template-tree \"${PARENT_TREE}\""
        echo "    ; Contract: branches this repo is EXPECTED to carry beyond the default."
        echo "    ; Empty means default-only. A mint must never inherit template work"
        echo "    ; branches (coderabbit/, chore/, bot-task or stale branches) — that is"
        echo "    ; how knot-knot received a byte-identical copy of a template work branch"
        echo "    ; with no common ancestor (#203). Enforced by"
        echo "    ; scripts/check-template-conformance.sh."
        echo "    :extra-branches ()"
        echo "    :canon-version \"${CANON_VERSION}\""
        echo "    :criteria-sha256 \"${CANON_CRITERIA_SHA}\""
        echo "    :gates-sha256 \"${CANON_GATES_SHA}\""
        echo "    :archetype \"${ARCHETYPE:-}\""
        echo "    ; Which minting path actually ran (#201/#203 needed this signal)."
        echo "    :minted-by \"repo-init\""
        echo "    :mint-mode \"${MINT_MODE}\""
        echo "    ; A non-empty :unassigned list means the mint did not fully render;"
        echo "    ; the validation step below already fails on a leftover token."
        echo "    (substitutions :rendered 34 :unassigned ()))"
    } | put_clause provenance

    if [ "$CANON_VERSION" = "UNASSIGNED" ]; then
        echo "  provenance: $DEED_OUT (provenance) — canon pin UNASSIGNED"
        echo "              The template deed carried no (canon …) clause, so this repo"
        echo "              cannot state which canon it conforms to. Fix by minting"
        echo "              from a template commit that has one."
    else
        echo "  provenance: $DEED_OUT (provenance)  (canon v${CANON_VERSION} ${CANON_CRITERIA_SHA:0:12})"
    fi

    # archetypes/ is template-only overlay data, not part of your repo
    # (same reason build/templates is removed above).
    rm -rf archetypes
    rm -rf build/docs-seed          # template-only; its content now lives in docs/

    # Overlay .in rule (julia-library archetype; the convention any future
    # overlay can adopt): the overlay ships content templates as *.in so a
    # substitution token never survives in a file with a final name. Rename
    # the known set now that substitution has rendered them, before the
    # placeholder gate below.
    if [ "$ARCHETYPE" = "julia-library" ]; then
        # the name is read from Project.toml.in until the loop below renames
        # it - order matters.
        TOML_FILE=Project.toml
        [ -f "$TOML_FILE" ] || TOML_FILE=Project.toml.in
        if [ -f src/PACKAGE.jl.in ] && [ -f "$TOML_FILE" ]; then
            PKG_NAME=$(sed -n 's/^name = "\([^"]*\)".*/\1/p' "$TOML_FILE" | head -1)
            if [ -n "$PKG_NAME" ] && [ "$PKG_NAME" != "UNASSIGNED" ]; then
                mv "src/PACKAGE.jl.in" "src/${PKG_NAME}.jl"
                echo "  entry point: src/${PKG_NAME}.jl (from src/PACKAGE.jl.in)"
            else
                echo "WARN: Project.toml name is UNASSIGNED - src/PACKAGE.jl.in left in place"
                echo "      so the placeholder gate stays honest. Name the package, then run:"
                echo "      mv src/PACKAGE.jl.in src/<PackageName>.jl"
            fi
        fi
        for f in Project.toml.in \
                 .github/workflows/julia-ci.yml.in \
                 .github/workflows/julia-docs.yml.in; do
            [ -f "$f" ] && { mv "$f" "${f%.in}"; echo "  overlay: ${f%.in}"; }
        done
    fi

    # ── Regenerate what is DERIVED from the deed and the tree ───────────────
    # CLAUDE.md's arrival pack and the repository map are generated files, and
    # until now the mint left both describing the TEMPLATE. The self-name pass
    # swaps the slug inside them, which is worse than leaving them alone: the
    # pack then states the template's uuid and clade, maturity `production`,
    # and pipeline position `foundation` with chain "standards -> <this repo>
    # -> (every estate repo)", under the child's name. Measured 2026-10-14 on
    # resource-algebra. The map also kept the archetypes/ root entry,
    # which this recipe deletes, so Estate Rules' map-freshness step failed in
    # every minted child. Both are regenerated here, after every deed clause
    # above is written and every template-only path is gone. Fail-closed: a
    # generator that cannot run (no nickel on PATH) stops the mint rather than
    # shipping a pack that names the wrong repository.
    if [ -f .machine_readable/arrival-pack/generate.sh ]; then
        bash .machine_readable/arrival-pack/generate.sh
        echo "  arrival pack: CLAUDE.md regenerated from ${DEED_OUT}"
    fi
    if [ -f scripts/gen-repo-map.sh ]; then
        bash scripts/gen-repo-map.sh . >/dev/null
        echo "  repo map:     docs/architecture/REPOSITORY-MAP.adoc regenerated"
    fi

    echo ""
    echo "── Validation ───────────────────────────────────"

    # Check for remaining placeholders.
    #
    # This printed "WARNING" and then carried on to "Done! Mint complete." It
    # detected the very defect that went on to reach 211 repos, said so every
    # time, and stopped nobody. That is the fake-gate pattern this estate keeps
    # re-learning: a check that cannot fail reads as coverage while changing no
    # outcome.
    #
    # It now aborts the mint. A tree that still holds substitution tokens is not
    # minted, it is half-minted, and shipping one is how the estate acquired 12
    # permanently-red OpenSSF builds and 12 settings.yml files declaring an
    # unsubstituted repository name. That second one is not theoretical: the
    # braces were once submitted to GitHub, collapsed to dashes, and renamed a
    # repo to "-REPO-", which then read as deleted.
    #
    # RSR_ALLOW_PLACEHOLDERS=1 restores the old warning, for deliberately
    # partial mints — not for getting past this message.
    #
    # META tokens are exempt, matching scripts/check-no-placeholders.sh. A file
    # is only half-minted if it holds a token naming a real value; a file that
    # says "replace all {PLACEHOLDER} values" is prose ABOUT tokens and is
    # supposed to survive. Without this exemption the gate fires on README.adoc,
    # EXPLAINME.adoc, both descriptiles and the checker itself on every single
    # mint — measured — and a gate that always fires gets switched off.
    #
    # This exemption is also, exactly, why the instruction block went unnoticed
    # in 211 repos: {PLACEHOLDER} is the ONLY doubled-brace text in it, so any
    # gate sensibly exempting metasyntax must let the block through. The two
    # checks here are therefore complementary, not redundant — the block can
    # only be caught by name, which the check below does.
    # The four allowlisted paths are copied verbatim from
    # scripts/check-no-placeholders.sh so the two gates cannot drift apart.
    # Each legitimately names tokens: the token vocabulary itself, prose
    # explaining that tokens exist, the checker's own pattern, and the e2e
    # test's answer list.
    PATTERN="${LB}[A-Z_]*${RB}"
    META='PLACEHOLDER|ANYTHING|TOKEN|UPPER_SNAKE'
    REMAINING=$(grep -rl "$PATTERN" . --include='*.md' --include='*.adoc' --include='*.yml' --include='*.yaml' --include='*.deed' --include='*.toml' --include='*.scm' --include='*.ncl' --include='*.nix' --include='*.json' --include='*.sh' 2>/dev/null | grep -v '.git/' | while IFS= read -r f; do
        case "${f#./}" in
            .machine_readable/ai/PLACEHOLDERS.adoc|EXPLAINME.adoc|scripts/check-no-placeholders.sh|tests/e2e/template_instantiation_test.sh) continue ;;
        esac
        # Bracketed [{]{2} rather than a doubled brace written literally, for
        # two independent reasons. First, `grep -E` is ugrep on some estate
        # machines and rejects a bare doubled brace as an "empty
        # (sub)expression", because a brace opens an interval quantifier — the
        # same reason ci.yml uses this form estate-wide. Second, a doubled brace
        # inside a just RECIPE BODY is just's own interpolation delimiter, so
        # writing one here (even in a comment) is a parse error. That is why the
        # recipe computes LB/RB with printf instead of spelling them out.
        if grep -ohE '[{]{2}[A-Z][A-Z0-9_]*[}]{2}' "$f" | grep -qvE "^[{]{2}(${META})[}]{2}$"; then
            echo "$f"
        fi
    done || true)
    if [ -n "$REMAINING" ]; then
        echo "Remaining placeholders in:"
        echo "$REMAINING" | sed 's/^/  /'
        echo ""
        echo "Inspect with: grep -rn '$LB' . --include='*.md'"
        if [ "${RSR_ALLOW_PLACEHOLDERS:-0}" = "1" ]; then
            echo "WARNING: continuing anyway (RSR_ALLOW_PLACEHOLDERS=1)."
        else
            echo "ERROR: mint aborted — the tree above is half-minted."
            echo "       Fill those tokens, or re-run with RSR_ALLOW_PLACEHOLDERS=1"
            echo "       if a partial mint is genuinely what you want."
            exit 1
        fi
    else
        echo "All placeholders replaced successfully!"
    fi

    # An un-deleted instruction block is a different failure from an unfilled
    # token, and once its literal metasyntax is the only doubled-brace text left
    # the check above cannot distinguish the two. Fail on it by name.
    #
    # The strip pass, this recipe and the e2e test are excluded because they
    # necessarily NAME the marker in order to describe or assert on it — the fix
    # for the defect would otherwise be flagged by the check for the defect, and
    # so would the test that guards the fix, and the cleanup test whose
        # fixture prose must keep the phrase to prove prose is not collateral.
        # All four are tooling, not
    # community-health documents, so a mention in them cannot mislead a reader
    # about what this project's Code of Conduct says.
    LEFTOVER_BLOCKS=$(grep -rl 'TEMPLATE INSTRUCTIONS' . --exclude-dir=.git 2>/dev/null | grep -vE '^\./(scripts/strip-instruction-blocks\.rs|build/just/repo-init\.just|tests/e2e/template_instantiation_test\.sh|tests/workflows/mint_cleanup_test\.sh)$' || true)
    if [ -n "$LEFTOVER_BLOCKS" ]; then
        echo ""
        echo "Un-deleted TEMPLATE INSTRUCTIONS block in:"
        echo "$LEFTOVER_BLOCKS" | sed 's/^/  /'
        echo "ERROR: the instruction-block pass should have removed these."
        exit 1
    fi

    # ── www/ site-operations bundle (issue #53, stage 5) ──────────────────
    #
    # A repository minted from this template already carries www/.well-known/
    # as the canonical location and has no root .well-known/, so in the
    # ordinary case both steps below do nothing at all. They exist for the
    # case that is not ordinary: repo-init run over a tree that predates #53
    # and still has a root .well-known/. The migrator moves it — quarantining
    # anything divergent rather than overwriting it — and the bundle's own
    # suite then proves the result.
    #
    # #106 described this wiring as already present. It was not: nothing
    # invoked the migrator or the suite at mint, which is why the estate
    # still carries root .well-known/ directories years into the convention.
    if [ -d .well-known ] && [ -f scripts/migrate-wellknown-to-www.sh ]; then
        echo ""
        echo "Migrating legacy root .well-known/ into www/.well-known/..."
        bash scripts/migrate-wellknown-to-www.sh
    fi

    # Fail-closed, like `just verify` below: the suite tolerates unminted
    # double-brace placeholder tokens by design (it runs in the template
    # itself), no archetype overlay touches www/, and the substituted Expires
    # value is a parseable end-of-mint-year timestamp — so a failure here is
    # real. (Spelled out in words because just interpolates double braces
    # anywhere in a recipe, comments included, and an undefined variable here
    # takes the whole Justfile down, not just this recipe.)
    if [ -f www/tests/run-all.sh ]; then
        echo ""
        echo "Running www/ site-operations suite..."
        bash www/tests/run-all.sh
    fi

    # K9-SVC validation (if available)
    if command -v k9-svc >/dev/null 2>&1; then
        echo ""
        echo "Running k9-svc validation..."
        k9-svc validate . 2>/dev/null || true
    fi

    echo ""
    echo "Running OpenSSF compliance verification..."
    just verify

    echo ""
    echo "Done! Mint complete. Remaining Forge stages (ADR-0003):"
    echo "  1. Review changes: git diff"
    echo "  2. Remove template cruft: rm .machine_readable/ai/PLACEHOLDERS.adoc"
    echo "  3. Customize README.adoc; then: grep -rn UNASSIGNED . for what still needs you"
    echo "  4. PROVISION — actually run your build and test commands and watch"
    echo "     them pass (echoed advice is not provisioning)."
    echo "  5. Commit: git add -A && git commit -m 'feat: initialize from RSR template'"
    echo "  6. Push: git remote add origin git@${FORGE}:${OWNER}/${REPO}.git && git push -u origin main"
    echo "  7. CONFIGURE — out of band, once (this recipe runs no gh commands):"
    echo "       gh repo edit ${OWNER}/${REPO} --description '<one line>' --homepage '${WEBSITE}'"
    echo "     Visibility is fail-closed private; flip deliberately if wanted:"
    echo "       gh repo edit ${OWNER}/${REPO} --visibility public --accept-visibility-change-consequences"
    echo "     Register in gv-clade-index; required contexts must equal emitted job ids."
    if [ -f ci/.gitlab-ci.yml ]; then
        echo ""
        echo "     GitLab mirror only: this repo keeps its GitLab CI config at"
        echo "     ci/.gitlab-ci.yml, which GitLab does NOT look for by default."
        echo "     Settings > CI/CD > General pipelines > CI/CD configuration file"
        echo "     must be set to ci/.gitlab-ci.yml, or GitLab CI silently never"
        echo "     runs - no pipeline and no error. See ci/README.adoc."
    fi
    echo "  8. HARNESS — arm the drift gate against your recorded parent-pin:"
    echo "       scripts/check-variant-drift.sh <parent-checkout-dir>"
