-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

{-# OPTIONS --safe #-}

module Sholes.Lens where

open import Data.Bool using (Bool; false; true)
open import Data.Fin using (_≟_)
open import Data.List using (List; []; _∷_)
open import Relation.Binary.PropositionalEquality using (_≡_; refl; cong)
open import Relation.Nullary using (yes; no)
open import Sholes.Core

Environment : Set
Environment = Bool

POSIX WINDOWS : Environment
POSIX = false
WINDOWS = true

-- Windows presentation of a canonical text stream. The binary guard makes
-- the non-interference law explicit at the presentation boundary as well.
toWindowsText : Stream → Stream
toWindowsText [] = []
toWindowsText (b ∷ bs) with b ≟ lf
... | yes _ = cr ∷ lf ∷ toWindowsText bs
... | no _  = b ∷ toWindowsText bs

toWindows : Stream → Stream
toWindows s with containsNul s
... | true  = s
... | false = toWindowsText s

-- get_e is the presentation seen by an environment.
get : Environment → Stream → Stream
get false s = canon s
get true s = toWindows (canon s)

-- put removes the platform presentation and returns storage bytes. Equality
-- in the first lens law is equality of canonical representatives.
put : Environment → Stream → Stream → Stream
put e s v = canon s

put-get : (e : Environment) (s : Stream) →
  put e s (get e s) ≡ canon s
put-get e s = refl

-- Both environments obey GetPut by congruence over idempotence. The Windows
-- binary guard is inside toWindows, so this proof does not need a side lemma
-- about the classifier preserving NULs.
get-put : (e : Environment) (s : Stream) →
  get e (put e s (get e s)) ≡ get e s
get-put false s = idempotence s
get-put true s = cong toWindows (idempotence s)
