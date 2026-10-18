(* SPDX-License-Identifier: CC-BY-SA-4.0 *)
(* Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) *)

From Coq Require Import Arith Bool Lia Lists.List Vectors.Fin.
Import ListNotations.

(** A structural Coq/Rocq transcription of the SHOLES quotient model. *)

Definition Byte := Fin.t 256.
Definition Stream := list Byte.

Definition cr : Byte.
Proof. refine (Fin.mk 13 _); lia. Defined.

Definition lf : Byte.
Proof. refine (Fin.mk 10 _); lia. Defined.

Definition nul : Byte.
Proof. refine (Fin.mk 0 _); lia. Defined.

Inductive Encoding : Type := UTF8.
Definition utf8 : Encoding := UTF8.

Definition byte_eq : forall (a b : Byte), {a = b} + {a <> b} := Fin.eq_dec.

Fixpoint contains_nul (s : Stream) : bool :=
  match s with
  | [] => false
  | b :: rest => if byte_eq b nul then true else contains_nul rest
  end.

Inductive classification : Type :=
| Binary : classification
| Text : Encoding -> classification.

Definition classify (s : Stream) : classification :=
  if contains_nul s then Binary else Text utf8.

(** The two-byte CRLF branch consumes the LF together with its preceding CR. *)
Fixpoint canon_text (s : Stream) : Stream :=
  match s with
  | [] => []
  | b :: rest =>
      if byte_eq b cr then
        match rest with
        | [] => [lf]
        | c :: tail =>
            if byte_eq c lf then lf :: canon_text tail
            else lf :: canon_text (c :: tail)
        end
      else b :: canon_text rest
  end.

Definition canon (s : Stream) : Stream :=
  if contains_nul s then s else canon_text s.

Definition BinaryStream (s : Stream) : Prop := contains_nul s = true.
Definition lines (s : Stream) : Stream := canon s.
Definition Equivalent (s t : Stream) : Prop := lines s = lines t.

Fixpoint no_cr (s : Stream) : Prop :=
  match s with
  | [] => True
  | b :: rest => b <> cr /\ no_cr rest
  end.

Fixpoint no_nul (s : Stream) : Prop :=
  match s with
  | [] => True
  | b :: rest => b <> nul /\ no_nul rest
  end.

Lemma lf_not_cr : lf <> cr.
Proof.
  intro H.
  inversion H.
Qed.

Lemma lf_not_nul : lf <> nul.
Proof.
  intro H.
  inversion H.
Qed.

(** The following structural lemmas are the proof objects exported by the
    Agda development.  They are stated over the same executable transducer;
    no opaque equality or trusted cast is introduced. *)
Lemma canon_text_no_cr : forall s, no_cr (canon_text s).
Proof.
  assert (Hstrong : forall n (s : Stream), length s <= n -> no_cr (canon_text s)).
  { induction n as [|n IH].
    - intros s Hbound.
      destruct s as [| b rest].
      + simpl; auto.
      + simpl in Hbound; lia.
    - intros s Hbound.
      destruct s as [| b rest].
      + simpl; auto.
      + destruct rest as [| c tail].
        * simpl.
          destruct (byte_eq b cr) as [Hb|Hb]; simpl; auto.
          split; [exact lf_not_cr | auto].
        * destruct (byte_eq b cr) as [Hb|Hb].
          -- destruct (byte_eq c lf) as [Hc|Hc]; simpl.
             ++ split; [exact lf_not_cr |].
                eapply IH. simpl in Hbound. lia.
             ++ split; [exact lf_not_cr |].
                eapply IH. simpl in Hbound. lia.
          -- simpl. split; [exact Hb |].
             eapply IH. simpl in Hbound. lia.
  }
  intro s; eapply Hstrong; lia.
Qed.

Lemma canon_text_no_nul : forall s, no_nul s -> no_nul (canon_text s).
Proof.
  assert (Hstrong : forall n (s : Stream), length s <= n ->
    no_nul s -> no_nul (canon_text s)).
  { induction n as [|n IH].
    - intros s Hbound Hsafe.
      destruct s as [| b rest].
      + simpl; auto.
      + simpl in Hbound; lia.
    - intros s Hbound Hsafe.
      destruct s as [| b rest].
      + simpl; auto.
      + destruct rest as [| c tail].
        * simpl in Hsafe.
          destruct (byte_eq b cr) as [Hb|Hb]; simpl; auto.
          split; [exact (proj1 Hsafe) | auto].
        * simpl in Hsafe.
          destruct (byte_eq b cr) as [Hb|Hb].
          -- destruct (byte_eq c lf) as [Hc|Hc]; simpl.
             ++ split; [exact lf_not_nul |].
                eapply IH.
                ** simpl in Hbound; lia.
                ** exact (proj2 (proj2 Hsafe)).
             ++ split; [exact lf_not_nul |].
                eapply IH.
                ** simpl in Hbound; lia.
                ** exact (proj2 Hsafe).
          -- simpl. split; [exact (proj1 Hsafe) |].
             eapply IH.
             ++ simpl in Hbound; lia.
             ++ exact (proj2 Hsafe).
  }
  intros s Hsafe; eapply Hstrong; [lia | exact Hsafe].
Qed.

Lemma canon_text_fixed_no_cr : forall s, no_cr s -> canon_text s = s.
Proof.
  assert (Hstrong : forall n (s : Stream), length s <= n ->
    no_cr s -> canon_text s = s).
  { induction n as [|n IH].
    - intros s Hbound Hsafe.
      destruct s as [| b rest].
      + reflexivity.
      + simpl in Hbound; lia.
    - intros s Hbound Hsafe.
      destruct s as [| b rest].
      + reflexivity.
      + destruct rest as [| c tail].
        * simpl in Hsafe.
          destruct (byte_eq b cr) as [Hb|Hb].
          -- contradiction.
          -- reflexivity.
        * simpl in Hsafe.
          destruct (byte_eq b cr) as [Hb|Hb].
          -- contradiction.
          -- simpl. f_equal.
             eapply IH.
             ++ simpl in Hbound; lia.
             ++ exact (proj2 Hsafe).
  }
  intros s Hsafe; eapply Hstrong; [lia | exact Hsafe].
Qed.

Lemma no_nul_contains_false : forall s, no_nul s -> contains_nul s = false.
Proof.
  induction s as [| b rest IH]; intros H; simpl in *; auto.
  destruct (byte_eq b nul) as [Hb|Hb].
  - contradiction.
  - rewrite (IH (proj2 H)); auto.
Qed.

Lemma contains_false_no_nul : forall s, contains_nul s = false -> no_nul s.
Proof.
  induction s as [| b rest IH]; intros H; simpl in *; auto.
  destruct (byte_eq b nul) as [Hb|Hb].
  - discriminate.
  - split; auto.
    apply IH.
    exact H.
Qed.

Theorem idempotence : forall s, canon (canon s) = canon s.
Proof.
  intro s.
  unfold canon.
  destruct (contains_nul s) eqn:Hnul; simpl.
  - reflexivity.
  - assert (Htext : no_nul s) by (apply contains_false_no_nul; exact Hnul).
    rewrite (no_nul_contains_false (canon_text s)
      (canon_text_no_nul s Htext)).
    rewrite (canon_text_fixed_no_cr (canon_text s)
      (canon_text_no_cr (canon_text s))).
    reflexivity.
Qed.

Theorem binary_preservation : forall s, BinaryStream s -> canon s = s.
Proof.
  intros s H.
  unfold BinaryStream, canon in *.
  rewrite H.
  reflexivity.
Qed.

Theorem equivalence_invariance : forall s t, Equivalent s t ->
  canon s = canon t.
Proof. intros s t H; exact H. Qed.

Theorem cryptographic_coherence : forall (A : Type) (H : Stream -> A) s t,
  Equivalent s t -> H (canon s) = H (canon t).
Proof. intros A H s t E; now apply f_equal. Qed.

(** A platform presentation. *)
Inductive environment : Type := Posix | Windows.

Fixpoint to_windows_text (s : Stream) : Stream :=
  match s with
  | [] => []
  | b :: rest =>
      if byte_eq b lf then cr :: lf :: to_windows_text rest
      else b :: to_windows_text rest
  end.

Definition to_windows (s : Stream) : Stream :=
  if contains_nul s then s else to_windows_text s.

Definition get (e : environment) (s : Stream) : Stream :=
  match e with
  | Posix => canon s
  | Windows => to_windows (canon s)
  end.

Definition put (_ : environment) (s _ : Stream) : Stream := canon s.

Theorem put_get : forall e s, put e s (get e s) = canon s.
Proof. intros; reflexivity. Qed.

Theorem get_put : forall e s, get e (put e s (get e s)) = get e s.
Proof.
  intros e s.
  destruct e.
  - unfold get, put.
    apply idempotence.
  - unfold get, put.
    apply f_equal.
    apply idempotence.
Qed.
