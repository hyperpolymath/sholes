#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# install.sh — install the pinned squabble release binary, or refuse.
#
# The order is the whole point of this file:
#
#   1. download the release asset into a fresh directory;
#   2. refuse it unless its sha256 equals SQUABBLE_SHA256, before anything
#      else reads or runs the file;
#   3. refuse it unless `gh attestation verify` proves it was built by this
#      repository's release.yml, from the pinned tag AND the pinned source
#      commit, on a GitHub-hosted runner, and the attested subject for the
#      asset carries that same digest;
#   4. only then make it executable, smoke-test its version and put it on PATH.
#
# The tag is a locator, not a trust anchor: the digest is the anchor, and the
# attestation ties that digest to the source commit. The plain-text output of
# `gh attestation verify` has been seen EMPTY with exit 0 when stdout is not a
# terminal (2026-10-09), so the JSON form is read and checked here instead.
#
# Bumping squabble means changing SQUABBLE_TAG, SQUABBLE_SHA256 and
# SQUABBLE_SOURCE_DIGEST to a new release's values, each read from that
# release itself, never copied from a tag name; README.adoc next to this file
# gives the steps.
#
# Sourcing this file defines the functions without running main, so
# tests/squabble_action_test.sh can exercise each guard on its own.

set -euo pipefail

readonly SQUABBLE_REPO="hyperpolymath/cicd-squabbler"
readonly SQUABBLE_TAG="v0.1.0"
readonly SQUABBLE_ASSET="squabble-x86_64-linux-musl"
readonly SQUABBLE_SHA256="6cbeb4577d83ccf2dea3405a3afb0d34b7fee422af73f2113d413ea7edba026c"
readonly SQUABBLE_SOURCE_DIGEST="b854d17abc0dce296719a349ebe856ff945cf03e"
readonly SQUABBLE_SIGNER_WORKFLOW="hyperpolymath/cicd-squabbler/.github/workflows/release.yml"

# die MESSAGE... — print MESSAGE as a GitHub Actions error annotation and exit 1.
die() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

# require_platform — refuse any machine that cannot execute the x86_64 Linux asset.
require_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  if [[ "$os" != "Linux" || "$arch" != "x86_64" ]]; then
    die "squabble action supports only x86_64 Linux runners (this is ${os}/${arch})"
  fi
}

# verify_digest FILE — succeed only if FILE exists and its sha256 equals SQUABBLE_SHA256.
verify_digest() {
  local file="$1" actual
  if [[ ! -f "$file" ]]; then
    printf '::error::%s does not exist\n' "$file" >&2
    return 1
  fi
  actual="$(sha256sum -- "$file")"
  actual="${actual%% *}"
  if [[ "$actual" != "$SQUABBLE_SHA256" ]]; then
    printf '::error::%s has sha256 %s, expected %s; refusing it\n' \
      "$file" "$actual" "$SQUABBLE_SHA256" >&2
    return 1
  fi
}

# check_attestation_json FILE — succeed only if FILE holds a non-empty JSON array
# of verification results, each of which attests SQUABBLE_ASSET, and only with
# the digest SQUABBLE_SHA256. Other subjects in the same statement (the release
# also attests SHA256SUMS) are allowed; an empty array is a refusal, not a pass.
check_attestation_json() {
  local json="$1"
  jq -e --arg name "$SQUABBLE_ASSET" --arg sha "$SQUABBLE_SHA256" '
    type == "array" and length > 0 and all(.[];
      [.verificationResult.statement.subject[]?
        | select(.name == $name) | .digest.sha256] as $d
      | ($d | length) > 0 and all($d[]; . == $sha))
  ' "$json" >/dev/null
}

# verify_attestation FILE — succeed only if GitHub's build-provenance attestation
# for FILE was signed by SQUABBLE_SIGNER_WORKFLOW at SQUABBLE_TAG, built from
# SQUABBLE_SOURCE_DIGEST on a GitHub-hosted runner, and names the pinned digest.
verify_attestation() {
  local file="$1" json rc=0
  json="${file}.attestation.json"
  gh attestation verify "$file" \
    --repo "$SQUABBLE_REPO" \
    --signer-workflow "$SQUABBLE_SIGNER_WORKFLOW" \
    --source-ref "refs/tags/${SQUABBLE_TAG}" \
    --source-digest "$SQUABBLE_SOURCE_DIGEST" \
    --predicate-type "https://slsa.dev/provenance/v1" \
    --deny-self-hosted-runners \
    --format json >"$json" || rc=$?
  if (( rc != 0 )); then
    printf '::error::gh attestation verify refused %s (exit %d)\n' "$file" "$rc" >&2
    return 1
  fi
  if ! check_attestation_json "$json"; then
    printf '::error::the attestation for %s does not name %s with sha256 %s\n' \
      "$file" "$SQUABBLE_ASSET" "$SQUABBLE_SHA256" >&2
    return 1
  fi
}

# main — download, verify and install squabble; on success append its directory
# to GITHUB_PATH and write `path=<binary>` to GITHUB_OUTPUT when those are set.
main() {
  local work asset bin version
  require_platform
  work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/squabble.XXXXXX")"
  mkdir -p "${work}/bin"
  gh release download "$SQUABBLE_TAG" \
    --repo "$SQUABBLE_REPO" \
    --pattern "$SQUABBLE_ASSET" \
    --dir "${work}/download"
  asset="${work}/download/${SQUABBLE_ASSET}"

  verify_digest "$asset" || die "squabble ${SQUABBLE_TAG}: download does not match the pinned sha256"
  verify_attestation "$asset" || die "squabble ${SQUABBLE_TAG}: attestation check failed"

  bin="${work}/bin/squabble"
  mv -- "$asset" "$bin"
  chmod 0755 "$bin"
  version="$("$bin" --version)"
  if [[ "$version" != "squabble ${SQUABBLE_TAG#v}" ]]; then
    die "installed binary reports '${version}', expected 'squabble ${SQUABBLE_TAG#v}'"
  fi

  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "${work}/bin" >>"$GITHUB_PATH"
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'path=%s\n' "$bin" >>"$GITHUB_OUTPUT"
  fi
  printf 'installed %s at %s (sha256:%s, attestation verified)\n' \
    "$version" "$bin" "$SQUABBLE_SHA256" >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
