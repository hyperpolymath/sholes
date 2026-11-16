(* SPDX-License-Identifier: CC-BY-SA-4.0
   Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
   Hand re-proof of the Agda core, equivalence, lens and header bridge.
   No claim of automatic proof-object transport. *)
From Stdlib Require Import List Bool.
Import ListNotations.
Set Implicit Arguments.

Inductive Byte (A : Type) := cr | lf | plain (a : A).
Inductive Token (A : Type) := newline | literal (a : A).
Arguments cr {A}. Arguments lf {A}. Arguments plain {A} a.
Arguments newline {A}. Arguments literal {A} a.

Section Sholes.
Context {A : Type}.
Fixpoint tokens (xs : list (Byte A)) : list (Token A) :=
  match xs with
  | [] => [] | cr :: xs => newline :: afterCR xs
  | lf :: xs => newline :: tokens xs
  | plain a :: xs => literal a :: tokens xs
  end
with afterCR (xs : list (Byte A)) : list (Token A) :=
  match xs with
  | [] => [] | lf :: xs => tokens xs
  | cr :: xs => newline :: afterCR xs
  | plain a :: xs => literal a :: tokens xs
  end.
Fixpoint renderLF (ts : list (Token A)) : list (Byte A) :=
  match ts with [] => [] | newline :: ts => lf :: renderLF ts
  | literal a :: ts => plain a :: renderLF ts end.
Fixpoint renderCRLF (ts : list (Token A)) : list (Byte A) :=
  match ts with [] => [] | newline :: ts => cr :: lf :: renderCRLF ts
  | literal a :: ts => plain a :: renderCRLF ts end.
Lemma tokens_renderLF ts : tokens (renderLF ts) = ts.
Proof. induction ts as [|t ts IH]; [reflexivity|destruct t; simpl; now rewrite IH]. Qed.
Lemma tokens_renderCRLF ts : tokens (renderCRLF ts) = ts.
Proof. induction ts as [|t ts IH]; [reflexivity|destruct t; simpl; now rewrite IH]. Qed.
Definition canon xs := renderLF (tokens xs).
Definition LEq xs ys := tokens xs = tokens ys.
Lemma equiv_refl xs : LEq xs xs. Proof. reflexivity. Qed.
Lemma equiv_sym xs ys : LEq xs ys -> LEq ys xs. Proof. unfold LEq; auto. Qed.
Lemma equiv_trans xs ys zs : LEq xs ys -> LEq ys zs -> LEq xs zs.
Proof. unfold LEq; intros; congruence. Qed.
Lemma canon_preserves_tokens xs : LEq (canon xs) xs.
Proof. apply tokens_renderLF. Qed.
Lemma idempotent xs : canon (canon xs) = canon xs.
Proof. unfold canon; now rewrite tokens_renderLF. Qed.
Lemma invariant xs ys : LEq xs ys -> canon xs = canon ys.
Proof. unfold LEq, canon; intros H; now rewrite H. Qed.
Lemma reflects xs ys : canon xs = canon ys -> LEq xs ys.
Proof. intros H. unfold LEq. rewrite <- (canon_preserves_tokens xs), <- (canon_preserves_tokens ys). now rewrite H. Qed.
Lemma hash_coherent {B : Type} (H : list (Byte A) -> B) xs ys : LEq xs ys -> H (canon xs) = H (canon ys).
Proof. intros E; now rewrite (invariant E). Qed.
Lemma factors {B : Type} (f : list (Token A) -> B) xs : f (tokens (canon xs)) = f (tokens xs).
Proof. now rewrite canon_preserves_tokens. Qed.

Fixpoint hasBreak (xs : list (Byte A)) : bool :=
  match xs with [] => false | cr :: _ => true | lf :: _ => true | plain _ :: xs => hasBreak xs end.
Fixpoint hasLF (xs : list (Byte A)) : bool :=
  match xs with [] => false | cr :: xs => hasLF xs | lf :: _ => true | plain _ :: xs => hasLF xs end.
Fixpoint hasCR (xs : list (Byte A)) : bool :=
  match xs with [] => false | cr :: _ => true | lf :: xs => hasCR xs | plain _ :: xs => hasCR xs end.
Fixpoint tokenBreak (ts : list (Token A)) : bool :=
  match ts with [] => false | newline :: _ => true | literal _ :: ts => tokenBreak ts end.
Lemma render_no_CR ts : hasCR (renderLF ts) = false.
Proof. induction ts as [|t ts IH]; [reflexivity|destruct t; exact IH]. Qed.
Lemma tokens_break xs : tokenBreak (tokens xs) = hasBreak xs.
Proof. induction xs as [|b xs IH]; [reflexivity|destruct b; simpl; auto]. Qed.
Lemma render_break ts : hasBreak (renderLF ts) = tokenBreak ts.
Proof. induction ts as [|t ts IH]; [reflexivity|destruct t; simpl; auto]. Qed.
Lemma render_LF ts : hasLF (renderLF ts) = tokenBreak ts.
Proof. induction ts as [|t ts IH]; [reflexivity|destruct t; simpl; auto]. Qed.
Lemma header_break_preserved xs : hasBreak (canon xs) = hasBreak xs.
Proof. unfold canon; rewrite render_break; apply tokens_break. Qed.
Lemma canonical_LF_detects_all xs : hasLF (canon xs) = hasBreak xs.
Proof. unfold canon; rewrite render_LF; apply tokens_break. Qed.

Inductive Mode := text | binary.
Definition canonicalize m xs := match m with text => canon xs | binary => xs end.
Lemma binary_preserved xs : canonicalize binary xs = xs. Proof. reflexivity. Qed.
Inductive Environment := unix | windows.
Definition render e := match e with unix => renderLF | windows => renderCRLF end.
Lemma parse_render e ts : tokens (render e ts) = ts.
Proof. destruct e; [apply tokens_renderLF|apply tokens_renderCRLF]. Qed.
Lemma put_get e ts : tokens (render e ts) = ts. Proof. apply parse_render. Qed.
Lemma get_put_quotient e xs : LEq (render e (tokens xs)) xs. Proof. apply parse_render. Qed.
Lemma get_put_normal_view e ts : render e (tokens (render e ts)) = render e ts.
Proof. now rewrite parse_render. Qed.
Lemma no_raw_inverse (restore : list (Byte A) -> list (Byte A)) :
  restore (canon [cr]) = [cr] -> restore (canon [lf]) = [lf] -> False.
Proof. change (restore [lf] = [cr] -> restore [lf] = [lf] -> False). intros H K. rewrite H in K. discriminate. Qed.

Fixpoint pairOnly (xs : list (Byte A)) : bool :=
  match xs with
  | [] => false
  | cr :: tail => match tail with lf :: _ => true | _ => pairOnly tail end
  | _ :: tail => pairOnly tail
  end.
Lemma pair_misses_CR : pairOnly [cr] = false. Proof. reflexivity. Qed.
Lemma pair_misses_LF : pairOnly [lf] = false. Proof. reflexivity. Qed.
Lemma normalizing_does_not_fix_pair_check : pairOnly (canon [cr; lf]) = false. Proof. reflexivity. Qed.
Lemma pair_misses_every_canonical_break ts : pairOnly (renderLF ts) = false.
Proof. induction ts as [|t ts IH]; [reflexivity|destruct t; exact IH]. Qed.
Lemma trailing_break_retained : tokens [lf] = [newline]. Proof. reflexivity. Qed.
Lemma two_breaks_retained : tokens [cr; cr; lf] = [newline; newline]. Proof. reflexivity. Qed.
Inductive State := ready | suppressLF.
Definition next (_ : State) (b : Byte A) := match b with cr => suppressLF | _ => ready end.
Definition emit q (b : Byte A) : list (Token A) :=
  match b with cr => [newline] | lf => match q with ready => [newline] | suppressLF => [] end
  | plain a => [literal a] end.
Fixpoint finish q (xs : list (Byte A)) : State :=
  match xs with [] => q | x :: xs => finish (next q x) xs end.
Fixpoint output q (xs : list (Byte A)) : list (Token A) :=
  match xs with [] => [] | x :: xs => emit q x ++ output (next q x) xs end.
Lemma finish_append q xs ys : finish q (xs ++ ys) = finish (finish q xs) ys.
Proof. revert q; induction xs as [|x xs IH]; intros q; simpl; auto. Qed.
Lemma output_append q xs ys : output q (xs ++ ys) = output q xs ++ output (finish q xs) ys.
Proof. revert q; induction xs as [|x xs IH]; intros q; simpl; [reflexivity|rewrite IH; apply app_assoc]. Qed.
Lemma output_spec xs q : output q xs = match q with ready => tokens xs | suppressLF => afterCR xs end.
Proof. revert q; induction xs as [|b xs IH]; intros q; [destruct q; reflexivity|].
  destruct q, b; simpl; rewrite IH; reflexivity. Qed.
Lemma output_tokens xs : output ready xs = tokens xs. Proof. apply output_spec. Qed.
Lemma output_afterCR xs : output suppressLF xs = afterCR xs. Proof. apply output_spec. Qed.
Lemma chunk_refinement xs ys : output ready xs ++ output (finish ready xs) ys = tokens (xs ++ ys).
Proof. rewrite <- output_append; apply output_tokens. Qed.
Lemma reset_is_wrong : output ready [cr] ++ output ready [lf] <> tokens [cr; lf].
Proof. discriminate. Qed.
End Sholes.
Print Assumptions chunk_refinement.
Print Assumptions reset_is_wrong.

Print Assumptions idempotent.
Print Assumptions reflects.
Print Assumptions hash_coherent.
Print Assumptions no_raw_inverse.
Print Assumptions header_break_preserved.
Print Assumptions canonical_LF_detects_all.
Print Assumptions pair_misses_every_canonical_break.
