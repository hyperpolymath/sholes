{-# OPTIONS --safe --without-K --cubical-compatible #-}
-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
module Sholes.HeaderBridge where
open import Sholes.Equivalence public

tokens-break : ∀ {A} (xs : List (Byte A)) → tokenBreak (tokens xs) ≡ hasBreak xs
tokens-break [] = refl
tokens-break (cr ∷ xs) = refl
tokens-break (lf ∷ xs) = refl
tokens-break (plain _ ∷ xs) = tokens-break xs

render-break : ∀ {A} (ts : List (Token A)) → hasBreak (renderLF ts) ≡ tokenBreak ts
render-break [] = refl
render-break (newline ∷ ts) = refl
render-break (literal _ ∷ ts) = render-break ts

render-LF : ∀ {A} (ts : List (Token A)) → hasLF (renderLF ts) ≡ tokenBreak ts
render-LF [] = refl
render-LF (newline ∷ ts) = refl
render-LF (literal _ ∷ ts) = render-LF ts

header-break-preserved : ∀ {A} (xs : List (Byte A)) → hasBreak (canon xs) ≡ hasBreak xs
header-break-preserved xs = trans (render-break (tokens xs)) (tokens-break xs)

canonical-LF-detects-all : ∀ {A} (xs : List (Byte A)) → hasLF (canon xs) ≡ hasBreak xs
canonical-LF-detects-all xs = trans (render-LF (tokens xs)) (tokens-break xs)

-- Model of checking only adjacent CRLF, as Proven's current Zig shim does.
pairOnly : ∀ {A} → List (Byte A) → Bool
pairOnly [] = false
pairOnly (cr ∷ lf ∷ _) = true
pairOnly (cr ∷ cr ∷ xs) = pairOnly (cr ∷ xs)
pairOnly (cr ∷ plain _ ∷ xs) = pairOnly xs
pairOnly (cr ∷ []) = false
pairOnly (lf ∷ xs) = pairOnly xs
pairOnly (plain _ ∷ xs) = pairOnly xs

pair-misses-CR : ∀ {A} → pairOnly {A} (cr ∷ []) ≡ false
pair-misses-CR = refl
pair-misses-LF : ∀ {A} → pairOnly {A} (lf ∷ []) ≡ false
pair-misses-LF = refl
normalizing-does-not-fix-pair-check : ∀ {A} → pairOnly {A} (canon (cr ∷ lf ∷ [])) ≡ false
normalizing-does-not-fix-pair-check = refl

pair-misses-every-canonical-break : ∀ {A} (ts : List (Token A)) → pairOnly (renderLF ts) ≡ false
pair-misses-every-canonical-break [] = refl
pair-misses-every-canonical-break (newline ∷ ts) = pair-misses-every-canonical-break ts
pair-misses-every-canonical-break (literal _ ∷ ts) = pair-misses-every-canonical-break ts
