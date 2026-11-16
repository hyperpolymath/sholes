{-# OPTIONS --safe --without-K --cubical-compatible #-}
-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
module Sholes.Core where

open import Agda.Builtin.Bool public using (Bool; true; false)
open import Agda.Builtin.List public using (List; []; _∷_)
open import Agda.Builtin.Equality public using (_≡_; refl)

data ⊥ : Set where

cong : ∀ {A B : Set} (f : A → B) {x y} → x ≡ y → f x ≡ f y
cong f refl = refl
sym : ∀ {A : Set} {x y : A} → x ≡ y → y ≡ x
sym refl = refl
trans : ∀ {A : Set} {x y z : A} → x ≡ y → y ≡ z → x ≡ z
trans refl q = q

-- Payloads exclude CR and LF by construction. Wire.agda supplies the
-- concrete 256-element alphabet and its round-trip to numeric octets.
data Byte (A : Set) : Set where
  cr lf : Byte A
  plain : A → Byte A

data Token (A : Set) : Set where
  newline : Token A
  literal : A → Token A

-- CRLF is one break; a lone CR or LF is also one break. Repeated breaks,
-- all payloads, and a final break are retained. No text/binary heuristic.
mutual
  tokens : ∀ {A} → List (Byte A) → List (Token A)
  tokens [] = []
  tokens (cr ∷ xs) = newline ∷ afterCR xs
  tokens (lf ∷ xs) = newline ∷ tokens xs
  tokens (plain a ∷ xs) = literal a ∷ tokens xs

  afterCR : ∀ {A} → List (Byte A) → List (Token A)
  afterCR [] = []
  afterCR (lf ∷ xs) = tokens xs
  afterCR (cr ∷ xs) = newline ∷ afterCR xs
  afterCR (plain a ∷ xs) = literal a ∷ tokens xs

renderLF : ∀ {A} → List (Token A) → List (Byte A)
renderLF [] = []
renderLF (newline ∷ ts) = lf ∷ renderLF ts
renderLF (literal a ∷ ts) = plain a ∷ renderLF ts

renderCRLF : ∀ {A} → List (Token A) → List (Byte A)
renderCRLF [] = []
renderCRLF (newline ∷ ts) = cr ∷ lf ∷ renderCRLF ts
renderCRLF (literal a ∷ ts) = plain a ∷ renderCRLF ts

tokens-renderLF : ∀ {A} (ts : List (Token A)) → tokens (renderLF ts) ≡ ts
tokens-renderLF [] = refl
tokens-renderLF (newline ∷ ts) = cong (newline ∷_) (tokens-renderLF ts)
tokens-renderLF (literal a ∷ ts) = cong (literal a ∷_) (tokens-renderLF ts)

tokens-renderCRLF : ∀ {A} (ts : List (Token A)) → tokens (renderCRLF ts) ≡ ts
tokens-renderCRLF [] = refl
tokens-renderCRLF (newline ∷ ts) = cong (newline ∷_) (tokens-renderCRLF ts)
tokens-renderCRLF (literal a ∷ ts) = cong (literal a ∷_) (tokens-renderCRLF ts)

canon : ∀ {A} → List (Byte A) → List (Byte A)
canon xs = renderLF (tokens xs)

hasBreak : ∀ {A} → List (Byte A) → Bool
hasBreak [] = false
hasBreak (cr ∷ _) = true
hasBreak (lf ∷ _) = true
hasBreak (plain _ ∷ xs) = hasBreak xs

hasLF : ∀ {A} → List (Byte A) → Bool
hasLF [] = false
hasLF (cr ∷ xs) = hasLF xs
hasLF (lf ∷ _) = true
hasLF (plain _ ∷ xs) = hasLF xs

tokenBreak : ∀ {A} → List (Token A) → Bool
tokenBreak [] = false
tokenBreak (newline ∷ _) = true
tokenBreak (literal _ ∷ ts) = tokenBreak ts

hasCR : ∀ {A} → List (Byte A) → Bool
hasCR [] = false
hasCR (cr ∷ _) = true
hasCR (lf ∷ xs) = hasCR xs
hasCR (plain _ ∷ xs) = hasCR xs

render-no-CR : ∀ {A} (ts : List (Token A)) → hasCR (renderLF ts) ≡ false
render-no-CR [] = refl
render-no-CR (newline ∷ ts) = render-no-CR ts
render-no-CR (literal _ ∷ ts) = render-no-CR ts

data Mode : Set where
  text binary : Mode

canonicalize : ∀ {A} → Mode → List (Byte A) → List (Byte A)
canonicalize text xs = canon xs
canonicalize binary xs = xs

binary-preserved : ∀ {A} (xs : List (Byte A)) → canonicalize binary xs ≡ xs
binary-preserved xs = refl

-- Counterexamples to erasing a trailing break or collapsing repeated ones.
trailing-break-retained : ∀ {A} → tokens {A} (lf ∷ []) ≡ newline ∷ []
trailing-break-retained = refl
two-breaks-retained : ∀ {A} → tokens {A} (cr ∷ cr ∷ lf ∷ []) ≡ newline ∷ newline ∷ []
two-breaks-retained = refl
