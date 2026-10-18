-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

import Sholes.Core

namespace Sholes

def LineEquivalent (s₁ s₂ : Stream) : Prop := canon s₁ = canon s₂

theorem line_equivalence_refl (s : Stream) : LineEquivalent s s :=
  idempotence s

theorem line_equivalence_symm {s₁ s₂ : Stream} :
    LineEquivalent s₁ s₂ → LineEquivalent s₂ s₁ := by
  intro h
  exact h.symm

theorem line_equivalence_trans {s₁ s₂ s₃ : Stream} :
    LineEquivalent s₁ s₂ → LineEquivalent s₂ s₃ → LineEquivalent s₁ s₃ := by
  intro h₁ h₂
  exact h₁.trans h₂

theorem hash_coherence {α : Type} (H : Stream → α)
    {s₁ s₂ : Stream} (h : LineEquivalent s₁ s₂) :
    H (canon s₁) = H (canon s₂) := congrArg H h

end Sholes
