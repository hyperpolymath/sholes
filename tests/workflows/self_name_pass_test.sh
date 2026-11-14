#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The mint's self-name pass rewrites the template's literal name to the
# child's, except on provenance lines and in issue references. It is a sed
# program inside build/just/repo-init.just; this runs that program, as the
# recipe defines it, over fixture lines. A recipe without the two lines fails
# the test rather than skipping it.
#
# The template's name is DERIVED from the checkout, never assumed to be
# rsr-template-repo: repo-init is carried into children unchanged, so a mint
# from a minted repo must rewrite THAT repo's name (lintel, say). Both
# generations are exercised; the second is the regression a hardcoded literal
# reintroduces (first fixed downstream in metadatastician/lintel#9).
#
# This file's fixtures must keep the template's literal name, so the mint
# carries it unchanged (.machine_readable/mint-verbatim.txt). Rewritten, it
# failed in lintel: `lintel (rsr-template-repo#7)` vs `mint-check (...)`.
# OWNER, REPO and TEMPLATE_* are read by the sourced recipe lines (file-wide).
# shellcheck disable=SC2034
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
recipe="$repo/build/just/repo-init.just"
prov=$(grep -m1 -E "^ +SELF_PROV='" "$recipe") || { echo "FAIL: no SELF_PROV line in $recipe" >&2; exit 1; }
prog=$(grep -m1 -E '^ +SELF_NAME_SED="' "$recipe") || { echo "FAIL: no SELF_NAME_SED line in $recipe" >&2; exit 1; }
rule_script=$(mktemp)
trap 'rm -f "$rule_script"' EXIT
printf '%s\n%s\n' "$prov" "$prog" > "$rule_script"
# The recipe must derive the template's identity instead of naming one.
grep -qE 'TEMPLATE_REPO=.*Justfile' "$recipe" \
  || { echo "FAIL: repo-init does not read TEMPLATE_REPO from the Justfile" >&2; exit 1; }
grep -qE 'TEMPLATE_SLUG="\$\{TEMPLATE_OWNER\}/\$\{TEMPLATE_REPO\}"' "$recipe" \
  || { echo "FAIL: repo-init does not compose TEMPLATE_SLUG" >&2; exit 1; }
grep -qE 'PARENT_SLUG="\$TEMPLATE_SLUG"' "$recipe" \
  || { echo "FAIL: repo-init does not record the derived parent in provenance" >&2; exit 1; }
# Outside comments, no code line may
# name the original template or a deed file: each such line was a mint that
# silently did nothing in a second-generation child.
hard=$(grep -nE 'rsr-template-repo|hyperpolymath|[A-Za-z0-9-]_chora\.deed' "$recipe" \
       | grep -vE '^[0-9]+: *#' || true)
[ -z "$hard" ] || { echo "$hard" >&2; echo "FAIL: repo-init hardcodes a template name or deed file again" >&2; exit 1; }
# The template identity must never fall back to the git remote: in a
# template-created child the remote is the CHILD (Codex review of #251).
if sed -n '/--- The template'"'"'s own identity/,/TEMPLATE_SLUG=/p' "$recipe" | grep -v '^ *#' | grep -q 'remote\.origin'; then
  echo "FAIL: repo-init derives the template identity from the git remote again" >&2; exit 1
fi

fail=0
# check INPUT EXPECTED — the pass must turn INPUT into EXPECTED.
check() {
  local got; got=$(printf '%s\n' "$1" | sed -E "$SELF_NAME_SED")
  if [ "$got" = "$2" ]; then echo "  PASS $1"; else echo "  FAIL $1 -> $got (want $2)" >&2; fail=1; fi
}

# ── Generation 1: minted from rsr-template-repo ──────────────────────────────
TEMPLATE_OWNER=hyperpolymath TEMPLATE_REPO=rsr-template-repo
TEMPLATE_SLUG="${TEMPLATE_OWNER}/${TEMPLATE_REPO}"
OWNER=example-owner REPO=mint-check
# shellcheck disable=SC1090
. "$rule_script"
check 'project := "rsr-template-repo"' 'project := "mint-check"'
check 'sonar.projectKey=hyperpolymath_rsr-template-repo' 'sonar.projectKey=hyperpolymath_mint-check'
check 'https://github.com/hyperpolymath/rsr-template-repo/issues/new' 'https://github.com/example-owner/mint-check/issues/new'
# Issue references name the template's own issues.
check '# deed clauses since rsr-template-repo#209.' '# deed clauses since rsr-template-repo#209.'
check 'see hyperpolymath/rsr-template-repo#53 and rsr-template-repo#106' 'see hyperpolymath/rsr-template-repo#53 and rsr-template-repo#106'
check 'rsr-template-repo (rsr-template-repo#7)' 'mint-check (rsr-template-repo#7)'
# A deed document id (ADR-008 profile C, domain repo-document) holds the slug: it follows the minting owner and repo.
check ':id #u8"repo-document:github.com/hyperpolymath/rsr-template-repo#placeholders"' ':id #u8"repo-document:github.com/example-owner/mint-check#placeholders"'
# Provenance and detector lines are left alone.
check ':instantiated-from "hyperpolymath/rsr-template-repo"' ':instantiated-from "hyperpolymath/rsr-template-repo"'
check ':reject-if-contains ("rsr-template-repo")' ':reject-if-contains ("rsr-template-repo")'
# The deed-validate message names the template as the deed's upstream source.
check 'Copy it from the upstream template, [rsr-template-repo](https://github.com/hyperpolymath/rsr-template-repo).' \
      'Copy it from the upstream template, [rsr-template-repo](https://github.com/hyperpolymath/rsr-template-repo).'

# ── Generation 2: minted from a minted repo (metadatastician/lintel) ─────────
TEMPLATE_OWNER=metadatastician TEMPLATE_REPO=lintel
TEMPLATE_SLUG="${TEMPLATE_OWNER}/${TEMPLATE_REPO}"
OWNER=example-owner REPO=mint-check
# shellcheck disable=SC1090
. "$rule_script"
check 'project := "lintel"' 'project := "mint-check"'
check 'REPO := "lintel"' 'REPO := "mint-check"'
check 'sonar.projectKey=metadatastician_lintel' 'sonar.projectKey=metadatastician_mint-check'
check ':repo-uuid #u5"github.com/metadatastician/lintel"' ':repo-uuid #u5"github.com/example-owner/mint-check"'
check 'see metadatastician/lintel#53 and lintel#106' 'see metadatastician/lintel#53 and lintel#106'
check 'lintel_chora.deed (anchor)' 'mint-check_chora.deed (anchor)'
check ':instantiated-from "lintel"' ':instantiated-from "lintel"'
# The grandparent's name is not this generation's literal.
check ':reject-if-contains ("rsr-template-repo")' ':reject-if-contains ("rsr-template-repo")'
check 'see hyperpolymath/rsr-template-repo' 'see hyperpolymath/rsr-template-repo'

# ── A dotted parent slug (Julia package repos, <Name>.jl) ────────────────────
# `.` is a sed metacharacter; unescaped it would rewrite "GeometryXjl" too.
TEMPLATE_OWNER=example-owner TEMPLATE_REPO="Geometry.jl"
TEMPLATE_SLUG="${TEMPLATE_OWNER}/${TEMPLATE_REPO}"
OWNER=example-owner REPO=mint-check
# shellcheck disable=SC1090
. "$rule_script"
check 'project := "Geometry.jl"' 'project := "mint-check"'
check 'Geometry.jl ships it; GeometryXjl is another string' 'mint-check ships it; GeometryXjl is another string'

# ── A short, common parent name (Codex review of #251) ───────────────────────
# Unbounded, a parent named `app` corrupted every word containing "app".
TEMPLATE_OWNER=example-owner TEMPLATE_REPO=app
TEMPLATE_SLUG="${TEMPLATE_OWNER}/${TEMPLATE_REPO}"
OWNER=other-owner REPO=new
# shellcheck disable=SC1090
. "$rule_script"
check 'application mapping app' 'application mapping new'
check 'my-app app-config apps happy' 'my-new new-config apps happy'
check 'project := "app"' 'project := "new"'
check 'app app app' 'new new new'
check 'example-owner/app and example-owner/apps' 'other-owner/new and example-owner/apps'
check 'sonar.projectKey=example-owner_app' 'sonar.projectKey=example-owner_new'
check 'app_chora.deed and app#12' 'new_chora.deed and app#12'
# A new name containing the old one terminates and is not rewritten twice.
TEMPLATE_OWNER=example-owner TEMPLATE_REPO=geo
TEMPLATE_SLUG="${TEMPLATE_OWNER}/${TEMPLATE_REPO}"
OWNER=example-owner REPO=geo-tools
# shellcheck disable=SC1090
. "$rule_script"
check 'geo and geo' 'geo-tools and geo-tools'

# ── Literal marker-like text survives (Codex review of #274) ─────────────────
# The pass marks matches before replacing them; markers that are plain text
# rewrote a user's literal "__TEMPLATE_NAME__". They are control characters now.
TEMPLATE_OWNER=example-owner TEMPLATE_REPO=app
TEMPLATE_SLUG="${TEMPLATE_OWNER}/${TEMPLATE_REPO}"
OWNER=other-owner REPO=new
# shellcheck disable=SC1090
. "$rule_script"
check 'app handles __TEMPLATE_NAME__ and __TEMPLATE_SLUG__ text' 'new handles __TEMPLATE_NAME__ and __TEMPLATE_SLUG__ text'

# ── The self-owner rule: every form the identity parser accepts ─────────────
# One definition (SELF_OWNER_SED), used by the mint and by chain-mint.sh on
# the parent's carried files (Codex review of #277). It touches exactly the
# three identity lines; estate dependencies under the old owner stay.
oprog=$(grep -m1 -E '^ +SELF_OWNER_SED="' "$recipe") \
  || { echo "FAIL: no SELF_OWNER_SED line in $recipe" >&2; exit 1; }
grep -qE '^ +sed -i -E "\$SELF_OWNER_SED" Justfile sonar-project.properties$' "$recipe" \
  || { echo "FAIL: the self-owner pass does not apply SELF_OWNER_SED" >&2; exit 1; }
printf '%s\n' "$oprog" > "$rule_script"
sed_rhs() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
TEMPLATE_OWNER=example-owner OWNER=other-owner
# shellcheck disable=SC1090
. "$rule_script"
ocheck() {
  local got; got=$(printf '%s\n' "$1" | sed -E "$SELF_OWNER_SED")
  if [ "$got" = "$2" ]; then echo "  PASS owner: $1"; else echo "  FAIL owner: $1 -> $got (want $2)" >&2; fail=1; fi
}
ocheck 'OWNER := "example-owner"' 'OWNER := "other-owner"'
ocheck "OWNER := 'example-owner'" "OWNER := 'other-owner'"
ocheck 'export OWNER := "example-owner"' 'export OWNER := "other-owner"'
ocheck 'sonar.organization=example-owner' 'sonar.organization=other-owner'
ocheck 'sonar.projectKey=example-owner_elder-proj' 'sonar.projectKey=other-owner_elder-proj'
# Controls: dependencies, longer owners and other keys are left alone.
ocheck 'uses: example-owner/standards/.github/workflows/x.yml@main' 'uses: example-owner/standards/.github/workflows/x.yml@main'
ocheck 'sonar.organization=example-owner-two' 'sonar.organization=example-owner-two'
ocheck 'OWNER := "example-owner-two"' 'OWNER := "example-owner-two"'
ocheck 'REPO_OWNER := "example-owner"' 'REPO_OWNER := "example-owner"'

[ "$fail" -eq 0 ] || { echo "FAIL: self-name pass" >&2; exit 1; }
echo 'PASS: self-name pass rewrites the derived template name, keeps issue references, provenance and detectors'
