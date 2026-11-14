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

    # The mint edits only what belongs to the repository, so it needs git to
    # say what that is (see mint_files below). Checked first: nothing is
    # asked, fetched or written for a tree that cannot be minted.
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Error: repo-init must run inside a git work tree (run 'git init' first)."
        exit 1
    fi
    # The mint runs git against other repositories too (replays, a template
    # clone, the tests it runs in scratch repositories), and an inherited
    # repository location (GIT_DIR, GIT_INDEX_FILE, … from a hook or another git
    # caller) would redirect every one of them into this repository: the
    # replay's commits, the tests' fixture commits (CodeRabbit review of #275).
    # So the location is cleared, once, here, for this recipe and everything it
    # starts; one that named a different repository than this work tree's own
    # is refused, since clearing it would mint something else.
    _git_loc=(GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
              GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE)
    _git_set=""; for _v in "${_git_loc[@]}"; do [ -z "${!_v+x}" ] || _git_set="${_git_set} ${_v}"; done
    if [ -n "$_git_set" ]; then
        _here_gd="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
        _bare_gd="$(cd "$(git rev-parse --show-toplevel)" && env $(printf -- '-u %s ' "${_git_loc[@]}") git rev-parse --absolute-git-dir 2>/dev/null || true)"
        if [ -z "$_bare_gd" ] || [ "$_here_gd" != "$_bare_gd" ]; then
            echo "Error: mint aborted before writing anything — git location variables are set"
            echo "      (${_git_set# }) and name a repository other than this work tree's own."
            echo "      Run repo-init from the repository's work tree without them."
            exit 1
        fi
        unset "${_git_loc[@]}"
    fi

    # --- The template's own identity ---------------------------------------
    # repo-init is carried into every minted repo UNCHANGED (it is listed in
    # .machine_readable/mint-verbatim.txt: it is the generator, not generated
    # content), so it cannot assume it is running in rsr-template-repo. By the
    # second generation the deed on disk is <parent>_chora.deed, the literal to
    # rewrite is <parent>, and the provenance parent is <parent-owner>/<parent>.
    # Hardcoding the original template made a mint from a minted repo rename
    # nothing, rewrite nothing, and abort at the identity step. Measured on
    # metadatastician/lintel 2026-10-19; first fixed there in lintel#9 (not
    # merged), ported here, where the generator lives.
    #
    # Derived, never guessed: these are facts about the checkout, not choices.
    # The root Justfile's OWNER/REPO lines are the literals written through the
    # tree, so they are exactly what the rewrite has to match, and they are
    # still the TEMPLATE's in a repository created with "Use this template".
    # When the Justfile does not declare them, RSR_TEMPLATE_SLUG=owner/repo
    # must say so, or the mint stops. There is deliberately no fallback to the
    # git remote: in a template-created child the remote is the CHILD, so that
    # fallback named the child as its own template, and the pin resolver then
    # recorded the child's HEAD (Codex review of #251). Nor is there a default
    # template name: a guess here is the hardcoding this block replaced.
    TEMPLATE_OWNER=""
    TEMPLATE_REPO=""
    if [ -f Justfile ]; then
        TEMPLATE_REPO="$(sed -n -E "s/^(export[[:space:]]+)?REPO[[:space:]]*:=[[:space:]]*[\"']([^\"']+)[\"'].*/\2/p" Justfile | head -1)"
        TEMPLATE_OWNER="$(sed -n -E "s/^(export[[:space:]]+)?OWNER[[:space:]]*:=[[:space:]]*[\"']([^\"']+)[\"'].*/\2/p" Justfile | head -1)"
    fi
    if [ -z "$TEMPLATE_REPO" ] || [ -z "$TEMPLATE_OWNER" ]; then
        if [[ "${RSR_TEMPLATE_SLUG:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
            TEMPLATE_OWNER="${RSR_TEMPLATE_SLUG%%/*}"
            TEMPLATE_REPO="${RSR_TEMPLATE_SLUG#*/}"
        else
            echo "Error: the root Justfile does not declare OWNER := and REPO :=, so the"
            echo "       template this tree came from is unknown. Set RSR_TEMPLATE_SLUG=owner/repo."
            exit 1
        fi
    fi
    TEMPLATE_SLUG="${TEMPLATE_OWNER}/${TEMPLATE_REPO}"

    # --- A template is minted; a minted repo is minted as a chain ------------
    # A minted repo has already filled its tokens and deleted build/templates,
    # so minting it like a template renders none of the new answers and skips
    # the identity splice: the grandchild silently inherited its parent's
    # author, contacts, clade and maturity (Codex review of #251). So it is
    # never minted that way: it is chain-minted, or refused, before anything is
    # asked or written. A variant template keeps build/templates and still mints.
    #
    # Chain minting (owner ruling 2026-11-04): a minted repo that recorded its
    # (mint-answers) CAN be minted again. scripts/chain-mint.sh replays its
    # mint, mints the same template commit with the new answers, and carries
    # its own work across by a three-way merge. One minted before answers were
    # recorded cannot be replayed, so it is still refused.
    #
    # Which it is, the deed's recorded mint state decides first: a template
    # (or a variant template, which is maintained, never minted) records no
    # (mint-answers). A minted repo that added build/templates/identity.deed.in
    # back as its own work is still a minted repo (Codex review of #277).
    # The recorded state alone decides; the chain script's presence does not:
    # a minted repo that deleted scripts/chain-mint.sh is still minted, and
    # minting it as a template would keep its author and contacts (Codex
    # review of #277). It is refused instead.
    CHAIN_MINT=0
    _prov_deed="$(bash scripts/deed-field.sh --find . 2>/dev/null || true)"
    if [ -n "$_prov_deed" ] && bash scripts/deed-field.sh --has "$_prov_deed" mint-answers \
       && [ ! -f scripts/chain-mint.sh ]; then
        echo "Error: this tree is a minted repo (its deed records (mint-answers)), but"
        echo "       scripts/chain-mint.sh, which mints a minted repo again, is absent."
        echo "       Restore it from the template, or mint from the template itself."
        exit 1
    elif [ -n "$_prov_deed" ] && bash scripts/deed-field.sh --has "$_prov_deed" mint-answers; then
        CHAIN_MINT=1
        echo "This tree is a minted repo (${TEMPLATE_SLUG}): it will be minted as a chain,"
        echo "from its template, carrying its own work since its mint."
        echo ""
    elif [ ! -f build/templates/identity.deed.in ]; then
        echo "Error: this tree has already been minted (build/templates/identity.deed.in is"
        echo "       absent) and records no (mint-answers), so its mint cannot be replayed"
        echo "       and it cannot be minted again. Mint from the template it came from."
        if [ -n "$_prov_deed" ]; then
            _prov_from="$(bash scripts/deed-field.sh "$_prov_deed" provenance template-repo 2>/dev/null || true)"
            [ -z "$_prov_from" ] || echo "       This tree records its template as ${_prov_from}."
        fi
        exit 1
    fi

    # --- What the mint may edit ---------------------------------------------
    # mint_files prints, one per line, every regular file that belongs to the
    # repository: tracked, or untracked and not ignored (what `git add -A`
    # would commit), minus the files .machine_readable/mint-verbatim.txt says
    # the mint carries unchanged. Every rewrite pass and every completeness
    # check below reads this list, and nothing else.
    #
    # The passes used to `find .` the whole directory. That walked git-ignored
    # caches: minting lintel, the instruction-block pass edited the pinned
    # sibling checkouts under _build/dependencies/, which broke those pins. It
    # also rewrote template machinery whose fixtures must keep the template's
    # literal name, so tests/workflows/self_name_pass_test.sh failed in the
    # child, and stripped the very fixture blocks the leftover check below
    # exempts. "Untracked and not ignored" is included so that a copy which
    # was never committed (tests/e2e/template_instantiation_test.sh) still
    # mints; in a repository created from the template every file is tracked.
    #
    # Paths are printed relative and without "./"; symlinks are skipped, as
    # `find -type f` skipped them.
    VERBATIM_LIST=".machine_readable/mint-verbatim.txt"
    [ -f "$VERBATIM_LIST" ] || { echo "Error: $VERBATIM_LIST is missing; the mint cannot tell machinery from content."; exit 1; }
    mapfile -t MINT_VERBATIM < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$VERBATIM_LIST" | grep -v '^$')
    # These two preflights judge a TEMPLATE tree. A chain mint's tree is a
    # minted repo whose own work (a deleted verbatim-listed file, an added file
    # with a brace token) is the parent's business; the root template is
    # checked when chain-mint.sh replays it, and the merged result passes the
    # placeholder gate (Codex review of #277).
    if [ "$CHAIN_MINT" != "1" ]; then
        for _v in "${MINT_VERBATIM[@]}"; do
            [ -f "$_v" ] || { echo "Error: $VERBATIM_LIST names $_v, which does not exist (stale entry)."; exit 1; }
        done
    fi

    # ── Can the template be minted at all? ──────────────────────────────────
    # A brace token the recipe below has no answer for is a file that cannot be
    # minted: it either survives into the child as a literal (measured: five
    # files in every Julia repo minted before 2026-10-30) or trips the
    # placeholder gate at the END of a mint that has already written the tree.
    # Both are cheaper to refuse here, before a single byte is written.
    if [ "$CHAIN_MINT" != "1" ] && [ -f scripts/check-mint-tokens.sh ]; then
        if ! bash scripts/check-mint-tokens.sh; then
            echo "ERROR: mint aborted before writing anything — the template ships a"
            echo "       token this recipe cannot fill. See the findings above."
            exit 1
        fi
    fi

    # ── Are the tools the mint needs LATER present? ─────────────────────────
    # The mint writes the tree first and reaches a KYAML-capable yq
    # (format-container-kyaml.sh) and nickel (the arrival pack) afterwards; a
    # missing one used to stop it after 100+ files were rewritten. Every mint
    # kind (plain, archetype, chain) reaches both steps, so none is exempt;
    # the script demands a tool only when its step can run (see its header).
    [ -f scripts/check-mint-tools.sh ] \
        || { echo "Error: scripts/check-mint-tools.sh is missing; the mint cannot check its tools."; exit 1; }
    bash scripts/check-mint-tools.sh . || exit 1
    mint_files() {
        git ls-files -z --cached --others --exclude-standard \
            | while IFS= read -r -d '' _f; do
                [ -f "$_f" ] && [ ! -L "$_f" ] || continue
                printf '%s\n' "$_f"
            done \
            | grep -vxF -f <(printf '%s\n' "${MINT_VERBATIM[@]}") \
            | sort -u || true
    }

    echo "═══════════════════════════════════════════════════"
    echo "  RSR Project Bootstrap"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # --- Archetype overlay data (ADR-0003) ---
    ARCHETYPE='{{archetype}}'
    ARCH_FILE=""
    ARCH_PRESET=""
    # A chain mint has no archetypes/ (the parent's mint removed it); it
    # re-mints with the archetype the parent recorded, from the root template
    # (scripts/chain-mint.sh). Naming that same archetype is accepted; any
    # other is refused, since the parent's tree was built for its own.
    # MINT_ARCH is the archetype the mint will actually apply: on a chain, the
    # parent's, whether or not it was named (the slug rule below depends on it:
    # a Julia package's <Name>.jl slug).
    MINT_ARCH="$ARCHETYPE"
    if [ "$CHAIN_MINT" = "1" ]; then
        _p_arch="$(bash scripts/deed-field.sh "$_prov_deed" mint-answers archetype 2>/dev/null || true)"
        if [ -n "$ARCHETYPE" ] && [ "$ARCHETYPE" != "$_p_arch" ]; then
            echo "Error: this tree was minted as archetype '${_p_arch:-none}'; a chain mint keeps it."
            echo "       Run just repo-init${_p_arch:+ ${_p_arch}} (or mint from the template for another)."
            exit 1
        fi
        [ -z "$_p_arch" ] || { echo "Archetype: ${_p_arch} (the parent's, re-minted from the template)"; echo ""; }
        MINT_ARCH="$_p_arch"
        ARCHETYPE=""
    elif [ -n "$ARCHETYPE" ]; then
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
    if [[ "$MINT_ARCH" = "julia-library" && "$REPO" =~ ^[A-Z][A-Za-z0-9]*\.jl$ ]]; then
        :
    elif [[ ! "$REPO" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
        echo "Error: repo slug must be lowercase alphanumeric words separated by single hyphens"
        [ "$MINT_ARCH" = "julia-library" ] && echo "       (or, for a Julia package, <Name>.jl with <Name> in UpperCamelCase)"
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
    # Derive the default for a DNS hostname and bare TOML service key, not
    # only an OCI image name: Julia dots and slug underscores need hyphens.
    # Explicit service answers still go through the validator unchanged.
    DEFAULT_SERVICE_NAME="${REPO,,}"
    DEFAULT_SERVICE_NAME="${DEFAULT_SERVICE_NAME//[._]/-}"
    if [ -d "build/container" ]; then
        echo ""
        echo "── Container configuration (optional) ─────────"
        ask "Service name [${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}]: " _SERVICE_NAME
        SERVICE_NAME="${_SERVICE_NAME:-${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}}"
        ask "Primary port [${PORT:-8080}]: " _PORT
        PORT="${_PORT:-${PORT:-8080}}"
        ask "Container registry [${REGISTRY:-ghcr.io/${OWNER,,}}]: " _REGISTRY
        REGISTRY="${_REGISTRY:-${REGISTRY:-ghcr.io/${OWNER,,}}}"
        # The values fill double-quoted KYAML scalars: refuse a value that
        # would break them now, before anything is written.
        bash scripts/format-container-kyaml.sh --check-values "$SERVICE_NAME" "$PORT" "$REGISTRY" \
            || { echo "ERROR: mint aborted before writing anything — see above."; exit 1; }
    else
        SERVICE_NAME="${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"
        PORT="${PORT:-8080}"
        REGISTRY="${REGISTRY:-ghcr.io/${OWNER,,}}"
    fi

    # --- Derived values ---
    # The PROJECT and project tokens land in identifiers (Zig, Idris, C macros),
    # so every character an identifier cannot hold maps to an underscore: the
    # hyphens of a slug and the dot of a Julia slug alike.
    PROJECT_UPPER=$(echo "$REPO" | tr '[:lower:]-.' '[:upper:]__')
    PROJECT_LOWER=$(echo "$REPO" | tr '[:upper:]-.' '[:lower:]__')
    # The mint date is an input like any answer: RSR_MINT_DATE replays a mint
    # exactly (scripts/check-mint-drift.sh re-mints a child with the date it
    # recorded). Otherwise it is today. The year always follows the date.
    CURRENT_DATE="${RSR_MINT_DATE:-$(date +%Y-%m-%d)}"
    # Validated in bash, not with `date -d`: that is GNU-only, and macOS's date
    # rejected every date, today's included (Codex review of #275).
    _dm=0
    if [[ "$CURRENT_DATE" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
        _yy=$((10#${BASH_REMATCH[1]})); _mm=$((10#${BASH_REMATCH[2]})); _dd=$((10#${BASH_REMATCH[3]}))
        case "$_mm" in
            1|3|5|7|8|10|12) _dm=31 ;;
            4|6|9|11) _dm=30 ;;
            2) if (( (_yy % 4 == 0 && _yy % 100 != 0) || _yy % 400 == 0 )); then _dm=29; else _dm=28; fi ;;
        esac
    fi
    if [ "$_dm" -eq 0 ] || [ "${_dd:-0}" -lt 1 ] || [ "${_dd:-0}" -gt "$_dm" ]; then
        echo "Error: RSR_MINT_DATE must be a real date, YYYY-MM-DD (got '${CURRENT_DATE}')."
        exit 1
    fi
    CURRENT_YEAR="${CURRENT_DATE:0:4}"
    VERSION="0.1.0"

    # --- Mint the repo's chora id ----------------------------------------
    # The chora id is minted ONCE, here, from the repo's birth path, and is
    # carried opaquely as :repo-uuid #uuid"<id>" (standards A1 rules U1 to U4
    # and V8, A7 J11). It is the ADR-008 profile C UUIDv8 of the birth path in
    # the domain chora-registry (owner ruling V9, 2026-11-13: new ids only; ids
    # minted earlier keep their gv-clade-index id and are never reminted):
    #     first 16 bytes of SHA-256("chora-registry:<forge>/<owner>/<name>"),
    #     version 8, variant 10
    # (scripts/uuid-v8.sh, equal to standards scripts/uuid-v8.js c, tested by
    # tests/workflows/uuid_v8_test.sh). It is computed the same way on every
    # machine, so the drift gate's replay agrees with the mint. Nothing
    # re-derives it later: a transfer or rename never changes it (U1).
    REPO_UUID="$(bash scripts/uuid-v8.sh chora-registry "${FORGE}/${OWNER}/${REPO}")" || {
        echo "Error: the repo id is minted as a UUIDv8 (SHA-256), and this machine"
        echo "       has none of sha256sum, shasum or openssl to mint it with."
        exit 1
    }

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

    # An answer is one line: no sed expression, deed string or prompt can carry
    # a newline. Refused HERE, before the first write (the overlay, the prune
    # and the docs seed all come next), so a bad answer leaves a clean tree.
    for _ans in PROJECT_NAME PROJECT_DESCRIPTION OWNER AUTHOR AUTHOR_EMAIL AUTHOR_ORG \
                AUTHOR_LAST AUTHOR_FIRST FORGE SECURITY_EMAIL CONDUCT_EMAIL PROJECT_TYPE \
                WEBSITE SERVICE_NAME PORT REGISTRY AUTHOR_EMAIL_ALT AUTHOR_ORCID OPENSSF_BP_ID; do
        case "${!_ans:-}" in
            *$'\n'*) echo "Error: the answer for $_ans contains a newline; answers are one line."; exit 1 ;;
            # 0x01 is the record separator deed-field.sh and deed-clause.sh read the
            # deed with: an answer holding it renders everywhere, then cannot be
            # recorded in (mint-answers) (Codex review of #275).
            *$'\001'*) echo "Error: the answer for $_ans contains byte 0x01, which the deed cannot record."; exit 1 ;;
        esac
    done

    # Answers are free text, and the right-hand side of s|…|…| is not: `&`
    # inserts the matched token, `\` escapes, `|` ends the expression. A
    # description "Tools & proofs" rendered as "Tools <the token> proofs" and
    # then failed the placeholder gate; a `|` broke the substitution. Every
    # answer goes through sed_rhs. (A newline was refused before the first write.)
    # Defined here, ahead of the rules below that use it.
    sed_rhs() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

    # The self-name rule, defined once: used by the self-name pass below and
    # handed to scripts/chain-mint.sh, so a chain mint renames the parent by
    # exactly the same rule (passed as data, never re-read from the recipe).
    SELF_PROV='instantiated-from|parent|upstream|chain =|lineage|minted from|created from|Template: |reject-if-contains'
    # The template's name and slug are LITERAL text, not patterns: a Julia
    # mint's parent may be <Name>.jl, and `.` in a sed pattern matches any
    # character. Escaped inline so self_name_pass_test.sh can evaluate this
    # one assignment exactly as the recipe defines it.
    # The name is matched only where it stands as a whole name: not inside
    # a longer word or slug (Codex review of #251). Unbounded, a parent
    # named `app` turned "application mapping" into "newlication mnewing".
    # A neighbouring letter or digit blocks the match; anything else does
    # not, so `<owner>_<name>` (sonar.projectKey), `<name>_chora.deed` and
    # derived names such as `<name>-checkout` or `rm-<name>` still follow. Each pass
    # loops (:label … t label) because a match consumes its right-hand
    # neighbour, and marks through a sentinel so a new name that contains
    # the old one (Geometry -> Geometry.jl) cannot loop forever.
    SELF_NAME_SED="/${SELF_PROV}/!{:i;s@(^|[^A-Za-z0-9])${TEMPLATE_REPO//./\\.}#([0-9])@\\1\\x01I\\x01\\2@;ti;:s;s@(^|[^A-Za-z0-9])${TEMPLATE_SLUG//./\\.}([^A-Za-z0-9]|$)@\\1\\x01S\\x01\\2@;ts;:n;s@(^|[^A-Za-z0-9])${TEMPLATE_REPO//./\\.}([^A-Za-z0-9]|$)@\\1\\x01N\\x01\\2@;tn;s@\\x01S\\x01@${OWNER}/${REPO}@g;s@\\x01N\\x01@${REPO}@g;s@\\x01I\\x01@${TEMPLATE_REPO}#@g;}"
    # The self-owner rule, defined once likewise (see the self-OWNER pass for
    # why it is three exact identity lines and never a blanket rewrite): the
    # Justfile OWNER declaration in each form the identity parser accepts, and
    # the SonarCloud organization and project key. chain-mint.sh applies it to
    # the parent's carried files too (Codex review of #277).
    SELF_OWNER_SED="s|^((export[[:space:]]+)?OWNER[[:space:]]*:=[[:space:]]*)([\"'])${TEMPLATE_OWNER//./\\.}([\"'])|\\1\\3$(sed_rhs "${OWNER}")\\4|;s|^sonar\\.organization=${TEMPLATE_OWNER//./\\.}\$|sonar.organization=$(sed_rhs "${OWNER}")|;s|^sonar\\.projectKey=${TEMPLATE_OWNER//./\\.}_|sonar.projectKey=$(sed_rhs "${OWNER}")_|"

    # Chain mint: everything below renders a TEMPLATE tree, which this is not.
    # chain-mint.sh renders the template afresh with these answers and carries
    # this tree's own work across; it writes nothing unless it succeeds.
    if [ "$CHAIN_MINT" = "1" ]; then
        export PROJECT_NAME REPO OWNER AUTHOR AUTHOR_EMAIL AUTHOR_ORG AUTHOR_EMAIL_ALT \
               AUTHOR_ORCID PROJECT_DESCRIPTION FORGE SECURITY_EMAIL CONDUCT_EMAIL \
               PROJECT_TYPE WEBSITE OPENSSF_BP_ID SERVICE_NAME PORT REGISTRY \
               TEMPLATE_REPO TEMPLATE_OWNER
        export RSR_MINT_DATE="$CURRENT_DATE" SELF_NAME_SED SELF_OWNER_SED
        bash scripts/chain-mint.sh
        echo ""
        echo "Done! Chain mint complete. Review with git status, then commit."
        exit 0
    fi

    # Template-only paths this recipe deletes, as they stand before it runs.
    # Recorded in the (variant) clause's (paths :removed …) below, so the
    # record says what the mint took away instead of leaving the drift gate to
    # report each file as an undeclared removal (18 lines on a fresh mint).
    MINT_REMOVES=()
    for _d in archetypes build/docs-seed build/templates; do
        [ -d "$_d" ] && MINT_REMOVES+=("$_d/")
    done

    # --- Which template commit is in hand (provenance) ---------------------
    # Resolved BEFORE anything is written, so an unresolvable parent stops the
    # mint with the tree untouched instead of half-minted. The child's own HEAD
    # is never recorded as the template's: in a repository created with "Use
    # this template" it is a commit of the child (lintel recorded its own
    # claude/mint-lintel tip, 2026-10-14). scripts/resolve-template-pin.sh owns
    # the rule and says why; tests/workflows/resolve_template_pin_test.sh
    # holds its controls.
    #   RSR_TEMPLATE_URL     read the template's history from here instead
    #   RSR_TEMPLATE_COMMIT  assert the template commit (verified to exist)
    #   RSR_ALLOW_UNPINNED=1 record UNASSIGNED instead of aborting (offline)
    PIN_ARGS=(--slug "$TEMPLATE_SLUG")
    [ -z "${RSR_TEMPLATE_URL:-}" ] || PIN_ARGS+=(--url "$RSR_TEMPLATE_URL")
    [ -z "${RSR_TEMPLATE_COMMIT:-}" ] || PIN_ARGS+=(--commit "$RSR_TEMPLATE_COMMIT")
    if PIN_OUT="$(bash scripts/resolve-template-pin.sh "${PIN_ARGS[@]}")"; then
        PARENT_BRANCH="$(sed -n 's/^branch=//p' <<<"$PIN_OUT")"
        PARENT_PIN="$(sed -n 's/^commit=//p' <<<"$PIN_OUT")"
        PARENT_TREE="$(sed -n 's/^tree=//p' <<<"$PIN_OUT")"
        echo "Template: ${TEMPLATE_SLUG}@${PARENT_PIN:0:12} ($(sed -n 's/^source=//p' <<<"$PIN_OUT"))"
    elif [ "${RSR_ALLOW_UNPINNED:-0}" = "1" ]; then
        PARENT_BRANCH=UNASSIGNED PARENT_PIN=UNASSIGNED PARENT_TREE=UNASSIGNED
        echo "WARNING: template commit UNASSIGNED (RSR_ALLOW_UNPINNED=1)."
        echo "         scripts/check-template-conformance.sh fails until it is filled."
    else
        echo "ERROR: mint aborted before writing anything — the template commit this"
        echo "       tree came from cannot be named (reason above). Re-run with"
        echo "       RSR_ALLOW_UNPINNED=1 only if an unpinned mint is genuinely wanted."
        exit 1
    fi

    # --- What this work tree holds beyond the pinned tree -------------------
    # The mint transforms the work tree as it stands; the drift gate replays
    # from the pinned tree alone. Anything already changed here before the
    # mint (an edit, an untracked file, a deletion) is this repo's own, not
    # the mint's, so it is measured now and declared in (variant (paths)):
    # the replay stays exact and the record says what happened (Codex review
    # of #275). Measured in a scratch index and object store, so .git is not
    # written. (A chain mint carries its parent's tree by its own rules.)
    PREMINT_A=() PREMINT_M=() PREMINT_D=()
    if [ "${CHAIN_MINT:-0}" != "1" ] && [ "$PARENT_TREE" != "UNASSIGNED" ]; then
        # The work tree as `git add -A` would commit it, from the current index
        # (so a tracked file an ignore rule matches stays), in a scratch index
        # and object store.
        _pm="$(mktemp -d)"; mkdir -p "$_pm/objects"
        _gd="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
        _ix="$(git rev-parse --git-path index)"
        [ ! -f "$_ix" ] || cp "$_ix" "$_pm/index"
        _wt() { GIT_INDEX_FILE="$_pm/index" GIT_OBJECT_DIRECTORY="$_pm/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$_gd/objects" git "$@"; }
        _wt add -A .
        # A gitlink (submodule) cannot be replayed (checkout-index writes no files
        # for one), so the drift gate could never pass: refused by name here,
        # whether or not anything else changed (Codex review of #275).
        _gl="$(_wt ls-files -s | awk -F '\t' '$1 ~ /^160000 / { print "         " $2 }')"
        if [ -n "$_gl" ]; then
            echo "ERROR: mint aborted before writing anything — this tree carries a submodule"
            echo "       (gitlink), which a replay of the mint cannot reproduce, so its drift gate"
            echo "       could never pass. Minting such a tree is not supported:"
            printf '%s\n' "$_gl"
            rm -rf "$_pm"; exit 1
        fi
        if git cat-file -e "${PARENT_TREE}^{tree}" 2>/dev/null; then
            while IFS= read -r -d '' _st && IFS= read -r -d '' _p; do
                # A newline splits the deed's line-based lists; byte 0x01 is the deed
                # reader's record separator (Codex review of #277).
                case "$_p" in *$'\n'*|*$'\001'*) echo "Error: a path holding a newline or byte 0x01 cannot be declared: $(printf '%q' "$_p")"; rm -rf "$_pm"; exit 1 ;; esac
                case "$_st" in
                    A) PREMINT_A+=("$_p") ;;
                    D) PREMINT_D+=("$_p") ;;
                    *) PREMINT_M+=("$_p") ;;
                esac
            done < <(_wt diff --cached -z --no-renames --name-status "$PARENT_TREE")
        elif [ "$(_wt write-tree)" != "$PARENT_TREE" ]; then
            # An asserted pin (RSR_TEMPLATE_COMMIT) whose tree this repository
            # does not hold: the difference cannot even be listed, so it cannot
            # be declared, and the replay would report it (Codex review of #275).
            rm -rf "$_pm"
            echo "ERROR: mint aborted before writing anything — this work tree differs from the"
            echo "       template tree ${PARENT_TREE:0:12}, which this repository does not hold, so"
            echo "       the difference cannot be declared. Fetch it first"
            echo "       (git fetch <template-url> ${PARENT_PIN}) or mint from a matching tree."
            exit 1
        fi
        # The work tree's own tree: what a dry run of this mint starts from
        # (below). Its objects stay in $_pm until the replays are done.
        _WT_TREE="$(_wt write-tree)"
        # The mint moves a root .well-known/ (the www/ migration, below), so a
        # path there could not be declared where it ends up: refused by name.
        for _p in "${PREMINT_A[@]}" "${PREMINT_M[@]}" "${PREMINT_D[@]}"; do
            case "$_p" in
                .well-known/*)
                    echo "ERROR: mint aborted before writing anything — $_p changed before the mint,"
                    echo "       and the mint moves .well-known/ into www/.well-known/. Commit that move"
                    echo "       first (bash scripts/migrate-wellknown-to-www.sh), or revert the change."
                    rm -rf "$_pm"; exit 1 ;;
            esac
        done
        # The mint writes new files of its own: the archetype overlay (before
        # and after its .in rename), the docs seed, the deed. A pre-mint file
        # at one of those paths would be overwritten (lost) and then declared
        # as this repo's own addition, which the replay contradicts (Codex
        # review of #275). Refused by name, before anything is written.
        _writes=("${REPO}_chora.deed")
        if [ -n "$ARCHETYPE" ] && [ -d "archetypes/${ARCHETYPE}/overlay" ]; then
            while IFS= read -r -d '' _o; do
                _o="${_o#./}"; _writes+=("$_o")
                case "$_o" in
                    src/PACKAGE.jl.in) _writes+=("src/${PROJECT_NAME}.jl") ;;
                    *.in) _writes+=("${_o%.in}") ;;
                esac
            done < <(cd "archetypes/${ARCHETYPE}/overlay" && find . -type f -print0)
        fi
        if [ -d build/docs-seed ]; then
            while IFS= read -r -d '' _o; do _writes+=("docs/${_o#./}"); done \
                < <(cd build/docs-seed && find . -type f ! -path ./README.adoc -print0)
        fi
        # An edited template file the overlay or seed replaces is lost the same way
        # (Codex review of #275: provisioning_praxis.deed under julia-library).
        for _p in "${PREMINT_A[@]}" "${PREMINT_M[@]}"; do
            for _w in "${_writes[@]}"; do
                if [ "$_p" = "$_w" ]; then
                    echo "ERROR: mint aborted before writing anything — $_p changed before the mint, and"
                    echo "       the mint writes that path itself (the archetype overlay, the docs seed or"
                    echo "       the deed), so your file would be overwritten. Move it aside, mint, then"
                    echo "       bring it back as a change of your own."
                    rm -rf "$_pm"; exit 1
                fi
            done
        done
        _n=$(( ${#PREMINT_A[@]} + ${#PREMINT_M[@]} + ${#PREMINT_D[@]} ))
        if [ "$_n" -gt 0 ]; then
            echo "NOTE: ${_n} path(s) here already differ from the template tree ${PARENT_TREE:0:12}"
            echo "      (${#PREMINT_A[@]} added, ${#PREMINT_M[@]} changed, ${#PREMINT_D[@]} removed before this mint). They are"
            echo "      this repo's own. What they change in the result is declared in"
            echo "      (variant (paths)), measured against a replay of this mint:"
            for _p in "${PREMINT_A[@]}" "${PREMINT_M[@]}" "${PREMINT_D[@]}"; do echo "        $_p"; done
        fi
    fi

    # --- The replay this mint is measured against, when the tree has changed ---
    # A pre-mint change can reach the result in ways no rule over its own path
    # predicts: the mint moves, overwrites and renders files, and reads its own
    # inputs (the overlay, the docs seed, its scripts) from this tree (Codex and
    # CodeRabbit review of #275). So this mint is replayed, here, before anything
    # is written, from the pinned tree with the same answers and date, exactly
    # as the drift gate will replay it; what this tree then differs by is
    # declared below. The pinned tree is in this repository (checked above).
    # The inner mint skips pin resolution (RSR_ALLOW_UNPINNED with no template
    # source): it writes the pin only into its deed, which is not compared.
    #
    # And a dry run: the same mint of THIS tree, pre-mint changes and all. A
    # change at a path where the dry run and the replay agree has no effect on
    # the result: the mint writes that path itself (the roadmap, mise.toml,
    # the map, the overlay, the docs seed, the deed) and the change
    # would be silently discarded. It is refused by name, before anything is
    # written (Codex review of #275), whatever writes it.
    # _same A B — identical as git records them: content, executable bit, link target.
    # As scripts/check-mint-drift.sh's same(): a link target is read with a
    # sentinel (command substitution strips trailing newlines), and the
    # executable bit is the owner's (0100), as git records it, not `-x`
    # (effective access, true as root for a group-executable file) (Codex
    # review of #275).
    _ux() { [ -n "$(find "$1" -prune -perm -0100 2>/dev/null)" ]; }
    _same() {
        if [ -L "$1" ] || [ -L "$2" ]; then
            [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1"; echo .)" = "$(readlink "$2"; echo .)" ]
            return
        fi
        { _ux "$1" && _ux "$2"; } || { ! _ux "$1" && ! _ux "$2"; } || return 1
        cmp -s "$1" "$2"
    }
    _REPLAY=""
    if [ $(( ${#PREMINT_A[@]} + ${#PREMINT_M[@]} + ${#PREMINT_D[@]} )) -gt 0 ]; then
        # _rg — git with no user or system configuration and no hooks, and no
        # inherited repository location (GIT_DIR, GIT_INDEX_FILE, … from a hook or
        # another git caller), which would redirect the replay's commits into
        # this repository (CodeRabbit review of #275). _rgi IDX — the same, on
        # the scratch index IDX and object store $_pm (the work tree's objects).
        _rgclean=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY
                  -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_PREFIX -u GIT_NAMESPACE GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
        _rgflags=(-c user.name=replay -c user.email=replay@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null)
        _rg() { "${_rgclean[@]}" git "${_rgflags[@]}" "$@"; }
        _rgi() { local _i="$1"; shift
                 "${_rgclean[@]}" GIT_INDEX_FILE="$_i" GIT_OBJECT_DIRECTORY="$_pm/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$_gd/objects" \
                     git "${_rgflags[@]}" "$@"; }
        _rp="$(mktemp -d)"; _REPLAY="$_rp/r"
        mkdir -p "$_rp/cfg"; : > "$_rp/gitconfig"
        # _mint_tree TREE DIR — TREE written into DIR as a checkout writes it
        # (checkout-index, not git archive, whose export-ignore and export-subst
        # attributes would change the tree (Codex review of #275)), committed as
        # "Use this template" commits it, then minted with this mint's answers.
        _mint_tree() {
            mkdir -p "$2"
            _rgi "$_rp/index" read-tree "$1"
            # A gitlink has no files to write, so the copy would lose it: refused
            # by name rather than replayed inexactly (Codex review of #277).
            _gl="$(_rgi "$_rp/index" ls-files -s | awk -F '\t' '$1 ~ /^160000 / { print "         " $2 }')"
            if [ -n "$_gl" ]; then
                echo "ERROR: the tree carries a submodule (gitlink), which the replay of this mint"
                echo "       cannot reproduce; minting such a tree is not supported:"
                printf '%s\n' "$_gl"
                rm -f "$_rp/index"; return 1
            fi
            _rgi "$_rp/index" checkout-index -a -f --prefix="$2/"
            rm -f "$_rp/index"
            # Forced, then checked to BE the tree: a file the tree tracks although
            # its .gitignore matches it is still copied by "Use this template"
            # (Codex and CodeRabbit review of #277).
            _rg -C "$2" init -q -b main; _rg -C "$2" add -f -A
            if [ "$(_rg -C "$2" write-tree)" != "$(_rgi "$_rp/index" rev-parse "$1^{tree}")" ]; then
                echo "ERROR: the checkout of the tree does not read back as itself (an attribute"
                echo "       rewrites a file), so this mint cannot be replayed exactly."
                return 1
            fi
            _rg -C "$2" commit -q -m "Initial commit"
            _rg -C "$2" remote add origin "git@${FORGE}:${OWNER}/${REPO}.git"
            (cd "$2" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
                ${RUSTUP_HOME:+RUSTUP_HOME="$RUSTUP_HOME"} ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} \
                ${RSR_MINT_TOOL_CACHE:+RSR_MINT_TOOL_CACHE="$RSR_MINT_TOOL_CACHE"} \
                ${RSR_TEMPLATE_SLUG:+RSR_TEMPLATE_SLUG="$RSR_TEMPLATE_SLUG"} \
                ${STANDARDS_UUID_V8_JS:+STANDARDS_UUID_V8_JS="$STANDARDS_UUID_V8_JS"} \
                XDG_CONFIG_HOME="$_rp/cfg" GIT_CONFIG_GLOBAL="$_rp/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
                RSR_NON_INTERACTIVE=1 RSR_MINT_REPLAY=1 RSR_ALLOW_UNPINNED=1 \
                RSR_TEMPLATE_URL="$_rp/no-template-source" RSR_MINT_DATE="$CURRENT_DATE" \
                PROJECT_NAME="$PROJECT_NAME" REPO="$REPO" OWNER="$OWNER" AUTHOR="$AUTHOR" \
                AUTHOR_EMAIL="$AUTHOR_EMAIL" AUTHOR_ORG="${AUTHOR_ORG:-}" AUTHOR_EMAIL_ALT="${AUTHOR_EMAIL_ALT:-}" \
                AUTHOR_ORCID="${AUTHOR_ORCID:-}" PROJECT_DESCRIPTION="${PROJECT_DESCRIPTION:-}" FORGE="$FORGE" \
                SECURITY_EMAIL="${SECURITY_EMAIL:-}" CONDUCT_EMAIL="${CONDUCT_EMAIL:-}" \
                PROJECT_TYPE="${PROJECT_TYPE:-}" WEBSITE="${WEBSITE:-}" OPENSSF_BP_ID="${OPENSSF_BP_ID:-}" \
                SERVICE_NAME="${SERVICE_NAME:-}" PORT="${PORT:-}" REGISTRY="${REGISTRY:-}" \
                just repo-init ${ARCHETYPE:+"$ARCHETYPE"} </dev/null) > "$2.log" 2>&1 \
                || { tail -n 30 "$2.log"; return 1; }
        }
        echo "  replaying this mint from the template tree, to measure the pre-mint changes..."
        if ! _mint_tree "$PARENT_TREE" "$_REPLAY"; then
            echo "ERROR: mint aborted before writing anything — the replay of this mint, needed to"
            echo "       measure the pre-mint changes above, failed (its log is above)."
            rm -rf "$_pm"; exit 1
        fi
        echo "  and a dry run of it on this tree, to find a change the mint would discard..."
        if ! _mint_tree "$_WT_TREE" "$_rp/dry"; then
            echo "ERROR: mint aborted before writing anything — a dry run of this mint on this"
            echo "       tree failed (its log is above): a pre-mint change breaks the mint."
            rm -rf "$_pm"; exit 1
        fi
        _lost=()
        _here() { [ -e "$1" ] || [ -L "$1" ]; }
        # _result_tree DIR — the mint result in DIR, as the tree git would commit.
        _result_tree() { _rg -C "$1" add -A >/dev/null && _rg -C "$1" write-tree; }
        _DRY_T=""
        _n=0
        for _p in "${PREMINT_A[@]}" "${PREMINT_M[@]}" "${PREMINT_D[@]}"; do
            if _here "$_rp/dry/$_p" && _here "$_REPLAY/$_p"; then
                if _same "$_rp/dry/$_p" "$_REPLAY/$_p"; then _lost+=("$_p"); fi
            elif ! _here "$_rp/dry/$_p" && ! _here "$_REPLAY/$_p" \
                 && { _wt ls-files --error-unmatch -- ":(literal)$_p" >/dev/null 2>&1; }; then
                # Added or changed here, and gone from both results: an input
                # the mint reads and deletes (the docs seed, the overlay), or a
                # file in a directory it deletes. Its change had an effect only if
                # the result differs without it: this mint, minus that one change,
                # is minted again and compared whole (Codex review of #275: an
                # edit to build/docs-seed/README.adoc, which is never copied,
                # was destroyed without a trace).
                [ -n "$_DRY_T" ] || _DRY_T="$(_result_tree "$_rp/dry")"
                _n=$((_n + 1))
                _rgi "$_rp/index" read-tree "$_WT_TREE"
                if _rgi "$_rp/index" cat-file -e "${PARENT_TREE}:$_p" 2>/dev/null; then
                    read -r _m _ _s _ <<<"$(_rgi "$_rp/index" ls-tree "$PARENT_TREE" -- "$_p")"
                    _rgi "$_rp/index" update-index --add --cacheinfo "$_m,$_s,$_p"
                else
                    _rgi "$_rp/index" update-index --force-remove -- "$_p"
                fi
                _rev_t="$(_rgi "$_rp/index" write-tree)"; rm -f "$_rp/index"
                echo "  checking that the pre-mint change to $_p has an effect..."
                if ! _mint_tree "$_rev_t" "$_rp/without.$_n"; then
                    echo "ERROR: mint aborted before writing anything — a dry run without the change"
                    echo "       to $_p failed (its log is above)."
                    rm -rf "$_pm"; exit 1
                fi
                if [ "$(_result_tree "$_rp/without.$_n")" = "$_DRY_T" ]; then _lost+=("$_p"); fi
            fi
        done
        rm -rf "$_pm"
        if [ "${#_lost[@]}" -gt 0 ]; then
            echo "ERROR: mint aborted before writing anything — these paths changed before the mint,"
            echo "       and the mint writes or deletes each itself, so the change would be discarded:"
            for _p in "${_lost[@]}"; do echo "         $_p"; done
            echo "       Revert them (or move them aside), mint, then make the change again."
            exit 1
        fi
    elif [ -n "${_pm:-}" ]; then
        rm -rf "$_pm"
    fi

    echo ""
    echo "Replacing placeholders..."

    # Apply archetype overlay files (if any) BEFORE substitution, so overlay
    # files are rendered along with the rest of the tree.
    #
    # The overlay's file list is recorded first: the .in rename below must touch
    # ONLY the files this archetype added. The spine ships .in templates of its
    # own (build/templates/, the k9 examples) whose .in suffix is meaningful and
    # must survive, and a blanket `find . -name '*.in' -exec mv` would rename
    # them into broken files.
    OVERLAY_FILES=()
    if [ -n "$ARCHETYPE" ] && [ -d "archetypes/${ARCHETYPE}/overlay" ]; then
        mapfile -t OVERLAY_FILES < <(
            cd "archetypes/${ARCHETYPE}/overlay" && find . -type f ! -name '*.orig' \
                | sed 's|^\./||' | sort
        )
        cp -a "archetypes/${ARCHETYPE}/overlay/." .
        echo "  applied overlay: archetypes/${ARCHETYPE}/overlay/ (${#OVERLAY_FILES[@]} file(s))"
    fi

    # An archetype's workflows bring their lock records as a fragment beside
    # the overlay, never as an overlay file: an overlay actions.lock REPLACES
    # the spine's lock, and every spine workflow then dies at startup with no
    # record. Merge the fragment in; a conflicting record stops the mint.
    if [ -n "$ARCHETYPE" ] && [ -f "archetypes/${ARCHETYPE}/actions.lock" ]; then
        bash scripts/rust-tool.sh merge-actions-lock \
            .github/workflows/actions.lock "archetypes/${ARCHETYPE}/actions.lock"
    fi

    # ── Archetype prune (ADR-0003) ───────────────────────────────────────────
    # The spine is polyglot on purpose: it carries the container module and the
    # dev container so that SOME child can use them. A child carrying a module
    # whose capability its preset does not declare is drift, and one of those
    # modules is not harmless: `build/container/` is a DEPLOYED artifact, so a
    # Julia package shipped it and failed `container-images-pinned` from birth
    # over a container it does not need. The archetype says what it drops in
    # archetypes/<name>/prune.txt; the removals are recorded in the child's
    # (variant (paths :removed …)) so the drift gate does not report them.
    if [ -n "$ARCHETYPE" ] && [ -f "archetypes/${ARCHETYPE}/prune.txt" ]; then
        while IFS= read -r _pruned; do
            [ -n "$_pruned" ] && MINT_REMOVES+=("$_pruned")
        done < <(bash scripts/prune-archetype-modules.sh "archetypes/${ARCHETYPE}" .)
        echo "  pruned: archetypes/${ARCHETYPE}/prune.txt applied"
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

    # Answers are free text, and the right-hand side of s|…|…| is not: `&`
    # inserts the matched token, `\` escapes, `|` ends the expression. A
    # description "Tools & proofs" rendered as "Tools <the token> proofs" and
    # then failed the placeholder gate; a `|` broke the substitution. Every
    # answer goes through sed_rhs. (A newline was refused before the first write.)
    sed_rhs() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

    # Build the sed expression list
    # Note: using | as delimiter since URLs contain /
    SED_ARGS=(
        -e "s|${LB}PROJECT_NAME${RB}|$(sed_rhs "${PROJECT_NAME}")|g"
        -e "s|${LB}PROJECT_DESCRIPTION${RB}|$(sed_rhs "${PROJECT_DESCRIPTION}")|g"
        -e "s|${LB}PROJECT${RB}|$(sed_rhs "${PROJECT_UPPER}")|g"
        -e "s|${LB}project${RB}|$(sed_rhs "${PROJECT_LOWER}")|g"
        -e "s|${LB}REPO${RB}|$(sed_rhs "${REPO}")|g"
        -e "s|${LB}OWNER${RB}|$(sed_rhs "${OWNER}")|g"
        -e "s|${LB}AUTHOR${RB}|$(sed_rhs "${AUTHOR}")|g"
        -e "s|${LB}AUTHOR_EMAIL${RB}|$(sed_rhs "${AUTHOR_EMAIL}")|g"
        -e "s|${LB}AUTHOR_ORG${RB}|$(sed_rhs "${AUTHOR_ORG}")|g"
        -e "s|${LB}AUTHOR_LAST${RB}|$(sed_rhs "${AUTHOR_LAST}")|g"
        -e "s|${LB}AUTHOR_FIRST${RB}|$(sed_rhs "${AUTHOR_FIRST}")|g"
        -e "s|${LB}AUTHOR_INITIALS${RB}|$(sed_rhs "${FIRST_INITIAL}")|g"
        -e "s|${LB}FORGE${RB}|$(sed_rhs "${FORGE}")|g"
        -e "s|${LB}CURRENT_YEAR${RB}|$(sed_rhs "${CURRENT_YEAR}")|g"
        -e "s|${LB}CURRENT_DATE${RB}|$(sed_rhs "${CURRENT_DATE}")|g"
        -e "s|${LB}DATE${RB}|$(sed_rhs "${CURRENT_DATE}")|g"
        -e "s|${LB}SECURITY_EMAIL${RB}|$(sed_rhs "${SECURITY_EMAIL}")|g"
        -e "s|${LB}CONDUCT_EMAIL${RB}|$(sed_rhs "${CONDUCT_EMAIL}")|g"
        -e "s|${LB}LICENSE${RB}|MPL-2.0|g"
        -e "s|${LB}CONDUCT_TEAM${RB}|Code of Conduct Committee|g"
        -e "s|${LB}RESPONSE_TIME${RB}|48 hours|g"
        -e "s|${LB}MAIN_BRANCH${RB}|main|g"
        -e "s|${LB}PROJECT_PURPOSE${RB}|$(sed_rhs "${PROJECT_DESCRIPTION}")|g"
        -e "s|${LB}PROJECT_ROLE${RB}|$(sed_rhs "${PROJECT_TYPE}")|g"
        -e "s|${LB}PROJECT_TYPE${RB}|$(sed_rhs "${PROJECT_TYPE}")|g"
        -e "s|${LB}WEBSITE${RB}|$(sed_rhs "${WEBSITE}")|g"
        -e "s|${LB}SERVICE_NAME${RB}|$(sed_rhs "${SERVICE_NAME}")|g"
        -e "s|${LB}PORT${RB}|$(sed_rhs "${PORT}")|g"
        -e "s|${LB}REGISTRY${RB}|$(sed_rhs "${REGISTRY}")|g"
        -e "s|${LB}IMAGE${RB}|$(sed_rhs "${REGISTRY}")/$(sed_rhs "${SERVICE_NAME}")|g"
        -e "s|${LB}VERSION${RB}|$(sed_rhs "${VERSION}")|g"
        -e "s|${LB}EMAIL${RB}|$(sed_rhs "${AUTHOR_EMAIL}")|g"
        -e "s|${LB}UUID${RB}|$(sed_rhs "${REPO_UUID}")|g"
        -e "s|${LB}DESCRIPTION${RB}|$(sed_rhs "${PROJECT_DESCRIPTION}")|g"
    )
    [ -n "$AUTHOR_EMAIL_ALT" ] && SED_ARGS+=(-e "s|${LB}AUTHOR_EMAIL_ALT${RB}|$(sed_rhs "${AUTHOR_EMAIL_ALT}")|g")
    [ -n "$AUTHOR_ORCID" ] && SED_ARGS+=(-e "s|${LB}AUTHOR_ORCID${RB}|$(sed_rhs "${AUTHOR_ORCID}")|g")
    [ -n "$OPENSSF_BP_ID" ] && SED_ARGS+=(-e "s|${LB}OPENSSF_BP_ID${RB}|$(sed_rhs "${OPENSSF_BP_ID}")|g")
    [ -n "$OPENSSF_BP_ID" ] && SED_ARGS+=(-e "s|${LB}OPENSSF_PROJECT_ID${RB}|$(sed_rhs "${OPENSSF_BP_ID}")|g")

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
    # with a SHA-256 tool (scripts/uuid-v8.sh) or bun over standards'
    # scripts/uuid-v8.js, never colliding with the repo uuid. The domain is
    # REGISTERED in standards' ADR-008-profile-c-domains.json. No SHA-256
    # tool and no bun -> UNASSIGNED
    # (the honest fallback at :437); Pkg then refuses the package loudly
    # until the owner assigns one.
    if [ "$ARCHETYPE" = "julia-library" ]; then
        # GitHub owner logins are case-insensitive; canonicalize to lowercase
        # before the preimage so owner casing cannot fork the UUID.
        OWNER_LC=$(printf '%s' "${OWNER}" | tr '[:upper:]' '[:lower:]')
        # A replay supplies the uuid the mint recorded ((mint-answers
        # :package-uuid)), so the drift gate does not depend on which of bun or
        # a SHA-256 tool the checking host has (Codex review of #275). Only a replay:
        # an ordinary mint always derives it, so a stray RSR_PACKAGE_UUID in the
        # environment cannot write an unrelated identity into Project.toml.
        if [ "${RSR_MINT_REPLAY:-0}" = "1" ] && [[ "${RSR_PACKAGE_UUID:-}" =~ ^(UNASSIGNED|[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$ ]]; then
            PACKAGE_UUID="$RSR_PACKAGE_UUID"
        elif command -v bun >/dev/null 2>&1 && [ -f "${STANDARDS_UUID_V8_JS:-}" ]; then
            PACKAGE_UUID=$(bun "${STANDARDS_UUID_V8_JS}" c julia-package-identity "github.com/${OWNER_LC}/${REPO}")
        elif command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1; then
            # The same ADR-008 profile C id in shell (scripts/uuid-v8.sh, equal to
            # standards uuid-v8.js c). No Python: the estate bans it.
            PACKAGE_UUID=$("${BASH:-bash}" scripts/uuid-v8.sh julia-package-identity "github.com/${OWNER_LC}/${REPO}")
        else
            PACKAGE_UUID=UNASSIGNED
        fi
        SED_ARGS+=(-e "s|${LB}PACKAGE_UUID${RB}|${PACKAGE_UUID}|g")
        echo "  package uuid: ${PACKAGE_UUID} (minted from the birth path, beside chora id ${REPO_UUID})"
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
    # Return success when $1 is classified as text, using a byte-content probe
    # (which accepts empty files) when the file command is unavailable.
    is_text_file() {
        if command -v file >/dev/null 2>&1; then
            file --brief "$1" | grep -qi 'text\|ascii\|utf'
        else
            [ ! -s "$1" ] || LC_ALL=C grep -Iq . "$1"
        fi
    }

    mint_files | while IFS= read -r file; do
        case "${file##*/}" in
            MPL-2.0.txt|Justfile|*.just|*.png|*.jpg|*.gif|*.woff|*.woff2) continue ;;
        esac
        if is_text_file "$file"; then
            sed -i "${SED_ARGS[@]}" "$file"
        fi
    done

    # The pass above fills the container tokens too (SERVICE_NAME, PORT,
    # REGISTRY), which changes how KYAML quotes them; reformat the configs or
    # Estate Rules' "Converted YAML stays KYAML" fails the child.
    bash scripts/format-container-kyaml.sh

    # [YOUR-REPO-NAME] and [YOUR-NAME/ORG] (the family-7 allocation manifest
    # folded into the deed — standards#837 pilot) are replaced in the deed,
    # found by its shape rather than by the original template's file name: in
    # a repository minted from a minted one it is <parent>_chora.deed, and the
    # two seds that named rsr-template-repo_chora.deed silently no-opped there.
    DEED_IN="$(bash scripts/deed-field.sh --find .)" \
        || { echo "Error: the tree must carry exactly one *_chora.deed at its root."; exit 1; }
    sed -i -e "s|\[YOUR-REPO-NAME\]|$(sed_rhs "${PROJECT_NAME}")|g" -e "s|\[YOUR-NAME/ORG\]|$(sed_rhs "${OWNER}")|g" "$DEED_IN"

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
        mint_files | bash scripts/rust-tool.sh strip-instruction-blocks -
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
    if [ "$REPO" != "$TEMPLATE_REPO" ]; then
        SELF_PROV='instantiated-from|parent|upstream|chain =|lineage|minted from|created from|Template: |reject-if-contains'
        # The template's name and slug are LITERAL text, not patterns: a Julia
        # mint's parent may be <Name>.jl, and `.` in a sed pattern matches any
        # character. Escaped inline so self_name_pass_test.sh can evaluate this
        # one assignment exactly as the recipe defines it.
        # The name is matched only where it stands as a whole name: not inside
        # a longer word or slug (Codex review of #251). Unbounded, a parent
        # named `app` turned "application mapping" into "newlication mnewing".
        # A neighbouring letter or digit blocks the match; anything else does
        # not, so `<owner>_<name>` (sonar.projectKey), `<name>_chora.deed` and
        # derived names such as `<name>-checkout` or `rm-<name>` still follow. Each pass
        # loops (:label … t label) because a match consumes its right-hand
        # neighbour, and marks through a sentinel so a new name that contains
        # the old one (Geometry -> Geometry.jl) cannot loop forever.
        SELF_NAME_SED="/${SELF_PROV}/!{:i;s@(^|[^A-Za-z0-9])${TEMPLATE_REPO//./\\.}#([0-9])@\\1\\x01I\\x01\\2@;ti;:s;s@(^|[^A-Za-z0-9])${TEMPLATE_SLUG//./\\.}([^A-Za-z0-9]|$)@\\1\\x01S\\x01\\2@;ts;:n;s@(^|[^A-Za-z0-9])${TEMPLATE_REPO//./\\.}([^A-Za-z0-9]|$)@\\1\\x01N\\x01\\2@;tn;s@\\x01S\\x01@${OWNER}/${REPO}@g;s@\\x01N\\x01@${REPO}@g;s@\\x01I\\x01@${TEMPLATE_REPO}#@g;}"
        # Paths that are ABOUT the template keep its name wholesale: its ADRs,
        # changelog and audits. Template machinery (this recipe, the tests whose
        # fixtures must stay the template's literal name) is not in mint_files
        # at all; it is listed in .machine_readable/mint-verbatim.txt.
        mint_files | while IFS= read -r file; do
            case "$file" in
                docs/decisions/*|CHANGELOG.md|*/CHANGELOG.md) continue ;;
                TEMPLATE-STANDARDS-AUDIT.adoc|*/TEMPLATE-STANDARDS-AUDIT.adoc) continue ;;
                TEMPLATE-LINEAGE-AUDIT.adoc|*/TEMPLATE-LINEAGE-AUDIT.adoc) continue ;;
                *.png|*.jpg|*.gif|*.woff|*.woff2) continue ;;
            esac
            grep -qF -- "$TEMPLATE_REPO" "$file" 2>/dev/null || continue
            is_text_file "$file" || continue
            # sed -i preserves the mode bit; rewriting via a temp file would not.
            sed -i -E "$SELF_NAME_SED" "$file"
        done
        echo "  self-name: rewrote ${TEMPLATE_REPO} -> ${REPO} (provenance lines preserved)"

        # The repo deed's FILENAME carries the repo slug (deed dispatch:
        # <stem>_chora.deed — deed.abnf v1.0.0). The self-name pass rewrote
        # the slug inside the file; the file itself is renamed here. Plain mv:
        # mint runs before the new repo's first commit. Renames (not tokens)
        # are how filenames change — a REPO token in a FILENAME is the
        # brace-collapse hazard class repo-init has already been burnt by.
        # The deed was found by shape above (DEED_IN), never by the original
        # template's name, so a mint from a minted repo renames it too.
        if [ "${DEED_IN#./}" != "${REPO}_chora.deed" ]; then
            mv -- "$DEED_IN" "${REPO}_chora.deed"
            echo "  repo deed: renamed ${DEED_IN#./} -> ${REPO}_chora.deed"
        fi
    fi

    # ── self-OWNER pass ──────────────────────────────────────────────────────
    #
    # Same class as the self-name leak above, and missed by it: the template's
    # own OWNER is a plain literal, so nothing rewrote it. A repo minted under a
    # different owner shipped:
    #
    #     Justfile                 OWNER := "hyperpolymath"
    #     sonar-project.properties sonar.projectKey=hyperpolymath_<repo>
    #
    # i.e. it declared the wrong owner and reported its code analysis into the
    # wrong SonarCloud project. Measured on a metadatastician mint. The owner
    # compared against is the TEMPLATE's (derived above), so a repo minted from
    # a metadatastician child is handled the same way.
    #
    # This pass is deliberately NARROW — three exact, identity-bearing lines. A
    # blanket owner rewrite would be WRONG: `hyperpolymath/standards`,
    # `hyperpolymath/proven` and the other estate dependencies are real repos
    # every child genuinely points at, and rewriting those would break the
    # child's canon, CI and badges.
    if [ "$OWNER" != "$TEMPLATE_OWNER" ]; then
        # The same declaration forms the identity parser accepts: optional
        # `export`, either quote (Codex review of #274).
        sed -i -E "$SELF_OWNER_SED" Justfile sonar-project.properties
        # The deed's document ids hold the repo slug (ADR-008 profile C, domain
        # repo-document). The self-name pass rewrites it, but only when the repo name
        # changes; a mint under the SAME name and a different owner skips that pass
        # and would keep the template's owner in its ids. Followed here, narrowly.
        if [ -f "${REPO}_chora.deed" ]; then
            sed -i -E "s|(repo-document:github\\.com/)${TEMPLATE_OWNER//./\\.}/|\\1$(sed_rhs "${OWNER}")/|g" "${REPO}_chora.deed"
        fi
        echo "  self-owner: rewrote ${TEMPLATE_OWNER} -> ${OWNER} (estate dependency paths preserved)"
        echo "  NOTE: confirm the SonarCloud ORG is really '${OWNER}' before provisioning —"
        echo "        the GitHub owner and the SonarCloud org are not always the same."
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
    #   JUDGEMENT -> left to the author; a clade placement is an optional identity fact, never written here
    ID_IN="build/templates/identity.deed.in"
    # Whatever one deed is present (renamed for the child above, or already
    # named for it): never a hardcoded template file name.
    DEED="$(bash scripts/deed-field.sh --find .)" \
        || { echo "Error: the tree must carry exactly one *_chora.deed at its root."; exit 1; }
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
        # The chora id, minted above from the birth path and written once as an
        # opaque #uuid literal. It replaces the template's own id (whatever its
        # literal form) so a child never carries the template's identity.
        sed -i -E 's,^(  :repo-uuid )#(uuid|u5|u8)"[^"]*",\1#uuid"'"${REPO_UUID}"'",' "$DEED"
        # The template's journal is not the child's: install the stub.
        mkdir -p docs/status
        cp build/templates/ROADMAP.adoc.in docs/status/ROADMAP.adoc
        rm -rf build/templates          # template-only; not part of your repo
        echo "  uuid:  $REPO_UUID"
        echo "         (the chora id: UUIDv8 of the birth path ${FORGE}/${OWNER}/${REPO},"
        echo "          minted once and written to :repo-uuid; a rename never changes it)"
        echo "  clade: none written. Identity is the chora id above; a clade placement is an"
        echo "         optional identity fact. The 12 are listed in the identity comment"
        echo "         of $DEED; validate-rsr checks one only if you declare it."
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
    # scripts/canon-pin-check.sh and standards
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
    # PARENT_BRANCH / PARENT_PIN / PARENT_TREE were resolved before the first
    # write (see "Which template commit is in hand" above). Reading the live
    # remote tip recorded where the remote is NOW, not the tree in hand (#203);
    # reading local HEAD recorded the CHILD's own commit whenever the repo was
    # created with "Use this template" (lintel, 2026-10-14). Tree equality
    # against the template's history is the rule that is right in both cases.
    PARENT_SLUG="$TEMPLATE_SLUG"

    # Shape, not presence: a value that is not a 40-hex object name is not a pin.
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
        echo "  ; Records what this repo was minted from, for re-templating tooling and"
        echo "  ; the drift gate. For a minted repo the gate replays the mint from"
        echo "  ; (provenance) and (mint-answers) and diffs this tree against the"
        echo "  ; replay (scripts/check-mint-drift.sh), so only edits made after the"
        echo "  ; mint count. Declare those in (paths) below; the derived files are"
        echo "  ; declared already, since their own gates keep them fresh."
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
        # The paths this work tree changed before the mint are added to these
        # lists once the mint has moved and deleted what it will (see "What
        # this work tree held before the mint", below).
        _list() { local _s="" _x; printf '      :%s (' "$1"; shift; for _x in "$@"; do printf '%s"%s"' "$_s" "$_x"; _s=" "; done; printf ')'; }
        _removed=("${MINT_REMOVES[@]}")
        [ "${DEED_IN#./}" = "${REPO}_chora.deed" ] || _removed+=("${DEED_IN#./}")
        _list added; echo
        _list removed "${_removed[@]}"; echo
        _list diverged "${REPO}_chora.deed" docs/status/ROADMAP.adoc CLAUDE.md docs/architecture/REPOSITORY-MAP.adoc; echo "))"
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

    # ── (mint-answers) — the answers, so the mint can be replayed ───────────
    # Provenance names the template commit; this names what it was rendered
    # with. Together they make the mint a function that can be run again:
    # scripts/check-mint-drift.sh re-mints the template at the pin with these
    # answers and diffs the child against the result, so drift is measured
    # exactly instead of through hand-written (normalise) rules (ADR-0003).
    # Owner ruling (2026-11-04): record only values the mint already writes
    # into the child's own files (names, contacts, description, URLs), so the
    # record publishes nothing new. Deed strings escape `\` and `"`.
    deed_str() { printf '%s' "$1" | sed -e 's/[\\"]/\\&/g'; }
    # The ruling is checked here, not left to a hand-kept list (Codex review of
    # #275 found project-type recorded, though no template file renders it): a
    # non-empty answer is recorded only if its value appears verbatim in this
    # repo's files. An answer left out replays as unanswered; it rendered
    # nothing here, so the replay is unchanged.
    # Not the template-only trees the mint deletes below (MINT_REMOVES:
    # archetypes/, build/docs-seed/): a value found only there is in no file
    # the child keeps (CodeRabbit review of #275).
    mapfile -t _MINTED < <(mint_files | awk -v r="${MINT_REMOVES[*]:-}" \
        'BEGIN { n = split(r, p, " ") } { for (i = 1; i <= n; i++) if (index($0, p[i]) == 1) next; print }')
    _ANSWERS=() _UNRECORDED=""
    for _pair in project-name:PROJECT_NAME repo:REPO owner:OWNER author:AUTHOR \
                 author-email:AUTHOR_EMAIL author-org:AUTHOR_ORG \
                 author-email-alt:AUTHOR_EMAIL_ALT author-orcid:AUTHOR_ORCID \
                 description:PROJECT_DESCRIPTION forge:FORGE \
                 security-email:SECURITY_EMAIL conduct-email:CONDUCT_EMAIL \
                 project-type:PROJECT_TYPE website:WEBSITE \
                 openssf-bp-id:OPENSSF_BP_ID service-name:SERVICE_NAME \
                 port:PORT registry:REGISTRY archetype:ARCHETYPE \
                 package-uuid:PACKAGE_UUID; do
        _var="${_pair#*:}"
        _val="${!_var:-}"
        if [ -n "$_val" ] && ! grep -qsF -- "$_val" "${_MINTED[@]}" /dev/null; then
            _UNRECORDED="${_UNRECORDED} ${_pair%%:*}"
            continue
        fi
        _ANSWERS+=("    :${_pair%%:*} \"$(deed_str "$_val")\"")
    done
    {
        echo "  ; mint-answers — what just repo-init was answered on ${CURRENT_DATE}."
        echo "  ; Read by scripts/check-mint-drift.sh to replay the mint. Every value"
        echo "  ; here already appears in this repo's rendered files."
        echo "  (mint-answers"
        printf '%s\n' "${_ANSWERS[@]}"
        echo "    :mint-date \"${CURRENT_DATE}\")"
    } | put_clause mint-answers
    echo "  answers:    $DEED_OUT (mint-answers) — replayable with scripts/check-mint-drift.sh"
    [ -z "$_UNRECORDED" ] || echo "              not recorded, written into no file here:${_UNRECORDED}"

    if [ "$CANON_VERSION" = "UNASSIGNED" ]; then
        echo "  provenance: $DEED_OUT (provenance) — canon pin UNASSIGNED"
        echo "              The template deed carried no (canon …) clause, so this repo"
        echo "              cannot state which canon it conforms to. Fix by minting"
        echo "              from a template commit that has one."
    else
        echo "  provenance: $DEED_OUT (provenance)  (canon v${CANON_VERSION} ${CANON_CRITERIA_SHA:0:12})"
        CANON_PROPOSED_BY="$(deed_canon proposed-by "$DEED_OUT")"
        if [ -n "$CANON_PROPOSED_BY" ]; then
            echo "  WARNING:    the template pins canon v${CANON_VERSION} ahead of its release"
            echo "              (:proposed-by \"${CANON_PROPOSED_BY}\"). This repo inherits that pin;"
            echo "              its Canon lockstep passes only while that canon PR is open and"
            echo "              unchanged, and once it merges. Re-mint or re-pin if it is closed."
        fi
    fi

    # archetypes/ is template-only overlay data, not part of your repo
    # (same reason build/templates is removed above).
    rm -rf archetypes
    rm -rf build/docs-seed          # template-only; its content now lives in docs/
    # Its SD022 exemption goes with it: a child keeping an exemption for a path
    # it does not have fails check-hypatia-ignore.sh (stale exemption). The
    # block runs from its section header to the entry, plus the blank after.
    if [ -f .hypatia-ignore ]; then
        awk '/^# ─── build\/docs-seed\/ describes DOWNSTREAM/ { skip = 1 }
             skip && /^structural_drift\/SD022:build\/docs-seed\/$/ { skip = 0; blank = 1; next }
             skip { next }
             blank && /^$/ { blank = 0; next }
             { blank = 0; print }' .hypatia-ignore > .hypatia-ignore.mint
        mv .hypatia-ignore.mint .hypatia-ignore
    fi
    # The Hypatia rule-order policy classifies each module .hypatia-ignore
    # exempts, and check-hypatia-rule-order.sh fails on a classification with
    # no exemption behind it. With no structural_drift exemption left, drop its
    # observed_modules entry. The policy is one line of JCS (RFC 8785), so
    # removing one object and its comma keeps it canonical; no JSON tool needed.
    POLICY=.machine_readable/policies/hypatia-rule-order.json
    if [ -f "$POLICY" ] && ! grep -q '^structural_drift/' .hypatia-ignore 2>/dev/null; then
        SD_OBJ='[{]"layer":[0-9]+,"module":"structural_drift","rationale":"([^"\\]|\\.)*"[}]'
        sed -E -i -e "s/${SD_OBJ},//" -e "s/,${SD_OBJ}//" "$POLICY"
        if grep -q '"module":"structural_drift"' "$POLICY"; then
            echo "ERROR: could not drop structural_drift from $POLICY; the mint stops here." >&2
            exit 1
        fi
    fi

    # Overlay .in rule (every archetype): an overlay ships content templates as
    # *.in so a substitution token never survives in a file whose final name is
    # already the real one — a half-rendered `Project.toml` is a file `Pkg`
    # reads, while a half-rendered `Project.toml.in` is obviously unfinished.
    # Only files THIS overlay added are renamed: the spine's own .in templates
    # (build/templates/, the k9 examples) keep their suffix.
    #
    # src/PACKAGE.jl.in is the one exception, handled after the loop: the Julia
    # convention names the module file after the package, and the package name
    # is only known once Project.toml.in has been rendered and renamed.
    for _of in "${OVERLAY_FILES[@]}"; do
        case "$_of" in
            src/PACKAGE.jl.in) continue ;;
            *.in) [ -f "$_of" ] && { mv "$_of" "${_of%.in}"; echo "  overlay: ${_of%.in}"; } ;;
        esac
    done
    if [ "$ARCHETYPE" = "julia-library" ] && [ -f src/PACKAGE.jl.in ]; then
        TOML_FILE=Project.toml
        if [ -f "$TOML_FILE" ]; then
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
    fi

    # ── Cargo.lock (rust-cli, or any overlay that ships a Cargo.toml) ───────
    # The overlay ships Cargo.toml.in only. The minted rust-ci.yml runs clippy,
    # check and test with --locked, which REFUSES to run without a Cargo.lock,
    # so a fresh mint failed its own CI on the first push. A lock cannot be
    # shipped as a template: it records the package name, which is the repo
    # slug and only known now. It is therefore generated here from the
    # substituted manifest. With no [dependencies] the resolution needs no
    # network, so this works offline; a missing cargo is a hard error, not a
    # skipped step (fail loudly: a repo minted without its lock is red in CI).
    if [ -f Cargo.toml ] && [ ! -f Cargo.lock ]; then
        echo ""
        echo "── Cargo.lock ───────────────────────────────────"
        if ! command -v cargo >/dev/null 2>&1; then
            echo "ERROR: this mint ships a Cargo.toml, so it must also ship a Cargo.lock"
            echo "       (the minted CI builds with --locked), and cargo is not on PATH."
            echo "       Install a Rust toolchain (rustup) and re-run the mint."
            exit 1
        fi
        cargo generate-lockfile || {
            echo "ERROR: cargo generate-lockfile failed; the minted CI would fail on --locked."
            exit 1
        }
        [ -f Cargo.lock ] || { echo "ERROR: cargo reported success but wrote no Cargo.lock."; exit 1; }
        echo "  generated: Cargo.lock"
    fi

    # ── www/ site-operations bundle (issue #53, stage 5) ──────────────────
    #
    # A repository minted from this template already carries www/.well-known/
    # as the canonical location and has no root .well-known/, so in the
    # ordinary case the migration below does nothing at all. It exists for the
    # case that is not ordinary: repo-init run over a tree that predates #53
    # and still has a root .well-known/. The migrator moves it — quarantining
    # anything divergent rather than overwriting it — and the bundle's own
    # suite (under Validation) then proves the result. It runs HERE, before the
    # map and the arrival pack are regenerated, because it moves files: the map
    # must be the last thing written, or it describes a tree that no longer
    # exists (lintel shipped a stale map and Estate Rules failed until lintel#8).
    #
    # #106 described this wiring as already present. It was not: nothing
    # invoked the migrator or the suite at mint, which is why the estate
    # still carries root .well-known/ directories years into the convention.
    if [ -d .well-known ] && [ -f scripts/migrate-wellknown-to-www.sh ]; then
        echo ""
        echo "Migrating legacy root .well-known/ into www/.well-known/..."
        bash scripts/migrate-wellknown-to-www.sh --date "$CURRENT_DATE"
    fi

    # ── Toolchain (mise.toml) ───────────────────────────────────────────────
    # The provisioning standard says mise.toml is MINTED per repository (canon's
    # mise.toml.tmpl carries __MISE_TOOLS_TOML__ for exactly that). Until now the
    # mint copied the spine's file verbatim, so every child declared the
    # TEMPLATE's toolchain: the spine once declared nine runtimes (python, node,
    # rust, go, zig, java, bun, denojs, npm, pip, cargo, black, ruff, pytest …)
    # and a minted Julia package therefore installed Python — banned estate-wide
    # — declared no Julia, and ran `cargo build` from `just build`.
    #
    # Rendered here, after the overlay's manifests have their final names (so
    # detection can see Project.toml / Cargo.toml) and after the archetype prune
    # (so a dropped module does not keep its toolchain).
    if [ -f scripts/render-mise.sh ]; then
        echo ""
        echo "── Toolchain ────────────────────────────────────"
        bash scripts/render-mise.sh --root . || {
            echo "ERROR: mise.toml could not be rendered from this tree's languages."
            exit 1
        }
    fi

    # ── What this work tree held before the mint ────────────────────────────
    # Declared here, after every step that moves or deletes files, as exactly
    # what this tree now differs by from the replay taken before the first write
    # (above): the comparison the drift gate makes, so the declaration cannot
    # disagree with it, whatever the mint did to a pre-mint change on the way
    # (moved, rendered, overwritten, or reached through an edited input) (Codex
    # and CodeRabbit review of #275). The files this mint owns are declared
    # already. Written into the (variant (paths)) lists by awk, which takes the
    # paths as data and escapes \ and " in deed strings.
    if [ -n "$_REPLAY" ]; then
        _owned=("${REPO}_chora.deed" docs/status/ROADMAP.adoc CLAUDE.md docs/architecture/REPOSITORY-MAP.adoc)
        _is_owned() { local _o; for _o in "${_owned[@]}"; do [ "$1" = "$_o" ] && return 0; done; return 1; }
        # _files DIR — DIR's own files, one per line (tracked, or untracked and not
        # ignored), as the drift gate lists them. This tree is read under its own
        # git configuration, as `git add -A` will commit it (a file only a global
        # excludesFile ignores is never committed, so never declared); the
        # replay under none (CodeRabbit review of #275).
        _files() {
            { if [ "$1" = "$_REPLAY" ]; then _rg -C "$1" ls-files -z --cached --others --exclude-standard
              else git -C "$1" ls-files -z --cached --others --exclude-standard; fi; } \
                | while IFS= read -r -d '' _f; do
                    if [ -e "$1/$_f" ] || [ -L "$1/$_f" ]; then printf '%s\n' "$_f"; fi
                done | LC_ALL=C sort -u
        }
        _pml="$(mktemp -d)"; : > "$_pml/a"; : > "$_pml/r"; : > "$_pml/d"
        _files . > "$_pml/child"
        _files "$_REPLAY" > "$_pml/replay"
        while IFS= read -r _p; do
            _is_owned "$_p" && continue
            if ! grep -qxF -- "$_p" "$_pml/replay"; then printf '%s\n' "$_p" >> "$_pml/a"
            elif ! _same "$_p" "$_REPLAY/$_p"; then printf '%s\n' "$_p" >> "$_pml/d"
            fi
        done < "$_pml/child"
        while IFS= read -r _p; do
            _is_owned "$_p" && continue
            grep -qxF -- "$_p" "$_pml/child" || printf '%s\n' "$_p" >> "$_pml/r"
        done < "$_pml/replay"
        awk -v fa="$_pml/a" -v fr="$_pml/r" -v fd="$_pml/d" '
            function load(file,    s, p) {
                s = ""
                while ((getline p < file) > 0) {
                    gsub(/\\/, "\\\\", p); gsub(/"/, "\\\"", p)
                    s = s " \"" p "\""
                }
                close(file); return s
            }
            # insert EXTRA before the ")" that closes the list opened at "(".
            function extend(line, extra,    i, c, q, open, out) {
                open = index(line, "("); q = 0
                for (i = open + 1; i <= length(line); i++) {
                    c = substr(line, i, 1)
                    if (q && c == "\\") { i++; continue }
                    if (c == "\"") q = !q
                    else if (!q && c == ")") {
                        out = substr(line, 1, i - 1) extra substr(line, i)
                        sub(/\( "/, "(\"", out)
                        return out
                    }
                }
                return line
            }
            BEGIN { A = load(fa); R = load(fr); D = load(fd) }
            /^      :added \(/    { $0 = extend($0, A) }
            /^      :removed \(/  { $0 = extend($0, R) }
            /^      :diverged \(/ { $0 = extend($0, D) }
            { print }
        ' "$DEED_OUT" > "$_pml/deed" && cat "$_pml/deed" > "$DEED_OUT"
        echo "  pre-mint: $(wc -l < "$_pml/a") added, $(wc -l < "$_pml/d") diverged, $(wc -l < "$_pml/r") removed;"
        echo "            declared in $DEED_OUT (variant (paths)) as this repo's own"
        rm -rf "$_pml" "$(dirname "$_REPLAY")"
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
    #
    # This is the LAST step that writes the tree; everything after it only
    # checks (tests/e2e/use_template_mint_test.sh commits the result and runs
    # the freshness check on it). The map is read from the work tree
    # (--worktree), not the index: the mint runs before the first commit, so
    # the index still lists archetypes/ and the template's deed name, which is
    # how lintel shipped a map that failed Estate Rules from birth.
    if [ -f .machine_readable/arrival-pack/generate.sh ]; then
        bash .machine_readable/arrival-pack/generate.sh
        echo "  arrival pack: CLAUDE.md regenerated from ${DEED_OUT}"
    fi
    if [ -f scripts/gen-repo-map.sh ]; then
        bash scripts/gen-repo-map.sh --worktree . >/dev/null
        echo "  repo map:     docs/architecture/REPOSITORY-MAP.adoc regenerated"
    fi

    # Replay (scripts/check-mint-drift.sh): every tree-writing step has run, so
    # the reconstruction is complete. What follows only checks the tree: the placeholder
    # gate (a partial mint made with RSR_ALLOW_PLACEHOLDERS=1 would fail it on
    # replay), the www suite (a past RSR_MINT_DATE fails it: security.txt
    # expires at the end of the mint year) and the rest. The child's own CI
    # runs those checks on the child; the replay exists only to be compared.
    if [ "${RSR_MINT_REPLAY:-0}" = "1" ]; then
        echo ""
        echo "Replay complete (RSR_MINT_REPLAY=1): post-write checks left to the child's CI."
        exit 0
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
    # The allowlisted paths are copied from scripts/check-no-placeholders.sh so
    # the two gates cannot drift apart. Each legitimately names tokens: the
    # token vocabulary itself, prose explaining that tokens exist, and the
    # checker's own pattern. Template machinery that names tokens in its
    # fixtures (the e2e answer list, the Julia UUID test) is in
    # .machine_readable/mint-verbatim.txt, so mint_files never lists it, and
    # the checker reads the same manifest.
    PATTERN="${LB}[A-Z_]*${RB}"
    META='PLACEHOLDER|ANYTHING|TOKEN|UPPER_SNAKE'
    REMAINING=$(mint_files | while IFS= read -r f; do
        case "$f" in
            *.md|*.adoc|*.yml|*.yaml|*.deed|*.toml|*.scm|*.ncl|*.nix|*.json|*.sh) ;;
            *) continue ;;
        esac
        case "$f" in
            .machine_readable/ai/PLACEHOLDERS.adoc|EXPLAINME.adoc|scripts/check-no-placeholders.sh) continue ;;
        esac
        grep -q "$PATTERN" "$f" 2>/dev/null || continue
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
    # Read over mint_files, so the files that necessarily NAME the marker in
    # order to describe or assert on it (the strip tool, this recipe, the e2e
    # test, the cleanup test whose fixture must keep the phrase) are exempt by
    # the same manifest that kept the strip pass out of them: they are listed
    # in .machine_readable/mint-verbatim.txt. Before, this list exempted them
    # here while the strip pass rewrote them anyway. All are tooling, not
    # community-health documents, so a mention in them cannot mislead a reader
    # about what this project's Code of Conduct says.
    LEFTOVER_BLOCKS=$(mint_files | while IFS= read -r f; do
        grep -q 'TEMPLATE INSTRUCTIONS' "$f" 2>/dev/null && echo "$f"
    done || true)
    if [ -n "$LEFTOVER_BLOCKS" ]; then
        echo ""
        echo "Un-deleted TEMPLATE INSTRUCTIONS block in:"
        echo "$LEFTOVER_BLOCKS" | sed 's/^/  /'
        echo "ERROR: the instruction-block pass should have removed these."
        exit 1
    fi

    # ── The gates the template enforces on children, run on the child ────────
    # Each of these was once a check the template shipped that could not fail:
    #   * the SPDX check globbed one language's extensions, so in a Julia repo it
    #     examined nothing and reported PASS;
    #   * the container check asked "is cgr.dev named anywhere" and passed on a
    #     floating :latest, so a template shipping two of them passed itself;
    #   * the toolchain check did not exist, and the spine's mise.toml declared
    #     nine runtimes for repositories that use none of them.
    # Running them HERE means a mint that would fail them fails at mint, in the
    # template's own CI, instead of in N children after the fact.
    echo ""
    echo "── Language, licence and container gates ────────"
    GATE_FAIL=0
    for _gate in check-spdx-headers check-mise-language check-container-pins; do
        [ -f "scripts/${_gate}.sh" ] || continue
        echo ""
        echo "  ${_gate}.sh"
        if bash "scripts/${_gate}.sh" --root .; then
            echo "  ${_gate}: OK"
        else
            echo "  ${_gate}: FAILED"
            GATE_FAIL=1
        fi
    done
    if [ "$GATE_FAIL" -ne 0 ]; then
        echo ""
        echo "ERROR: the minted tree fails a gate this template enforces on children."
        echo "       The tree above is complete but not conforming; fix it before"
        echo "       committing. (A mint that ships a failing tree teaches the child"
        echo "       that the gate is noise.)"
        exit 1
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
    echo "     Register in chora-registry (formerly gv-clade-index); required contexts must equal emitted job ids."
    if [ -f ci/.gitlab-ci.yml ]; then
        echo ""
        echo "     GitLab mirror only: this repo keeps its GitLab CI config at"
        echo "     ci/.gitlab-ci.yml, which GitLab does NOT look for by default."
        echo "     Settings > CI/CD > General pipelines > CI/CD configuration file"
        echo "     must be set to ci/.gitlab-ci.yml, or GitLab CI silently never"
        echo "     runs - no pipeline and no error. See ci/README.adoc."
    fi
    echo "  8. HARNESS — check the recorded pin, then arm the drift gate, which replays"
    echo "     this mint from (provenance) and (mint-answers) and diffs the result:"
    echo "       scripts/check-template-conformance.sh"
    echo "       scripts/check-variant-drift.sh <template-checkout>"
