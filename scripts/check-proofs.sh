#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-proofs.sh <prover>            prover in: idris2 | lean4 | agda | coq
#
# The single source of truth for "do the <prover> proofs in this repo compile?".
# build/just/proofs.just calls this (`just proof-check-<prover>`), and CI should
# too, so a green local run and a green CI run mean the same thing.
#
# It replaces four separate "checks that could not fail" that let non-compiling
# proofs sit in estate repos for months while every status file said "proved":
#
#   1. `command -v <prover> || { echo SKIP; exit 0; }` — a MISSING TOOLCHAIN
#      reported success.  A gate that cannot run must never report OK: it
#      manufactures false confidence, which is worse than having no gate.
#   2. `<prover> --check <full/path/To/Mod>` — Idris2 (and friends) derive the
#      expected module name from the path they are handed, so a module checked
#      from the wrong directory fails on a name mismatch rather than its real
#      errors, and verdicts invert.  Every module here is checked from its own
#      SOURCE ROOT (declared in the MANIFEST).
#   3. Path-filtered CI that only looked at one directory — nothing checked the
#      rest.  Here, a proof file present on disk but absent from the MANIFEST is
#      an ERROR, so new proofs are gated by default, not by remembering.  The
#      scan covers verification/proofs/<prover>/ and every source root the
#      MANIFEST names, and an entry must name a .<ext> source with status
#      gated or quarantine, so a quarantined README cannot pass as a proof.
#   4. `idris2 --check X && ok` — `idris2 --check` EXITS 0 ON A MISSING IMPORT
#      (verified against 0.7.0) while printing `Error: ...`.  Testing the exit
#      code alone is unsound; for idris2 we require exit 0 AND no `Error:` line.
#   5. `idris2 --check` also exits 0, with no `Error:`, on a module whose proof
#      is an unsolved hole (`= ?todo`), verified against 0.7.0 on 2026-11-09.
#      For idris2 we also require the REPL's `:m` to answer `No holes`.
#
# They share one shape: a null check that emits reassuring text.  If you extend
# this script, the test to apply is not "does it pass?" but "have I watched it
# fail?".
#
# CONVENTION: proofs live under verification/proofs/<prover>/ ; the MANIFEST for
# a prover is verification/proofs/<prover>/MANIFEST, one entry per line:
#
#   <source-root>|<module-path-relative-to-source-root>|gated|quarantine|<note>
#
#     source-root : directory the prover is invoked from, chosen so the module's
#                   declared name matches its path (getting this wrong is hole #2).
#     gated       : MUST compile.  A failure fails this script and CI.
#     quarantine  : known-broken, tracked in docs/status/ROADMAP.adoc.  Must CONTINUE to fail;
#                   if one starts compiling the script fails and tells you to
#                   promote it, so the list cannot rot into a permanent excuse.
#
# Blank lines and lines starting with # are ignored.
#
# Exit: 0 = every gated module compiles AND every quarantined module still fails
#           AND every proof file on disk is listed; 1 = otherwise; 2 = misuse.

set -euo pipefail

PROVER="${1:-}"
case "$PROVER" in
  idris2|lean4|agda|coq) ;;
  *) echo "usage: $(basename "$0") <idris2|lean4|agda|coq>" >&2; exit 2 ;;
esac

# This script lives in <repo-root>/scripts/ ; run everything from the repo root.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
PROOF_DIR="verification/proofs/$PROVER"
MANIFEST_FILE="$PROOF_DIR/MANIFEST"

# --- per-prover configuration -------------------------------------------------
# CMD      : executable that must be on PATH (absent => FAIL, never skip).
# EXT      : file extension, for the "unlisted proof" coverage scan.
# ERROR_RE : if non-empty, output must not match it even when the exit code is 0.
#            idris2 needs it (its --check exits 0 on a missing import), and so
#            does lean4: `lean` exits 0 on `sorry`, reporting only a warning.
#            coqc exits 0, silently, on `Admitted`, so no pattern can catch it;
#            check_one therefore also runs scripts/scan-dangerous.sh on every
#            module, for every prover.
case "$PROVER" in
  idris2) CMD=idris2; EXT=idr;  ERROR_RE='^Error:' ;;
  lean4)  CMD=lean;   EXT=lean; ERROR_RE="error:|declaration uses 'sorry'" ;;
  agda)   CMD=agda;   EXT=agda; ERROR_RE=''        ;;
  coq)    CMD=coqc;   EXT=v;    ERROR_RE=''        ;;
esac

check_one() {
  # $1 source-root (rel to ROOT), $2 module (rel to source-root).
  # Sets LAST_OUT to the tool output on failure; returns 0 iff the module compiles and uses no escape hatch in code.
  local root="$1" rel="$2" out rc
  set +e
  case "$PROVER" in
    idris2) out="$(cd "$ROOT/$root" && idris2 --check "$rel" 2>&1)"; rc=$?
            # Hole #5: --check accepts unsolved holes (?name). Ask the REPL.
            if [ "$rc" -eq 0 ] && ! grep -qE "$ERROR_RE" <<<"$out"; then
              holes="$(cd "$ROOT/$root" && printf ':m\n:q\n' | idris2 --no-banner "$rel" 2>&1)"
              if ! grep -q 'No holes' <<<"$holes"; then
                out="$out"$'\n'"Error: unsolved holes: $(grep -o '[0-9]* holes\{0,1\}:.*' <<<"$holes" | head -1)"
              fi
            fi ;;
    lean4)  out="$(cd "$ROOT/$root" && lean          "$rel" 2>&1)"; rc=$? ;;
    # Canonical theory invocation, PROOF-POLICY §2.1 (standards). Do not weaken.
    agda)   out="$(cd "$ROOT/$root" && agda --safe --without-K --cubical-compatible "$rel" 2>&1)"; rc=$? ;;
    coq)    out="$(cd "$ROOT/$root" && coqc           "$rel" 2>&1)"; rc=$? ;;
  esac
  set -e
  if [[ "$rc" -ne 0 ]] || { [[ -n "$ERROR_RE" ]] && grep -qE "$ERROR_RE" <<<"$out"; }; then
    LAST_OUT="$out"; return 1
  fi
  # A module that compiles but uses an escape hatch (believe_me, sorry,
  # Admitted, ...) in code is not a proof. Comments are ignored.
  if ! out="$(bash "$ROOT/scripts/scan-dangerous.sh" "$root/$rel" 2>&1)"; then
    LAST_OUT="$out"; return 1
  fi
  LAST_OUT=""; return 0
}

echo "=== $PROVER proof check ==="

# --- toolchain: absent means FAIL, never skip ---------------------------------
if ! command -v "$CMD" >/dev/null 2>&1; then
  {
    echo "FAIL: '$CMD' not found on PATH."
    echo
    echo "This is deliberately fatal.  The previous recipe did 'exit 0' here with"
    echo "\"SKIP: $CMD not installed\", so every $PROVER proof reported green on any"
    echo "machine that could not check it.  Install the $PROVER toolchain, or run"
    echo "this in CI where the workflow installs it."
  } >&2
  exit 1
fi
"$CMD" --version 2>/dev/null | head -1 || true
echo

# --- a repo with proofs but no MANIFEST is itself a failure -------------------
if [ ! -f "$MANIFEST_FILE" ]; then
  if [ -d "$PROOF_DIR" ] && [ -n "$(find "$PROOF_DIR" -name "*.$EXT" 2>/dev/null)" ]; then
    echo "FAIL: $PROOF_DIR contains .$EXT proofs but has no MANIFEST." >&2
    echo "      Create $MANIFEST_FILE listing each as 'gated' or 'quarantine'." >&2
    exit 1
  fi
  echo "no $PROOF_DIR/*.$EXT proofs and no MANIFEST — nothing to check."
  exit 0
fi

fails=0
unexpected_pass=0
listed_tmp="$(mktemp)"
roots_tmp="$(mktemp)"
trap 'rm -f "$listed_tmp" "$roots_tmp"' EXIT

while IFS='|' read -r root rel status note; do
  # skip blank lines and comments
  [[ -z "${root//[[:space:]]/}${rel//[[:space:]]/}${status//[[:space:]]/}${note//[[:space:]]/}" ]] && continue
  case "${root#"${root%%[![:space:]]*}"}" in \#*) continue ;; esac
  # A source root may be written with trailing slashes; record it without, so
  # listed paths match what the coverage scan finds.
  while [[ "$root" == */ ]]; do root="${root%/}"; done
  # A non-blank entry with no source root would be skipped above and its
  # directory never scanned; reject it instead.
  if [[ -z "${root//[[:space:]]/}" ]]; then
    printf '  %-30s %-24s FAIL: entry has no source root\n' "(none)" "$rel"
    fails=$((fails + 1))
    continue
  fi
  printf '  %-30s %-24s ' "$root" "$rel"
  echo "$root/$rel" >>"$listed_tmp"
  echo "$root" >>"$roots_tmp"
  # An entry must name a .$EXT source. Otherwise a quarantined README or
  # build file would "keep failing" and be accepted as an expected failure.
  if [[ "$rel" != *."$EXT" ]]; then
    echo "FAIL: not a .$EXT proof source"
    fails=$((fails + 1))
    continue
  fi
  if [[ "$status" != gated && "$status" != quarantine ]]; then
    echo "FAIL: status '$status' is neither 'gated' nor 'quarantine'"
    fails=$((fails + 1))
    continue
  fi
  if check_one "$root" "$rel"; then
    if [ "$status" = gated ]; then
      echo "PASS"
    else
      echo "PASS -- UNEXPECTED (quarantined module now compiles)"
      echo "        Promote '$rel' to 'gated' in $MANIFEST_FILE and update docs/status/ROADMAP.adoc."
      unexpected_pass=$((unexpected_pass + 1))
    fi
  else
    if [ "$status" = gated ]; then
      echo "FAIL"
      printf '%s\n' "${LAST_OUT//$'\n'/$'\n        '}" | sed '1s/^/        /'
      fails=$((fails + 1))
    else
      echo "fail (quarantined, expected)"
      [ -n "${note// }" ] && echo "        reason:$note"
    fi
  fi
done < "$MANIFEST_FILE"

# --- coverage: every proof on disk must be listed -----------------------------
# The anti-recurrence rule: proofs went unchecked for months because nothing
# forced them onto anyone's list.  A file absent from the MANIFEST is an error.
echo
# The scan covers $PROOF_DIR and every source root the MANIFEST names, so a new
# module beside a gated one outside $PROOF_DIR (src/interface/Abi/, say) is
# caught too, not only one under verification/proofs/.
mapfile -t scan_dirs < <({ echo "$PROOF_DIR"; sort -u "$roots_tmp"; } | sed 's#/*$##' | sort -u)
echo "=== manifest coverage (${scan_dirs[*]}) ==="
listed="$(sed 's#^\./##' "$listed_tmp" | sort -u)"
found="$(cd "$ROOT" && find -H "${scan_dirs[@]}" -name "*.$EXT" -not -path '*/build/*' -not -path '*/.git/*' 2>/dev/null | sed 's#^\./##' | sort -u)"
unlisted="$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$found") || true)"
# Stale means "the listed file does not exist". A MANIFEST may also gate
# modules outside $PROOF_DIR, such as the repository's own ABI seam under
# src/, so existence is checked on disk, not against the $PROOF_DIR scan.
missing="$(while IFS= read -r entry; do
  if [ -n "$entry" ] && [ ! -f "$ROOT/$entry" ]; then printf '%s\n' "$entry"; fi
done <<<"$listed")"

if [ -n "${unlisted//[[:space:]]/}" ]; then
  echo "FAIL: .$EXT proofs on disk but absent from $MANIFEST_FILE:"
  printf '%s\n' "$unlisted" | sed 's/^/  /'
  echo "      List each as 'gated' or 'quarantine'; new proofs are gated by default."
  fails=$((fails + 1))
fi
if [ -n "${missing//[[:space:]]/}" ]; then
  echo "FAIL: MANIFEST lists modules that do not exist (stale entries):"
  printf '%s\n' "$missing" | sed 's/^/  /'
  fails=$((fails + 1))
fi
[ -z "${unlisted//[[:space:]]/}${missing//[[:space:]]/}" ] && \
  echo "  all $(printf '%s\n' "$found" | grep -c .) .$EXT file(s) accounted for"

echo
if [ "$fails" -gt 0 ] || [ "$unexpected_pass" -gt 0 ]; then
  echo "RESULT: FAIL ($fails failure(s), $unexpected_pass unexpected pass(es))"
  exit 1
fi
echo "RESULT: PASS -- gated modules compile; quarantined modules still fail as recorded"
