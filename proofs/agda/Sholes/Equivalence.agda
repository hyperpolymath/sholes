-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

{-# OPTIONS --safe #-}

module Sholes.Equivalence where

open import Data.List using (List)
open import Relation.Binary.PropositionalEquality using (_≡_; refl; sym; trans)
open import Sholes.Core

------------------------------------------------------------------------
-- Quotient interface
------------------------------------------------------------------------

record IsEquivalence (R : Stream → Stream → Set) : Set where
  field
    reflexive  : (s : Stream) → R s s
    symmetric  : {s t : Stream} → R s t → R t s
    transitive : {s t u : Stream} → R s t → R t u → R s u

≈LE-isEquivalence : IsEquivalence _≈LE_
≈LE-isEquivalence = record
  { reflexive = λ _ → refl
  ; symmetric = λ h → sym h
  ; transitive = λ h k → trans h k
  }

-- A canonical representative is a fixed point of the projection.
record IsCanonical (s : Stream) : Set where
  field
    fixed : canon s ≡ s

canonical-output : (s : Stream) → IsCanonical (canon s)
canonical-output s = record { fixed = idempotence s }

-- The quotient's representative is unique: two representatives in the same
-- class are propositionally equal because both are fixed points.
unique-representative : {s t : Stream} → s ≈LE t →
  canon s ≡ canon t
unique-representative = equivalence-invariance

-- Hashing is deliberately abstract.  The proof does not assume collision
-- resistance; it proves only the coherence demanded by equal canonical bytes.
hash-coherent : {A : Set} (H : Stream → A) →
  {s t : Stream} → s ≈LE t → H (canon s) ≡ H (canon t)
hash-coherent = cryptographic-coherence
