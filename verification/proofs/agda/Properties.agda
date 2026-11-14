-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Agda Proof Template: Inductive and coinductive properties
-- Replace with your project's domain-specific proofs.
-- All proofs must be total (no postulate, no {-# TERMINATING #-}).
--
-- Self-contained: this file imports NO library (not the Agda standard
-- library), so it checks with a bare `agda` and does not depend on the
-- pinned agda-stdlib building. It defines only the Nat / List / equality
-- pieces its theorems need.

module Properties where

infix  4 _≡_ _≤_
infixr 5 _∷_ _++_
infixl 6 _+_

-- Propositional equality
data _≡_ {A : Set} (x : A) : A → Set where
  refl : x ≡ x

cong : ∀ {A B : Set} (f : A → B) {x y : A} → x ≡ y → f x ≡ f y
cong f refl = refl

-- Natural numbers
data ℕ : Set where
  zero : ℕ
  suc  : ℕ → ℕ

_+_ : ℕ → ℕ → ℕ
zero  + n = n
suc m + n = suc (m + n)

data _≤_ : ℕ → ℕ → Set where
  z≤n : ∀ {n}           → zero  ≤ n
  s≤s : ∀ {m n} → m ≤ n → suc m ≤ suc n

-- Lists
data List (A : Set) : Set where
  []  : List A
  _∷_ : A → List A → List A

length : ∀ {A : Set} → List A → ℕ
length []       = zero
length (_ ∷ xs) = suc (length xs)

_++_ : ∀ {A : Set} → List A → List A → List A
[]       ++ ys = ys
(x ∷ xs) ++ ys = x ∷ (xs ++ ys)

-- Example: Proof that list append preserves total length
-- Replace with your project's domain proofs.

append-length : ∀ {A : Set} (xs ys : List A) →
  length (xs ++ ys) ≡ length xs + length ys
append-length []       ys = refl
append-length (x ∷ xs) ys = cong suc (append-length xs ys)

-- Example: Monotonicity proof template
-- Use for state machines, confidence scores, trust levels
record Monotone {A : Set} (_≤A_ : A → A → Set) (f : A → A) : Set where
  field
    preserves : ∀ {x y} → x ≤A y → f x ≤A f y

-- Example: Idempotence proof template
-- Use for normalisation, deduplication, formatting
record Idempotent {A : Set} (_≡A_ : A → A → Set) (f : A → A) : Set where
  field
    idem : ∀ (x : A) → f (f x) ≡A f x

-- Example: Natural number successor is monotone
suc-monotone : Monotone _≤_ suc
suc-monotone = record { preserves = s≤s }
