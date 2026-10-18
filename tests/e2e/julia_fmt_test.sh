#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Execute the formatting command shipped to Julia repos, with positive and
# negative controls in every scanned directory. Requires the real Julia and
# JuliaFormatter toolchain; package provisioning may need network access.
# Usage: JULIA_BIN=/path/to/julia bash tests/e2e/julia_fmt_test.sh
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
# Print all arguments as a failure message to stderr and exit the test with status 1.
fail() { echo "FAIL: $*" >&2; exit 1; }
julia_bin=$(command -v "${JULIA_BIN:-julia}") || fail 'Julia is required (set JULIA_BIN)'
# The workflow invokes `julia`; respect JULIA_BIN even if it has another name.
mkdir -p "$fixture/bin"
ln -s "$julia_bin" "$fixture/bin/julia"

# Run the entire literal command, including the file enumeration and current
# JuliaFormatter API. Reimplementing that loop here hid the original bugs.
awk '
  /^  fmt:/ { job = 1; next }
  job && /^  [A-Za-z0-9_-]+:/ { exit }
  job && /^        run: \|$/ { copying = 1; next }
  copying { sub(/^          /, ""); print }
' "$repo/archetypes/julia-library/overlay/.github/workflows/julia-ci.yml.in" > "$fixture/check-format.sh"
[ -s "$fixture/check-format.sh" ] || fail 'formatting command not found in workflow'
work="$fixture/package"
mkdir -p "$work/src/nested" "$work/test/nested" "$work/test/cases/nested"
cd "$work"

# Reset the three scanned Julia files to formatted contents in the package fixture.
clean_files() {
  printf 'x = 1\n' > src/example.jl
  printf 'y = 2\n' > test/runtests.jl
  printf 'z = 3\n' > test/cases/example.jl
}
# Print SHA-256 checksums for scanned and nested fixture files to detect rewrites.
snapshot() {
  sha256sum src/example.jl test/runtests.jl test/cases/example.jl \
    src/nested/ignored.jl test/nested/ignored.jl test/cases/nested/ignored.jl
}
# Run the shipped formatter check with the selected Julia binary, logging both
# output streams to format.log in the fixture; return the check's exit status.
run_fmt() {
  PATH="$fixture/bin:$PATH" bash -e "$fixture/check-format.sh" > "$fixture/format.log" 2>&1
}

# Nested directories are not files. Their deliberately invalid contents
# also prove that this shallow scan does not start recursing accidentally.
for dir in src/nested test/nested test/cases/nested; do
  printf 'this is deliberately invalid Julia (((\n' > "$dir/ignored.jl"
done
clean_files
before=$(snapshot)
run_fmt || { cat "$fixture/format.log" >&2; fail 'formatted files did not pass'; }
[ "$(snapshot)" = "$before" ] || fail 'positive formatting check rewrote input files'
echo 'PASS: formatted files pass; directories are ignored; input files are unchanged'

for file in src/example.jl test/runtests.jl test/cases/example.jl; do
  clean_files
  printf 'x=1\n' > "$file"
  before=$(snapshot)
  if run_fmt; then fail "unformatted $file passed"; fi
  grep -qF 'not formatted' "$fixture/format.log" \
    && grep -qF "$file" "$fixture/format.log" \
    || { cat "$fixture/format.log" >&2; fail "$file failed without a formatting diagnostic"; }
  [ "$(snapshot)" = "$before" ] || fail "formatting check rewrote $file"
  echo "PASS: unformatted $file is rejected without rewriting any input"
done

rm src/example.jl test/runtests.jl test/cases/example.jl
run_fmt || { cat "$fixture/format.log" >&2; fail 'directories without files did not pass'; }
echo 'PASS: empty file selection passes without trying to read directories'
