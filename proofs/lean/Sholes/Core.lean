/- SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
Hand re-proof of Sholes.Core, Equivalence, Lens and HeaderBridge in Agda.
This is not an exported Agda proof object. No Mathlib dependency. -/
import Init

namespace Sholes
inductive Byte (α : Type) where
  | cr | lf | plain : α → Byte α
inductive Token (α : Type) where
  | newline | literal : α → Token α
open Byte Token

mutual
  def tokens {α} : List (Byte α) → List (Token α)
    | [] => []
    | cr :: xs => newline :: afterCR xs
    | lf :: xs => newline :: tokens xs
    | plain a :: xs => literal a :: tokens xs
  def afterCR {α} : List (Byte α) → List (Token α)
    | [] => []
    | lf :: xs => tokens xs
    | cr :: xs => newline :: afterCR xs
    | plain a :: xs => literal a :: tokens xs
end

def renderLF {α} : List (Token α) → List (Byte α)
  | [] => []
  | newline :: ts => lf :: renderLF ts
  | literal a :: ts => plain a :: renderLF ts
def renderCRLF {α} : List (Token α) → List (Byte α)
  | [] => []
  | newline :: ts => cr :: lf :: renderCRLF ts
  | literal a :: ts => plain a :: renderCRLF ts

theorem tokens_renderLF {α} (ts : List (Token α)) : tokens (renderLF ts) = ts := by
  induction ts with
  | nil => rfl
  | cons t ts ih => cases t <;> first | rfl | exact ih | exact congrArg (List.cons _) ih
theorem tokens_renderCRLF {α} (ts : List (Token α)) : tokens (renderCRLF ts) = ts := by
  induction ts with
  | nil => rfl
  | cons t ts ih => cases t <;> first | rfl | exact ih | exact congrArg (List.cons _) ih

def canon {α} (xs : List (Byte α)) := renderLF (tokens xs)
def LEq {α} (xs ys : List (Byte α)) := tokens xs = tokens ys
theorem equiv_refl {α} (xs : List (Byte α)) : LEq xs xs := rfl
theorem equiv_sym {α} {xs ys : List (Byte α)} (h : LEq xs ys) : LEq ys xs := h.symm
theorem equiv_trans {α} {xs ys zs : List (Byte α)} (h : LEq xs ys) (k : LEq ys zs) : LEq xs zs := h.trans k
theorem canon_preserves_tokens {α} (xs : List (Byte α)) : LEq (canon xs) xs := tokens_renderLF (tokens xs)
theorem idempotent {α} (xs : List (Byte α)) : canon (canon xs) = canon xs :=
  congrArg renderLF (canon_preserves_tokens xs)
theorem invariant {α} {xs ys : List (Byte α)} (h : LEq xs ys) : canon xs = canon ys := congrArg renderLF h
theorem reflects {α} {xs ys : List (Byte α)} (h : canon xs = canon ys) : LEq xs ys :=
  (canon_preserves_tokens xs).symm.trans ((congrArg tokens h).trans (canon_preserves_tokens ys))
theorem hash_coherent {α β} (H : List (Byte α) → β) {xs ys} (h : LEq xs ys) : H (canon xs) = H (canon ys) :=
  congrArg H (invariant h)
theorem factors {α β} (f : List (Token α) → β) (xs : List (Byte α)) : f (tokens (canon xs)) = f (tokens xs) :=
  congrArg f (canon_preserves_tokens xs)

def hasBreak {α} : List (Byte α) → Bool
  | [] => false
  | cr :: _ => true
  | lf :: _ => true
  | plain _ :: xs => hasBreak xs
def hasLF {α} : List (Byte α) → Bool
  | [] => false
  | cr :: xs => hasLF xs
  | lf :: _ => true
  | plain _ :: xs => hasLF xs
def hasCR {α} : List (Byte α) → Bool
  | [] => false
  | cr :: _ => true
  | lf :: xs => hasCR xs
  | plain _ :: xs => hasCR xs
def tokenBreak {α} : List (Token α) → Bool
  | [] => false
  | newline :: _ => true
  | literal _ :: ts => tokenBreak ts

theorem render_no_CR {α} (ts : List (Token α)) : hasCR (renderLF ts) = false := by
  induction ts with
  | nil => rfl
  | cons t ts ih => cases t <;> first | rfl | exact ih | exact congrArg (List.cons _) ih
theorem tokens_break {α} (xs : List (Byte α)) : tokenBreak (tokens xs) = hasBreak xs := by
  induction xs with
  | nil => rfl
  | cons b xs ih => cases b <;> first | rfl | exact ih
theorem render_break {α} (ts : List (Token α)) : hasBreak (renderLF ts) = tokenBreak ts := by
  induction ts with
  | nil => rfl
  | cons t ts ih => cases t <;> first | rfl | exact ih | exact congrArg (List.cons _) ih
theorem render_LF {α} (ts : List (Token α)) : hasLF (renderLF ts) = tokenBreak ts := by
  induction ts with
  | nil => rfl
  | cons t ts ih => cases t <;> first | rfl | exact ih | exact congrArg (List.cons _) ih
theorem header_break_preserved {α} (xs : List (Byte α)) : hasBreak (canon xs) = hasBreak xs :=
  (render_break (tokens xs)).trans (tokens_break xs)
theorem canonical_LF_detects_all {α} (xs : List (Byte α)) : hasLF (canon xs) = hasBreak xs :=
  (render_LF (tokens xs)).trans (tokens_break xs)

inductive Mode where | text | binary
def canonicalize {α} : Mode → List (Byte α) → List (Byte α)
  | .text, xs => canon xs
  | .binary, xs => xs
theorem binary_preserved {α} (xs : List (Byte α)) : canonicalize .binary xs = xs := rfl

inductive Environment where | unix | windows
def render {α} : Environment → List (Token α) → List (Byte α)
  | .unix => renderLF
  | .windows => renderCRLF
theorem parse_render {α} (e : Environment) (ts : List (Token α)) : tokens (render e ts) = ts := by
  cases e
  exact tokens_renderLF ts
  exact tokens_renderCRLF ts
theorem put_get {α} (e : Environment) (ts : List (Token α)) : tokens (render e ts) = ts := parse_render e ts
theorem get_put_quotient {α} (e : Environment) (xs : List (Byte α)) : LEq (render e (tokens xs)) xs := parse_render e (tokens xs)
theorem get_put_normal_view {α} (e : Environment) (ts : List (Token α)) : render e (tokens (render e ts)) = render e ts :=
  congrArg (render e) (parse_render e ts)
theorem no_raw_inverse {α} (restore : List (Byte α) → List (Byte α))
    (p : restore (canon [cr]) = [cr]) (q : restore (canon [lf]) = [lf]) : False := by
  have bad : ([cr] : List (Byte α)) = [lf] := p.symm.trans q
  cases bad

def pairOnly {α} : List (Byte α) → Bool
  | [] => false
  | cr :: lf :: _ => true
  | cr :: cr :: xs => pairOnly (cr :: xs)
  | cr :: plain _ :: xs => pairOnly xs
  | [cr] => false
  | lf :: xs => pairOnly xs
  | plain _ :: xs => pairOnly xs
theorem pair_misses_CR {α} : pairOnly ([cr] : List (Byte α)) = false := rfl
theorem pair_misses_LF {α} : pairOnly ([lf] : List (Byte α)) = false := rfl
theorem normalizing_does_not_fix_pair_check {α} : pairOnly (canon ([cr, lf] : List (Byte α))) = false := rfl
theorem pair_misses_every_canonical_break {α} (ts : List (Token α)) : pairOnly (renderLF ts) = false := by
  induction ts with
  | nil => rfl
  | cons t ts ih => cases t <;> first | rfl | exact ih | exact congrArg (List.cons _) ih
theorem trailing_break_retained {α} : tokens ([lf] : List (Byte α)) = [newline] := rfl
theorem two_breaks_retained {α} : tokens ([cr, cr, lf] : List (Byte α)) = [newline, newline] := rfl

#print axioms idempotent
#print axioms reflects
#print axioms hash_coherent
#print axioms no_raw_inverse
#print axioms header_break_preserved
#print axioms canonical_LF_detects_all
#print axioms pair_misses_every_canonical_break
inductive State where | ready | suppressLF
open State
 def next {α} (_ : State) : Byte α → State
  | cr => suppressLF
  | lf => ready
  | plain _ => ready
 def emit {α} : State → Byte α → List (Token α)
  | _, cr => [newline]
  | ready, lf => [newline]
  | suppressLF, lf => []
  | _, plain a => [literal a]
 def finish {α} (q : State) : List (Byte α) → State
  | [] => q
  | x :: xs => finish (next q x) xs
 def output {α} (q : State) : List (Byte α) → List (Token α)
  | [] => []
  | x :: xs => emit q x ++ output (next q x) xs
 theorem finish_append {α} (q : State) (xs ys : List (Byte α)) :
    finish q (xs ++ ys) = finish (finish q xs) ys := by
  induction xs generalizing q with
  | nil => rfl
  | cons x xs ih => exact ih (next q x)
 theorem append_assoc_core {α} (xs ys zs : List α) : (xs ++ ys) ++ zs = xs ++ (ys ++ zs) := by
  induction xs with
  | nil => rfl
  | cons x xs ih => exact congrArg (List.cons x) ih
 theorem output_append {α} (q : State) (xs ys : List (Byte α)) :
    output q (xs ++ ys) = output q xs ++ output (finish q xs) ys := by
  induction xs generalizing q with
  | nil => rfl
  | cons x xs ih =>
    exact (congrArg (emit q x ++ ·) (ih (next q x))).trans
      (append_assoc_core (emit q x) (output (next q x) xs) (output (finish (next q x) xs) ys)).symm
 theorem output_spec {α} (xs : List (Byte α)) (q : State) :
    output q xs = match q with | ready => tokens xs | suppressLF => afterCR xs := by
  induction xs generalizing q with
  | nil => cases q <;> rfl
  | cons b xs ih =>
    cases q <;> cases b <;>
      first | exact ih ready | exact congrArg (List.cons _) (ih ready)
            | exact congrArg (List.cons _) (ih suppressLF)
 theorem output_tokens {α} (xs : List (Byte α)) : output ready xs = tokens xs := output_spec xs ready
 theorem output_afterCR {α} (xs : List (Byte α)) : output suppressLF xs = afterCR xs := output_spec xs suppressLF
 theorem chunk_refinement {α} (xs ys : List (Byte α)) :
    output ready xs ++ output (finish ready xs) ys = tokens (xs ++ ys) :=
  (output_append ready xs ys).symm.trans (output_tokens (xs ++ ys))
 theorem reset_is_wrong {α} :
    output ready ([cr] : List (Byte α)) ++ output ready [lf] ≠ tokens [cr, lf] := by
  intro h
  cases h
#print axioms chunk_refinement
#print axioms reset_is_wrong
end Sholes
