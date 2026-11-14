---------------------------- MODULE MC ----------------------------
(* SPDX-License-Identifier: MPL-2.0                                    *)
(* Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)             *)
(*                                                                     *)
(* Bounded model for TLC. StateMachine's `processed` counter grows     *)
(* without limit, so TLC cannot finish on the spec alone. This module  *)
(* bounds it. A result here is TESTED with these bounds (PROOF-POLICY  *)
(* §5), never PROVEN. Liveness checked under a state constraint is a   *)
(* weak result: TLC prunes behaviours at the bound.                    *)
EXTENDS StateMachine

MaxProcessed == 6
Bound == processed <= MaxProcessed
=====================================================================
