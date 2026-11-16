{-# OPTIONS --safe --without-K --cubical-compatible #-}
-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
module Sholes.Lens where
open import Sholes.Equivalence public

data Environment : Set where
  unix windows : Environment

render : ∀ {A} → Environment → List (Token A) → List (Byte A)
render unix = renderLF
render windows = renderCRLF

parse-render : ∀ {A} (e : Environment) (ts : List (Token A)) → tokens (render e ts) ≡ ts
parse-render unix = tokens-renderLF
parse-render windows = tokens-renderCRLF

-- The well-behaved interface has tokens as its canonical store. An arbitrary
-- raw byte stream is a view only up to line-token equivalence, not byte equality.
put-get : ∀ {A} (e : Environment) (ts : List (Token A)) → tokens (render e ts) ≡ ts
put-get = parse-render

get-put-quotient : ∀ {A} (e : Environment) (xs : List (Byte A)) → render e (tokens xs) ≈ xs
get-put-quotient e xs = parse-render e (tokens xs)

get-put-normal-view : ∀ {A} (e : Environment) (ts : List (Token A)) →
  render e (tokens (render e ts)) ≡ render e ts
get-put-normal-view e ts = cong (render e) (parse-render e ts)

-- Exact recovery from canonical bytes alone is impossible: lone CR and LF
-- have the same canonical output but distinct original representations.
cr-not-lf : ∀ {A} → _≡_ {A = List (Byte A)} (cr ∷ []) (lf ∷ []) → ⊥
cr-not-lf ()

no-raw-inverse : ∀ {A} (restore : List (Byte A) → List (Byte A)) →
  restore (canon (cr ∷ [])) ≡ cr ∷ [] →
  restore (canon (lf ∷ [])) ≡ lf ∷ [] → ⊥
no-raw-inverse restore p q = cr-not-lf (trans (sym p) q)
