#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# is-template-tree.sh [ROOT] - exit 0 iff ROOT (default .) is the template tree
# itself, not a repo minted from it. The one definition the template-only test
# controls share.
#
# A file named rsr-template-repo_chora.deed is NOT enough: some repos (fumble,
# hottchpotch) still carry the template's deed under that name, unrenamed and
# with its header unchanged. So the tree is the template only when ALL hold:
#   * rsr-template-repo_chora.deed exists at ROOT;
#   * its header :canonical-name is "rsr-template-repo";
#   * archetypes/ exists (the mint removes it, see docs/architecture/REPOSITORY-MAP.adoc);
#   * the repository it is checked out as is rsr-template-repo: the basename of
#     $GITHUB_REPOSITORY in CI, else of the git origin URL, else of ROOT's
#     directory name. A copy of the template under another repo's name is a
#     minted repo for this purpose.
set -u
root="${1:-.}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deed="$root/rsr-template-repo_chora.deed"
[ -f "$deed" ] || exit 1
[ -d "$root/archetypes" ] || exit 1
name="$(bash "$here/deed-field.sh" "$deed" "" canonical-name 2>/dev/null)" || exit 1
[ "$name" = "rsr-template-repo" ] || exit 1
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  slug="${GITHUB_REPOSITORY##*/}"
elif url="$(git -C "$root" remote get-url origin 2>/dev/null)" && [ -n "$url" ]; then
  slug="${url##*/}"; slug="${slug%.git}"
else
  slug="$(basename "$(cd "$root" && pwd)")"
fi
[ "$slug" = "rsr-template-repo" ]
