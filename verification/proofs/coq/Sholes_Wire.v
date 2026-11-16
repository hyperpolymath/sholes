(* SPDX-License-Identifier: CC-BY-SA-4.0
   Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
   Hand re-proof of Sholes.Wire.agda; structurally finite octets. *)
From Stdlib Require Import List Bool.
Require Import Sholes_Core.
Import ListNotations.
Module Wire.
Fixpoint Finite (n : nat) : Type :=
  match n with O => False | S n => option (Finite n) end.
Fixpoint indexAt (n extra : nat) : Finite (S (n + extra)) :=
  match n as k return Finite (S (k + extra)) with
  | O => None | S k => Some (indexAt k extra) end.

Fixpoint insert (n : nat) : Finite (S n) -> Finite n -> Finite (S n) :=
  match n as k return Finite (S k) -> Finite k -> Finite (S k) with
  | O => fun _ x => match x with end
  | S k => fun hole x => match hole, x with
    | None, _ => Some x | Some _, None => None
    | Some h, Some y => Some (insert k h y) end
  end.
Fixpoint remove (n : nat) : Finite (S n) -> Finite (S n) -> option (Finite n) :=
  match n as k return Finite (S k) -> Finite (S k) -> option (Finite k) with
  | O => fun hole x => match hole, x with
    | None, None => None | None, Some y => match y with end
    | Some h, _ => match h with end end
  | S k => fun hole x => match hole, x with
    | None, None => None | None, Some y => Some y
    | Some _, None => Some None
    | Some h, Some y => match remove k h y with
      | None => None | Some z => Some (Some z) end end
  end.
Definition Octet := Finite 256.
Definition Alphabet := Byte (Finite 254).
Definition encode (b : Alphabet) : Octet :=
  match b with
  | cr => indexAt 13 242 | lf => indexAt 10 245
  | plain x => insert 255 (indexAt 13 242) (insert 254 (indexAt 10 244) x) end.
Definition decode (b : Octet) : Alphabet :=
  match remove 255 (indexAt 13 242) b with
  | None => cr | Some x => match remove 254 (indexAt 10 244) x with
    | None => lf | Some y => plain y end end.

Fixpoint equal (n : nat) : Finite n -> Finite n -> bool :=
  match n as k return Finite k -> Finite k -> bool with
  | O => fun x _ => match x with end
  | S k => fun x y => match x, y with
    | None, None => true | Some x, Some y => equal k x y | _, _ => false end end.
Lemma equal_sound n (x y : Finite n) : equal n x y = true -> x = y.
Proof. induction n as [|n IH]; [destruct x|].
  destruct x as [x|], y as [y|]; simpl; intro H; try discriminate; try reflexivity.
  f_equal. now apply IH. Qed.
Fixpoint every (n : nat) : (Finite n -> bool) -> bool :=
  match n as k return (Finite k -> bool) -> bool with
  | O => fun _ => true
  | S k => fun f => f None && every k (fun x => f (Some x)) end.
Lemma every_sound n (f : Finite n -> bool) : every n f = true -> forall i, f i = true.
Proof. induction n as [|n IH]; [intros _ i; destruct i|].
  simpl. intro H. apply andb_true_iff in H as [Hnone Hsome].
  intros [i|]; [exact (IH _ Hsome i)|exact Hnone]. Qed.
Lemma roundtrip_check : every 256 (fun b => equal 256 (encode (decode b)) b) = true.
Proof. reflexivity. Qed.
Lemma wire_roundtrip (b : Octet) : encode (decode b) = b.
Proof. apply equal_sound. exact (every_sound _ _ roundtrip_check b). Qed.

Definition same (x y : Alphabet) : bool :=
  match x, y with cr, cr => true | lf, lf => true
  | plain x, plain y => equal 254 x y | _, _ => false end.
Lemma same_sound x y : same x y = true -> x = y.
Proof. destruct x, y; simpl; intro H; try discriminate; try reflexivity.
  f_equal. now apply equal_sound. Qed.
Lemma payload_check : every 254 (fun b => same (decode (encode (plain b))) (plain b)) = true.
Proof. reflexivity. Qed.
Lemma alphabet_roundtrip (b : Alphabet) : decode (encode b) = b.
Proof. destruct b; try reflexivity. apply same_sound. exact (every_sound _ _ payload_check a). Qed.

Fixpoint map {A B : Type} (f : A -> B) (xs : list A) : list B :=
  match xs with [] => [] | x :: xs => f x :: map f xs end.
Lemma wire_list_roundtrip bs : map encode (map decode bs) = bs.
Proof. induction bs as [|b bs IH]; [reflexivity|]. simpl. rewrite wire_roundtrip, IH. reflexivity. Qed.
Lemma alphabet_list_roundtrip bs : map decode (map encode bs) = bs.
Proof. induction bs as [|b bs IH]; [reflexivity|]. simpl. rewrite alphabet_roundtrip, IH. reflexivity. Qed.
Definition canonWire bs := map encode (canon (map decode bs)).
Lemma canonWire_idempotent bs : canonWire (canonWire bs) = canonWire bs.
Proof. unfold canonWire. rewrite alphabet_list_roundtrip, idempotent. reflexivity. Qed.
Lemma wire_header_preserved bs : hasBreak (map decode (canonWire bs)) = hasBreak (map decode bs).
Proof. unfold canonWire. rewrite alphabet_list_roundtrip. apply header_break_preserved. Qed.
Print Assumptions wire_roundtrip.
Print Assumptions alphabet_roundtrip.
Print Assumptions canonWire_idempotent.
Print Assumptions wire_header_preserved.
End Wire.
