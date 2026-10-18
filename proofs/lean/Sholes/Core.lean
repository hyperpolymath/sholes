-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

import Std

namespace Sholes

/-! A direct Lean 4 transcription of the Agda quotient model. -/

abbrev Byte := Fin 256
abbrev Stream := List Byte

def cr : Byte := ⟨13, by decide⟩
def lf : Byte := ⟨10, by decide⟩
def nul : Byte := ⟨0, by decide⟩

inductive Encoding where
  | utf8

def utf8 : Encoding := Encoding.utf8

def containsNul : Stream → Bool
  | [] => false
  | b :: bs => if b = nul then true else containsNul bs

def Classifier (s : Stream) : Sum Unit Encoding :=
  if containsNul s = true then Sum.inl () else Sum.inr utf8

def canonText : Stream → Stream
  | [] => []
  | b :: [] => if b = cr then [lf] else [b]
  | b :: c :: bs =>
      if b = cr then
        if c = lf then lf :: canonText bs
        else lf :: canonText (c :: bs)
      else b :: canonText (c :: bs)
termination_by s => s.length
decreasing_by simp_wf

def canon (s : Stream) : Stream :=
  if containsNul s = true then s else canonText s

def Binary (s : Stream) : Prop := containsNul s = true

def NoCR : Stream → Prop
  | [] => True
  | b :: bs => b ≠ cr ∧ NoCR bs

def NoNul : Stream → Prop
  | [] => True
  | b :: bs => b ≠ nul ∧ NoNul bs

lemma cr_ne_lf : cr ≠ lf := by decide
lemma cr_ne_nul : cr ≠ nul := by decide
lemma lf_ne_cr : lf ≠ cr := by decide
lemma lf_ne_nul : lf ≠ nul := by decide

/-- The transducer never emits a carriage return on its text branch. -/
theorem canonText_no_cr (s : Stream) : NoCR (canonText s) := by
  cases s with
  | nil => simp [canonText, NoCR]
  | cons b rest =>
      cases rest with
      | nil =>
          by_cases hb : b = cr <;> simp [canonText, NoCR, hb, lf_ne_cr]
      | cons c bs =>
          by_cases hb : b = cr
          · by_cases hc : c = lf
            · simp [canonText, NoCR, hb, hc, lf_ne_cr,
                canonText_no_cr bs]
            · simp [canonText, NoCR, hb, hc, lf_ne_cr,
                canonText_no_cr (c :: bs)]
          · simp [canonText, NoCR, hb, canonText_no_cr (c :: bs)]
termination_by s => s.length
decreasing_by simp_wf

/-- Replacing line terminators is identity on a list containing no CR. -/
theorem canonText_of_no_cr (s : Stream) (h : NoCR s) : canonText s = s := by
  cases s with
  | nil => rfl
  | cons b rest =>
      cases rest with
      | nil =>
          by_cases hb : b = cr
          · exact False.elim (h.1 hb)
          · simp [canonText, hb]
      | cons c bs =>
          by_cases hb : b = cr
          · exact False.elim (h.1 hb)
          · simp [canonText, hb, canonText_of_no_cr (c :: bs) h.2]
termination_by s => s.length
decreasing_by simp_wf

/-- The generated canonical text remains NUL-free when the input is. -/
theorem canonText_no_nul (s : Stream) (h : NoNul s) : NoNul (canonText s) := by
  cases s with
  | nil => simp [canonText, NoNul]
  | cons b rest =>
      cases rest with
      | nil =>
          by_cases hb : b = cr
          · simp [canonText, NoNul, hb, lf_ne_nul]
          · simp [canonText, NoNul, hb, h.1]
      | cons c bs =>
          by_cases hb : b = cr
          · by_cases hc : c = lf
            · simp [canonText, NoNul, hb, hc, lf_ne_nul,
                canonText_no_nul bs h.2.2]
            · simp [canonText, NoNul, hb, hc, lf_ne_nul,
                canonText_no_nul (c :: bs) h.2]
          · simp [canonText, NoNul, hb, h.1,
              canonText_no_nul (c :: bs) h.2]
termination_by s => s.length
decreasing_by simp_wf

lemma noNul_of_false : ∀ {s : Stream}, containsNul s = false → NoNul s
  | [], _ => trivial
  | b :: bs, h => by
      by_cases hb : b = nul
      · simp [containsNul, hb] at h
      · exact ⟨hb, noNul_of_false (s := bs) (by simpa [containsNul, hb] using h)⟩

lemma containsNul_of_noNul : ∀ {s : Stream}, NoNul s → containsNul s = false
  | [], _ => rfl
  | b :: bs, h => by
      simp [containsNul, h.1, containsNul_of_noNul h.2]

/-- Idempotence of the quotient projection. -/
theorem idempotence (s : Stream) : canon (canon s) = canon s := by
  by_cases h : containsNul s = true
  · simp [canon, h]
  · have hs : NoNul s := noNul_of_false h
    have hcanon : containsNul (canonText s) = false :=
      containsNul_of_noNul (canonText_no_nul s hs)
    simp [canon, h, hcanon]
    exact canonText_of_no_cr (canonText s) (canonText_no_cr (canonText s))

/-- Binary streams are passed through without interference. -/
theorem binary_preservation {s : Stream} (h : Binary s) : canon s = s := by
  simp [Binary, canon, h]

/-- The quotient relation is equality of canonical line-token sequences. -/
def lines (s : Stream) : Stream := canon s
def Equivalent (s₁ s₂ : Stream) : Prop := lines s₁ = lines s₂

theorem equivalence_invariance {s₁ s₂ : Stream} (h : Equivalent s₁ s₂) :
    canon s₁ = canon s₂ := h

/-- Cryptographic coherence is parametric in the hash function. -/
theorem cryptographic_coherence {α : Type} (H : Stream → α)
    {s₁ s₂ : Stream} (h : Equivalent s₁ s₂) :
    H (canon s₁) = H (canon s₂) := congrArg H h

end Sholes
