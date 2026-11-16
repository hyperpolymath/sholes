{-# OPTIONS --safe --cubical #-}
-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-- Separate full-Cubical consumer of the compatible source proofs.
module SholesCubical where
open import Sholes.HeaderBridge
open import Sholes.Lens
open import Sholes.Wire
open import Sholes.Streaming
open import Agda.Builtin.Cubical.Path renaming (_≡_ to _≡ᵖ_)

equality-path : ∀ {A : Set} {x y : A} → x ≡ y → x ≡ᵖ y
equality-path {x = x} refl i = x

idempotent-path : ∀ {A} (xs : List (Byte A)) → canon (canon xs) ≡ᵖ canon xs
idempotent-path xs = equality-path (idempotent xs)

header-path : ∀ {A} (xs : List (Byte A)) → hasBreak (canon xs) ≡ᵖ hasBreak xs
header-path xs = equality-path (header-break-preserved xs)

octet-roundtrip-path : (b : Octet) → encode (decode b) ≡ᵖ b
octet-roundtrip-path b = equality-path (wire-roundtrip b)

chunk-path : ∀ {A} (xs ys : List (Byte A)) →
  output ready xs ++ output (finish ready xs) ys ≡ᵖ tokens (xs ++ ys)
chunk-path xs ys = equality-path (chunk-refinement xs ys)
