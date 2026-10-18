<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) -->

# Lean 4 transcription

`Sholes/Core.lean` mirrors the total-list model and exposes the five quotient
laws. `Sholes/Equivalence.lean` and `Sholes/Lens.lean` keep the cross-prover
obligations in separate modules so a reviewer can compare the proof shape with
the Agda source.

The modules use Lean core/Std only; no Mathlib theorem is required.
