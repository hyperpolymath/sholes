#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Check the publication-facing cross-prover tree under proofs/.
# Missing toolchains are failures, never successful skips.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

files=(
  proofs/agda/Sholes/Core.agda
  proofs/agda/Sholes/Equivalence.agda
  proofs/agda/Sholes/Lens.agda
  proofs/lean/Sholes/Core.lean
  proofs/lean/Sholes/Equivalence.lean
  proofs/lean/Sholes/Lens.lean
  proofs/coq/Sholes_Core.v
)
for file in "${files[@]}"; do
  [ -f "$file" ] || { echo "FAIL: missing publication proof $file" >&2; exit 1; }
done

command -v agda >/dev/null || { echo "FAIL: agda is required" >&2; exit 1; }
command -v lean >/dev/null || { echo "FAIL: lean is required" >&2; exit 1; }
command -v coqc >/dev/null || { echo "FAIL: coqc is required" >&2; exit 1; }

agda --safe -i proofs/agda proofs/agda/Sholes/Core.agda
agda --safe -i proofs/agda proofs/agda/Sholes/Equivalence.agda
agda --safe -i proofs/agda proofs/agda/Sholes/Lens.agda
lean -i proofs/lean proofs/lean/Sholes/Core.lean
lean -i proofs/lean proofs/lean/Sholes/Equivalence.lean
lean -i proofs/lean proofs/lean/Sholes/Lens.lean
coqc proofs/coq/Sholes_Core.v

echo "PASS: publication Agda, Lean 4, and Coq/Rocq proofs checked"
