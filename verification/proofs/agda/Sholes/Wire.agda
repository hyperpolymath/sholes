{-# OPTIONS --safe --without-K --cubical-compatible #-}
-- SPDX-License-Identifier: CC-BY-SA-4.0
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
module Sholes.Wire where
open import Sholes.Core
open import Agda.Builtin.Nat using (Nat; zero; suc; _+_)
open import Agda.Builtin.Maybe using (Maybe; nothing; just)

-- Recursive finite type avoids indexed constructor injectivity, which Agda
-- 2.6.4.3 cannot compute under Cubical transports for the usual Fin datatype.
Fin : Nat → Set
Fin zero = ⊥
Fin (suc n) = Maybe (Fin n)
pattern fzero = nothing
pattern fsuc x = just x

at : (n : Nat) → ∀ {extra} → Fin (suc (n + extra))
at zero = fzero
at (suc n) {extra} = fsuc (at n {extra})

insert : ∀ {n} → Fin (suc n) → Fin n → Fin (suc n)
insert {zero} k ()
insert {suc n} fzero x = fsuc x
insert {suc n} (fsuc k) fzero = fzero
insert {suc n} (fsuc k) (fsuc x) = fsuc (insert {n} k x)

remove : ∀ {n} → Fin (suc n) → Fin (suc n) → Maybe (Fin n)
remove {zero} fzero fzero = nothing
remove {zero} fzero (fsuc ())
remove {zero} (fsuc ()) x
remove {suc n} fzero fzero = nothing
remove {suc n} fzero (fsuc x) = just x
remove {suc n} (fsuc k) fzero = just fzero
remove {suc n} (fsuc k) (fsuc x) with remove {n} k x
... | nothing = nothing
... | just y = just (fsuc y)

Octet : Set
Octet = Fin 256
Alphabet : Set
Alphabet = Byte (Fin 254)

encode : Alphabet → Octet
encode cr = at 13 {242}
encode lf = at 10 {245}
encode (plain x) = insert {255} (at 13 {242}) (insert {254} (at 10 {244}) x)

decode : Octet → Alphabet
decode b with remove {255} (at 13 {242}) b
... | nothing = cr
... | just x with remove {254} (at 10 {244}) x
...   | nothing = lf
...   | just y = plain y

equal : ∀ {n} → Fin n → Fin n → Bool
equal {zero} () y
equal {suc n} fzero fzero = true
equal {suc n} fzero (fsuc _) = false
equal {suc n} (fsuc _) fzero = false
equal {suc n} (fsuc x) (fsuc y) = equal {n} x y

equal-sound : ∀ {n} (x y : Fin n) → equal x y ≡ true → x ≡ y
equal-sound {zero} () y p
equal-sound {suc n} fzero fzero p = refl
equal-sound {suc n} fzero (fsuc y) ()
equal-sound {suc n} (fsuc x) fzero ()
equal-sound {suc n} (fsuc x) (fsuc y) p = cong fsuc (equal-sound {n} x y p)

_&&_ : Bool → Bool → Bool
true && b = b
false && _ = false
and-left : ∀ a b → (a && b) ≡ true → a ≡ true
and-left true b p = refl
and-left false b ()
and-right : ∀ a b → (a && b) ≡ true → b ≡ true
and-right true b p = p
and-right false b ()

-- Finite reflection: the coverage lemma makes these computational proofs,
-- not a sample of tests. Every inhabitant of Fin n is covered.
every : (n : Nat) → (Fin n → Bool) → Bool
every zero f = true
every (suc n) f = f fzero && every n (λ i → f (fsuc i))

every-sound : (n : Nat) (f : Fin n → Bool) → every n f ≡ true → (i : Fin n) → f i ≡ true
every-sound zero f p ()
every-sound (suc n) f p fzero = and-left (f fzero) (every n (λ i → f (fsuc i))) p
every-sound (suc n) f p (fsuc i) = every-sound n (λ j → f (fsuc j))
  (and-right (f fzero) (every n (λ j → f (fsuc j))) p) i

roundtrip-check : every 256 (λ b → equal {256} (encode (decode b)) b) ≡ true
roundtrip-check = refl

wire-roundtrip : (b : Octet) → encode (decode b) ≡ b
wire-roundtrip b = equal-sound {256} (encode (decode b)) b
  (every-sound 256 (λ x → equal {256} (encode (decode x)) x) roundtrip-check b)

same : Alphabet → Alphabet → Bool
same cr cr = true
same lf lf = true
same (plain x) (plain y) = equal {254} x y
same _ _ = false

same-sound : (x y : Alphabet) → same x y ≡ true → x ≡ y
same-sound cr cr p = refl
same-sound cr lf ()
same-sound cr (plain _) ()
same-sound lf cr ()
same-sound lf lf p = refl
same-sound lf (plain _) ()
same-sound (plain _) cr ()
same-sound (plain _) lf ()
same-sound (plain x) (plain y) p = cong plain (equal-sound {254} x y p)

payload-check : every 254 (λ b → same (decode (encode (plain b))) (plain b)) ≡ true
payload-check = refl

alphabet-roundtrip : (b : Alphabet) → decode (encode b) ≡ b
alphabet-roundtrip cr = refl
alphabet-roundtrip lf = refl
alphabet-roundtrip (plain b) = same-sound (decode (encode (plain b))) (plain b)
  (every-sound 254 (λ x → same (decode (encode (plain x))) (plain x)) payload-check b)

map : ∀ {A B : Set} → (A → B) → List A → List B
map f [] = []
map f (x ∷ xs) = f x ∷ map f xs

cons-cong : ∀ {A : Set} {x y : A} {xs ys} → x ≡ y → xs ≡ ys → (x ∷ xs) ≡ (y ∷ ys)
cons-cong refl refl = refl

wire-list-roundtrip : (bs : List Octet) → map encode (map decode bs) ≡ bs
wire-list-roundtrip [] = refl
wire-list-roundtrip (b ∷ bs) = cons-cong (wire-roundtrip b) (wire-list-roundtrip bs)

alphabet-list-roundtrip : (bs : List Alphabet) → map decode (map encode bs) ≡ bs
alphabet-list-roundtrip [] = refl
alphabet-list-roundtrip (b ∷ bs) = cons-cong (alphabet-roundtrip b) (alphabet-list-roundtrip bs)

canonWire : List Octet → List Octet
canonWire bs = map encode (canon (map decode bs))

-- This connects the abstract algebra to finite numeric octets. It does not
-- establish that an Idris String or Zig slice decoder implements this map.
open import Sholes.Equivalence using (idempotent)
open import Sholes.HeaderBridge using (header-break-preserved)
canonWire-idempotent : (bs : List Octet) → canonWire (canonWire bs) ≡ canonWire bs
canonWire-idempotent bs = trans
  (cong (λ xs → map encode (canon xs)) (alphabet-list-roundtrip (canon (map decode bs))))
  (cong (map encode) (idempotent (map decode bs)))

wire-header-preserved : (bs : List Octet) →
  hasBreak (map decode (canonWire bs)) ≡ hasBreak (map decode bs)
wire-header-preserved bs = trans
  (cong hasBreak (alphabet-list-roundtrip (canon (map decode bs))))
  (header-break-preserved (map decode bs))
