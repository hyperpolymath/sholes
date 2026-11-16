{-# OPTIONS --safe --without-K --cubical-compatible #-}
-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
module Sholes.Streaming where
open import Sholes.Core

infixr 5 _++_
_++_ : ∀ {A : Set} → List A → List A → List A
[] ++ ys = ys
(x ∷ xs) ++ ys = x ∷ (xs ++ ys)

++-assoc : ∀ {A : Set} (xs ys zs : List A) → (xs ++ ys) ++ zs ≡ xs ++ (ys ++ zs)
++-assoc [] ys zs = refl
++-assoc (x ∷ xs) ys zs = cong (x ∷_) (++-assoc xs ys zs)

data State : Set where
  ready suppressLF : State

next : ∀ {A} → State → Byte A → State
next _ cr = suppressLF
next _ lf = ready
next _ (plain _) = ready

emit : ∀ {A} → State → Byte A → List (Token A)
emit _ cr = newline ∷ []
emit ready lf = newline ∷ []
emit suppressLF lf = []
emit _ (plain a) = literal a ∷ []

finish : ∀ {A} → State → List (Byte A) → State
finish q [] = q
finish q (x ∷ xs) = finish (next q x) xs

output : ∀ {A} → State → List (Byte A) → List (Token A)
output q [] = []
output q (x ∷ xs) = emit q x ++ output (next q x) xs

finish-append : ∀ {A} (q : State) (xs ys : List (Byte A)) →
  finish q (xs ++ ys) ≡ finish (finish q xs) ys
finish-append q [] ys = refl
finish-append q (x ∷ xs) ys = finish-append (next q x) xs ys

output-append : ∀ {A} (q : State) (xs ys : List (Byte A)) →
  output q (xs ++ ys) ≡ output q xs ++ output (finish q xs) ys
output-append q [] ys = refl
output-append q (x ∷ xs) ys = trans
  (cong (emit q x ++_) (output-append (next q x) xs ys))
  (sym (++-assoc (emit q x) (output (next q x) xs) (output (finish (next q x) xs) ys)))

mutual
  output-tokens : ∀ {A} (xs : List (Byte A)) → output ready xs ≡ tokens xs
  output-tokens [] = refl
  output-tokens (cr ∷ xs) = cong (newline ∷_) (output-afterCR xs)
  output-tokens (lf ∷ xs) = cong (newline ∷_) (output-tokens xs)
  output-tokens (plain a ∷ xs) = cong (literal a ∷_) (output-tokens xs)

  output-afterCR : ∀ {A} (xs : List (Byte A)) → output suppressLF xs ≡ afterCR xs
  output-afterCR [] = refl
  output-afterCR (cr ∷ xs) = cong (newline ∷_) (output-afterCR xs)
  output-afterCR (lf ∷ xs) = output-tokens xs
  output-afterCR (plain a ∷ xs) = cong (literal a ∷_) (output-tokens xs)

-- State must cross the chunk boundary, even across empty chunks. CR is
-- emitted eagerly, so EOF does not discard a pending lone CR.
chunk-refinement : ∀ {A} (xs ys : List (Byte A)) →
  output ready xs ++ output (finish ready xs) ys ≡ tokens (xs ++ ys)
chunk-refinement xs ys = trans (sym (output-append ready xs ys)) (output-tokens (xs ++ ys))

reset-is-wrong : ∀ {A} →
  _≡_ {A = List (Token A)} (output ready (cr ∷ []) ++ output ready (lf ∷ []))
    (tokens (cr ∷ lf ∷ [])) → ⊥
reset-is-wrong ()
