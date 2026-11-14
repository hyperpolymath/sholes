#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# run.sh — run the installed squabble with the arguments in SQUABBLE_ARGS,
# record its exit code as the step output `exit-code`, and exit with it.
#
# SQUABBLE_ARGS holds one argument per line, taken literally: no shell
# parsing, no globbing, no word splitting. Blank lines are dropped, so the
# trailing newline of a YAML block scalar adds no empty argument.
#
# The exit code is captured with `|| rc=$?`. The runner's shell is
# `bash -e`, under which `cmd; rc=$?` never reaches the assignment.

set -euo pipefail

# main — split SQUABBLE_ARGS on newlines, run SQUABBLE_BIN with them, write
# exit-code to GITHUB_OUTPUT when it is set, and exit with squabble's code.
main() {
  local line rc=0
  local -a args=()
  if [[ ! -x "${SQUABBLE_BIN:-}" ]]; then
    printf '::error::SQUABBLE_BIN (%s) is not an executable file\n' "${SQUABBLE_BIN:-}" >&2
    exit 1
  fi
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      args+=("$line")
    fi
  done <<<"${SQUABBLE_ARGS:-}"

  "$SQUABBLE_BIN" "${args[@]}" || rc=$?

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'exit-code=%d\n' "$rc" >>"$GITHUB_OUTPUT"
  fi
  exit "$rc"
}

main "$@"
