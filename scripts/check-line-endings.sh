#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# Canonical line-ending proof check, including rejection controls.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
evidence=${EVIDENCE_DIR:-$(mktemp -d -t sholes-evidence.XXXXXXXX)}
mkdir -p "$evidence"
evidence=$(cd "$evidence" && pwd)
work=$(mktemp -d -t sholes-proofs.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
cp -R "$root/verification/proofs/agda" "$root/verification/proofs/coq" "$root/verification/proofs/cubical" "$work/"
cp -R "$root/verification/proofs/lean4" "$work/lean"
# Remove only generated files in the freshly allocated proof scratch directory.
find "$work" -type f \( -name '*.agdai' -o -name '*.olean' -o -name '*.vo' \) -delete
agda=${AGDA:-agda}
lean=${LEAN:-lean}
coqc=${COQC:-coqc}
coqchk=${COQCHK:-coqchk}
for tool in "$agda" "$lean" "$coqc" "$coqchk"; do
  command -v "$tool" >/dev/null || { echo "FAIL: missing $tool" >&2; exit 1; }
done
{ "$agda" --version; "$lean" --version; "$coqc" --version; } > "$evidence/versions.log"
(cd "$root"; git rev-parse HEAD; git diff --stat; find verification/proofs -type f \( -name '*.agda' -o -name '*.lean' -o -name '*.v' \) -print0 | sort -z | xargs -0 sha256sum) > "$evidence/source-identity.log"
for module in Core Equivalence Lens HeaderBridge Wire Streaming; do
  (cd "$work/agda"; "$agda" --safe --without-K --cubical-compatible --double-check --warning=error "Sholes/$module.agda") > "$evidence/agda-$module.log" 2>&1
done
(cd "$work"; "$agda" --safe --cubical --double-check --warning=error -i agda -i cubical cubical/SholesCubical.agda) > "$evidence/cubical.log" 2>&1
(cd "$work/lean"; "$lean" -o Sholes/Core.olean Sholes/Core.lean) > "$evidence/lean.log" 2>&1
{
  printf 'import Sholes.Core\n'
  sed -n 's/^[[:space:]]*theorem \([A-Za-z0-9_]*\).*/#print axioms Sholes.\1/p' "$work/lean/Sholes/Core.lean"
} > "$work/lean/Audit.lean"
(cd "$work/lean"; LEAN_PATH=. "$lean" Audit.lean) > "$evidence/lean-assumptions.log" 2>&1
if grep -Eq "depends on axioms:|declaration uses 'sorry'|error:" "$evidence/lean-assumptions.log" "$evidence/lean.log"; then
  echo 'FAIL: Lean assumption audit' >&2; exit 1
fi
(cd "$work/coq"; "$coqc" Sholes_Core.v; "$coqchk" -silent Sholes_Core) > "$evidence/rocq.log" 2>&1
{
  printf 'Require Import Sholes_Core.\n'
  sed -n 's/^Lemma \([A-Za-z0-9_]*\).*/Print Assumptions \1./p' "$work/coq/Sholes_Core.v"
} > "$work/coq/Audit.v"
(cd "$work/coq"; "$coqc" Audit.v) > "$evidence/rocq-assumptions.log" 2>&1
if grep -q 'Axioms:' "$evidence/rocq-assumptions.log"; then
  echo 'FAIL: Rocq assumption audit' >&2; exit 1
fi

# Each tool must reject the same false claim. Positive checks above establish
# that the tool, imports and source paths work before an exit failure counts.
cat > "$work/agda/Wrong.agda" <<'AGDA'
{-# OPTIONS --safe --without-K --cubical-compatible #-}
module Wrong where
open import Sholes.HeaderBridge
bad : hasBreak {Bool} (canon (cr ∷ [])) ≡ false
bad = refl
AGDA
if (cd "$work/agda"; "$agda" --safe --without-K --cubical-compatible --double-check Wrong.agda) > "$evidence/agda-negative.log" 2>&1; then
  echo 'FAIL: Agda accepted false header claim' >&2; exit 1
fi
grep -q 'true != false' "$evidence/agda-negative.log"
cat > "$work/lean/Wrong.lean" <<'LEAN'
import Sholes.Core
open Sholes
theorem bad : hasBreak (canon ([Byte.cr] : List (Byte Bool))) = false := by rfl
LEAN
if (cd "$work/lean"; LEAN_PATH=. "$lean" Wrong.lean) > "$evidence/lean-negative.log" 2>&1; then
  echo 'FAIL: Lean accepted false header claim' >&2; exit 1
fi
grep -q 'rfl' "$evidence/lean-negative.log"
cat > "$work/coq/Wrong.v" <<'COQ'
Require Import Sholes_Core.
Lemma bad : hasBreak (canon (cons (@cr bool) nil)) = false.
Proof. reflexivity. Qed.
COQ
if (cd "$work/coq"; "$coqc" Wrong.v) > "$evidence/rocq-negative.log" 2>&1; then
  echo 'FAIL: Rocq accepted false header claim' >&2; exit 1
fi
grep -q 'Unable to unify' "$evidence/rocq-negative.log"
printf 'PASS: compatible Agda; full Cubical; Lean; Rocq/coqchk; assumption audits; three rejection controls.\nEvidence: %s\n' "$evidence"
printf 'NOT CHECKED: automatic witness transport; Lean/Rocq Wire; Lean4Lean; executable/compiler refinement; classifier accuracy.\n'
