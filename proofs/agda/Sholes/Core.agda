-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

{-# OPTIONS --safe #-}

module Sholes.Core where

open import Data.Bool using (Bool; true; false)
open import Data.Empty using (⊥; ⊥-elim)
open import Data.Fin using (Fin; #_; _≟_)
open import Data.List using (List; []; _∷_)
open import Data.Product using (_×_; _,_; proj₂)
open import Data.Unit using (⊤; tt)
open import Relation.Binary.PropositionalEquality using (_≡_; _≢_; refl; cong)
open import Relation.Nullary using (yes; no)

------------------------------------------------------------------------
-- The alphabet, the classifier, and the executable projection
------------------------------------------------------------------------

Byte : Set
Byte = Fin 256

Stream : Set
Stream = List Byte

cr lf nul : Byte
cr  = # 13
lf  = # 10
nul = # 0

-- These two distinct finite values are reduced by the Fin equality decision
-- procedure.  Keeping the witnesses here makes all later binary/text proofs
-- constructive rather than relying on a trusted arithmetic axiom.
lf≢cr : lf ≢ cr
lf≢cr ()

lf≢nul : lf ≢ nul
lf≢nul ()

data Encoding : Set where
  UTF8 : Encoding

utf8 : Encoding
utf8 = UTF8

data Classification : Set where
  binary : Classification
  text   : Encoding → Classification

containsNul : Stream → Bool
containsNul [] = false
containsNul (b ∷ bs) with b ≟ nul
... | yes _ = true
... | no _  = containsNul bs

classify : Stream → Classification
classify s with containsNul s
... | true  = binary
... | false = text utf8

Binary : Stream → Set
Binary s = containsNul s ≡ true

NoNul : Stream → Set
NoNul [] = ⊤
NoNul (b ∷ bs) = (b ≢ nul) × NoNul bs

NoCR : Stream → Set
NoCR [] = ⊤
NoCR (b ∷ bs) = (b ≢ cr) × NoCR bs

-- The text transducer handles CR, CRLF, LF, and all other bytes.  The
-- two-element clauses are deliberately written without a mutual helper: every
-- recursive call is visibly on a tail, which is the termination argument used
-- by the Agda checker.
canonText : Stream → Stream
canonText [] = []
canonText (b ∷ []) with b ≟ cr
... | yes _ = lf ∷ []
... | no _  = b ∷ []
canonText (b ∷ c ∷ bs) with b ≟ cr
... | no _  = b ∷ canonText (c ∷ bs)
... | yes _ with c ≟ lf
... | yes _ = lf ∷ canonText bs
... | no _  = lf ∷ canonText (c ∷ bs)

canon : Stream → Stream
canon s with containsNul s
... | true  = s
... | false = canonText s

------------------------------------------------------------------------
-- Structural witnesses used by the projection theorems
------------------------------------------------------------------------

noCR-canonText : (s : Stream) → NoCR (canonText s)
noCR-canonText [] = tt
noCR-canonText (b ∷ []) with b ≟ cr
... | yes _ = (lf≢cr , tt)
... | no  h = (h , tt)
noCR-canonText (b ∷ c ∷ bs) with b ≟ cr
... | no h = (h , noCR-canonText (c ∷ bs))
... | yes _ with c ≟ lf
... | yes _ = (lf≢cr , noCR-canonText bs)
... | no _  = (lf≢cr , noCR-canonText (c ∷ bs))

noCR-canonText-id : {s : Stream} → NoCR s → canonText s ≡ s
noCR-canonText-id {[]} _ = refl
noCR-canonText-id {b ∷ []} (h , _) with b ≟ cr
... | yes e = ⊥-elim (h e)
... | no  _ = refl
noCR-canonText-id {b ∷ c ∷ bs} (h , tail) with b ≟ cr
... | yes e = ⊥-elim (h e)
... | no  _ = cong (_∷_ b) (noCR-canonText-id tail)

noNul-canonText : (s : Stream) → NoNul s → NoNul (canonText s)
noNul-canonText [] _ = tt
noNul-canonText (b ∷ []) (h , _) with b ≟ cr
... | yes _ = (lf≢nul , tt)
... | no  _ = (h , tt)
noNul-canonText (b ∷ c ∷ bs) (hb , tail) with b ≟ cr
... | no _ = (hb , noNul-canonText (c ∷ bs) tail)
... | yes _ with c ≟ lf
... | yes _ = (lf≢nul , noNul-canonText bs (proj₂ tail))
... | no _  = (lf≢nul , noNul-canonText (c ∷ bs) tail)

contains-false-noNul : {s : Stream} → containsNul s ≡ false → NoNul s
contains-false-noNul {[]} _ = tt
contains-false-noNul {b ∷ bs} h with b ≟ nul
... | yes e = ⊥-elim (true≠false h)
  where
  true≠false : true ≢ false
  true≠false ()
... | no  hb = (hb , contains-false-noNul h)

noNul-contains-false : {s : Stream} → NoNul s → containsNul s ≡ false
noNul-contains-false {[]} _ = refl
noNul-contains-false {b ∷ bs} (hb , tail) with b ≟ nul
... | yes e = ⊥-elim (hb e)
... | no _  = noNul-contains-false tail

------------------------------------------------------------------------
-- Projection laws
------------------------------------------------------------------------

idempotence : (s : Stream) → canon (canon s) ≡ canon s
idempotence s with containsNul s
... | true = refl
... | false with containsNul (canonText s)
... | true = ⊥-elim (true≠false (noNul-contains-false
                         (noNul-canonText s (contains-false-noNul refl))))
  where
  true≠false : true ≢ false
  true≠false ()
... | false = noCR-canonText-id (noCR-canonText (canonText s))

binary-preservation : {s : Stream} → Binary s → canon s ≡ s
binary-preservation {s} h with containsNul s
... | true = refl
... | false = ⊥-elim (false≠true h)
  where
  false≠true : false ≢ true
  false≠true ()

-- The operational line-token sequence is represented by its unique canonical
-- spelling. Thus the quotient relation is extensional equality of line tokens,
-- while the implementation remains a plain List Byte transducer.
lines : Stream → Stream
lines = canon

_≈LE_ : Stream → Stream → Set
s ≈LE t = lines s ≡ lines t

equivalence-invariance : {s t : Stream} → s ≈LE t → canon s ≡ canon t
equivalence-invariance h = h

-- Any function out of the quotient respects canonical representatives.
cryptographic-coherence : {A : Set} (H : Stream → A) →
  {s t : Stream} → s ≈LE t → H (canon s) ≡ H (canon t)
cryptographic-coherence H h = cong H h
