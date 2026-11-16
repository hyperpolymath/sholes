{-# OPTIONS --safe --without-K --cubical-compatible #-}
-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
module Sholes.Equivalence where
open import Sholes.Core public

infix 4 _≈_
_≈_ : ∀ {A} → List (Byte A) → List (Byte A) → Set
xs ≈ ys = tokens xs ≡ tokens ys

equiv-refl : ∀ {A} (xs : List (Byte A)) → xs ≈ xs
equiv-refl xs = refl
equiv-sym : ∀ {A} {xs ys : List (Byte A)} → xs ≈ ys → ys ≈ xs
equiv-sym = sym
equiv-trans : ∀ {A} {xs ys zs : List (Byte A)} → xs ≈ ys → ys ≈ zs → xs ≈ zs
equiv-trans = trans

canon-preserves-tokens : ∀ {A} (xs : List (Byte A)) → canon xs ≈ xs
canon-preserves-tokens xs = tokens-renderLF (tokens xs)

idempotent : ∀ {A} (xs : List (Byte A)) → canon (canon xs) ≡ canon xs
idempotent xs = cong renderLF (canon-preserves-tokens xs)

invariant : ∀ {A} {xs ys : List (Byte A)} → xs ≈ ys → canon xs ≡ canon ys
invariant = cong renderLF

reflects : ∀ {A} {xs ys : List (Byte A)} → canon xs ≡ canon ys → xs ≈ ys
reflects {xs = xs} {ys} eq = trans (sym (canon-preserves-tokens xs))
  (trans (cong tokens eq) (canon-preserves-tokens ys))

-- Congruence for ANY function H. This is not hash injectivity or collision resistance.
hash-coherent : ∀ {A B} (H : List (Byte A) → B) {xs ys} → xs ≈ ys → H (canon xs) ≡ H (canon ys)
hash-coherent H eq = cong H (invariant eq)

-- Any function on token sequences factors through the canonical projection.
factors : ∀ {A B} (f : List (Token A) → B) (xs : List (Byte A)) →
  f (tokens (canon xs)) ≡ f (tokens xs)
factors f xs = cong f (canon-preserves-tokens xs)
