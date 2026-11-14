||| SPDX-License-Identifier: MPL-2.0
||| Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
|||
||| Coaptation sound core: the hard (Must/Trust) gate of the comparator
||| `coapt.ncl`, modelled in Idris2 with a content-bearing witness relation.
|||
||| What is modelled. `coapt.ncl` reads the atomised clauses (`clauses.json`),
||| the atomised facts (`facts.json`) and the witness map (`witness-map.ncl`).
||| A clause listed in the map as `descriptile` is witnessed when every one of
||| its witness specs holds: the named fact, looked up by id, satisfies the
||| spec's predicate. The Must/Trust gate passes when no hard clause is
||| refuted, gapped or unmeasured. A hard clause that is unlisted but has a
||| runnable probe is "probe-deferred" and does NOT fail the Yard gate today.
|||
||| What is proved (kernel-checked by `idris2 --check`):
|||
||| * `hardGateSound`: if the gate function returns True, every Must/Trust
|||   clause carries a `HardResolved` term. That term is either a WITNESS, which
|||   holds, for every spec, the fact actually found by the lookup and a proof
|||   that its predicate is true, over a non-empty spec list; or a recorded
|||   PROBE DEFERRAL. There is no constructor for a gap.
||| * `hardGateComplete`: the converse. So the Bool gate and the evidence type
|||   agree exactly.
||| * `mustCannotGap`, `trustCannotGap`: no gap permission exists for the hard
|||   verbs, for any clause, not only for an example.
|||
||| What is NOT proved. That this model is a faithful transcription of
||| `coapt.ncl`. The correspondence is argued line by line in the comments
||| below (policy status ASSUMED for that bridge), not kernel-checked: Nickel
||| is the authoritative reading. The deferral constructor exists because the
||| comparator lets probe-deferred hard clauses pass; ultraplan P2.1 (standards)
||| rules that they become blocking until a Hunt run reports, and this core
||| drops `ByDeferral` when that lands.
module Coaptation

import Data.List
import Data.List.Quantifiers
import Data.String

%default total

-- ── Vocabulary (mirrors clauses.json `verb`) ────────────────────────────────

||| The six contractile verbs.
public export
data Verb = Intend | Must | Trust | Adjust | Dust | Bust

||| The hard verbs. coapt.ncl: `e.verb == "must" || e.verb == "trust"`.
public export
isHard : Verb -> Bool
isHard Must  = True
isHard Trust = True
isHard _     = False

||| The descriptive families that emit evidence (the descriptiles). Each one is
||| read from clauses of the repo deed (`<repo>_chora.deed`) by extract-facts.sh,
||| and its name, lower-cased, is the prefix of the fact IDs it emits:
|||   CLADE     (identity) (clade) (lineage) (forges) — what the repo IS
|||   STATE     (status) (maturity)                   — where it is now
|||   ECOSYSTEM (ecosystem)                           — where it sits, what it is not
|||   AGENTIC   (agentic)                             — may I act now?
|||   NEUROSYM  (neurosym)                            — the meaning of operations
|||   PLAYBOOK  (playbook)                            — how permitted actions run
|||   ANCHOR    (anchor)                              — semantic authority + golden path
public export
data Family = CLADE | STATE | ECOSYSTEM | AGENTIC | NEUROSYM | PLAYBOOK | ANCHOR

||| Permission to leave a clause unresolved. Constructors exist only for the
||| soft verbs, so a hard clause can never be gapped.
public export
data MayGap : Verb -> Type where
  IntendMayGap : MayGap Intend
  AdjustMayGap : MayGap Adjust
  DustMayGap   : MayGap Dust
  BustMayGap   : MayGap Bust

export
Uninhabited (MayGap Must) where
  uninhabited IntendMayGap impossible
  uninhabited AdjustMayGap impossible
  uninhabited DustMayGap impossible
  uninhabited BustMayGap impossible

export
Uninhabited (MayGap Trust) where
  uninhabited IntendMayGap impossible
  uninhabited AdjustMayGap impossible
  uninhabited DustMayGap impossible
  uninhabited BustMayGap impossible

||| A Must clause can never be gapped (universal, not an example).
export
mustCannotGap : MayGap Must -> Void
mustCannotGap = absurd

||| A Trust clause can never be gapped.
export
trustCannotGap : MayGap Trust -> Void
trustCannotGap = absurd

-- ── Data (mirrors facts.json, clauses.json, witness-map.ncl) ────────────────

||| A descriptive fact. facts.json: { id, value, present }.
public export
record Fact where
  constructor MkFact
  fid     : String
  value   : String
  present : Bool

||| A contractile clause. clauses.json: { id, verb, has_probe }.
public export
record Clause where
  constructor MkClause
  cid      : String
  verb     : Verb
  hasProbe : Bool

||| Witness predicates. witness-map.ncl ops.
public export
data Op = Present | Absent | Zero | NonZero
        | Equals String | Contains String | NotContains String

||| One witness spec: a fact id and the predicate it must satisfy.
public export
record Spec where
  constructor MkSpec
  fact : String
  op   : Op

||| A witness-map entry. `kind = "descriptile"` with its specs, or
||| `kind = "none"` (an explicit gap).
public export
data Entry = Descriptile (List Spec) | NoWitness

||| The witness map: clause id to entry. An id with no entry is `auto`.
public export
WMap : Type
WMap = List (String, Entry)

-- ── The comparator, as Bool functions (the Nickel reading) ──────────────────

||| coapt.ncl `lookup`: the fact with this id, or an absent empty fact.
public export
lookupFact : String -> List Fact -> Fact
lookupFact i [] = MkFact i "" False
lookupFact i (f :: fs) = if fid f == i then f else lookupFact i fs

||| coapt.ncl: the witness-map entry for a clause id, if listed.
public export
lookupEntry : String -> WMap -> Maybe Entry
lookupEntry i [] = Nothing
lookupEntry i ((k, e) :: rest) = if k == i then Just e else lookupEntry i rest

||| coapt.ncl `eval_w`, per op. `std.string.contains arg value` is
||| `isInfixOf arg value`.
public export
evalOp : Op -> Fact -> Bool
evalOp Present         f = present f
evalOp Absent          f = not (present f)
evalOp Zero            f = value f == "0"
evalOp NonZero         f = if present f then not (value f == "0") else False
evalOp (Equals a)      f = value f == a
evalOp (Contains a)    f = isInfixOf a (value f)
evalOp (NotContains a) f = not (isInfixOf a (value f))

public export
evalSpec : List Fact -> Spec -> Bool
evalSpec fs s = evalOp (op s) (lookupFact (fact s) fs)

||| Structural `all`, so proofs can reason about it.
public export
allSpecs : List Fact -> List Spec -> Bool
allSpecs fs [] = True
allSpecs fs (s :: ss) = if evalSpec fs s then allSpecs fs ss else False

||| A descriptile entry is satisfied only by a NON-EMPTY spec list whose specs
||| all hold. (coapt.ncl applies the same non-empty rule; an empty list there
||| is refuted, never vacuously witnessed.)
public export
satisfied : List Fact -> List Spec -> Bool
satisfied fs [] = False
satisfied fs (s :: ss) = allSpecs fs (s :: ss)

||| coapt.ncl per-clause status, for a hard clause.
public export
data HardStatus = Witnessed | Refuted | Gap | ProbeDeferred | Unmeasured

public export
classify : List Fact -> WMap -> Clause -> HardStatus
classify fs wm c with (lookupEntry (cid c) wm)
  _ | Just (Descriptile ss) = if satisfied fs ss then Witnessed else Refuted
  _ | Just NoWitness        = Gap
  _ | Nothing               = if hasProbe c then ProbeDeferred else Unmeasured

||| coapt.ncl `mt_gate`: refuted, gap and unmeasured fail; witnessed and
||| probe-deferred do not.
public export
passes : HardStatus -> Bool
passes Witnessed     = True
passes ProbeDeferred = True
passes _             = False

||| The Must/Trust gate over every clause.
public export
hardGate : List Fact -> WMap -> List Clause -> Bool
hardGate fs wm [] = True
hardGate fs wm (c :: cs) =
  if isHard (verb c)
     then (if passes (classify fs wm c) then hardGate fs wm cs else False)
     else hardGate fs wm cs

-- ── The evidence (content-bearing) ──────────────────────────────────────────

||| One spec holds: the very fact the lookup returns, and its predicate.
public export
data Holds : List Fact -> Spec -> Type where
  MkHolds : (f : Fact) -> lookupFact (fact s) fs = f -> evalOp (op s) f = True
         -> Holds fs s

||| A witness: a non-empty spec list, every spec holding.
public export
data Witness : List Fact -> List Spec -> Type where
  MkWitness : NonEmpty ss -> All (Holds fs) ss -> Witness fs ss

||| How a hard clause is resolved. No constructor for a gap.
public export
data HardResolved : List Fact -> WMap -> Clause -> Type where
  ByWitness  : lookupEntry (cid c) wm = Just (Descriptile ss) -> Witness fs ss
            -> HardResolved fs wm c
  ByDeferral : lookupEntry (cid c) wm = Nothing -> hasProbe c = True
            -> HardResolved fs wm c

||| Every hard clause in the list is resolved.
public export
data GateEvidence : List Fact -> WMap -> List Clause -> Type where
  Done  : GateEvidence fs wm []
  Hard  : isHard (verb c) = True -> HardResolved fs wm c
       -> GateEvidence fs wm cs -> GateEvidence fs wm (c :: cs)
  Soft  : isHard (verb c) = False
       -> GateEvidence fs wm cs -> GateEvidence fs wm (c :: cs)

-- ── Lemmas ──────────────────────────────────────────────────────────────────

allSpecsHolds : (fs : List Fact) -> (ss : List Spec) -> allSpecs fs ss = True
             -> All (Holds fs) ss
allSpecsHolds fs [] _ = []
allSpecsHolds fs (s :: ss) prf with (evalSpec fs s) proof p
  _ | True  = MkHolds (lookupFact (fact s) fs) Refl p :: allSpecsHolds fs ss prf
  _ | False = absurd prf

holdsAllSpecs : (fs : List Fact) -> (ss : List Spec) -> All (Holds fs) ss
             -> allSpecs fs ss = True
holdsAllSpecs fs [] [] = Refl
holdsAllSpecs fs (s :: ss) (MkHolds f eq ok :: hs) with (evalSpec fs s) proof p
  _ | True  = holdsAllSpecs fs ss hs
  _ | False = absurd (trans (sym p) (replace {p = \g => evalOp (op s) g = True} (sym eq) ok))

resolveSound : (fs : List Fact) -> (wm : WMap) -> (c : Clause)
            -> passes (classify fs wm c) = True -> HardResolved fs wm c
resolveSound fs wm c prf with (lookupEntry (cid c) wm) proof e
  _ | Just (Descriptile []) = absurd prf
  _ | Just (Descriptile (s :: ss)) with (allSpecs fs (s :: ss)) proof a
    _ | True  = ByWitness e (MkWitness IsNonEmpty (allSpecsHolds fs (s :: ss) a))
    _ | False = absurd prf
  _ | Just NoWitness = absurd prf
  _ | Nothing with (hasProbe c) proof h
    _ | True  = ByDeferral e h
    _ | False = absurd prf

resolveComplete : (fs : List Fact) -> (wm : WMap) -> (c : Clause)
               -> HardResolved fs wm c -> passes (classify fs wm c) = True
resolveComplete fs wm c (ByWitness {ss} e (MkWitness ne hs)) with (lookupEntry (cid c) wm)
  resolveComplete fs wm c (ByWitness {ss = s :: ss'} Refl (MkWitness IsNonEmpty hs)) | Just (Descriptile (s :: ss')) =
    rewrite holdsAllSpecs fs (s :: ss') hs in Refl
resolveComplete fs wm c (ByDeferral e h) with (lookupEntry (cid c) wm)
  resolveComplete fs wm c (ByDeferral Refl h) | Nothing = rewrite h in Refl

-- ── The theorems ────────────────────────────────────────────────────────────

||| Soundness: a passing gate yields evidence for every hard clause.
export
hardGateSound : (fs : List Fact) -> (wm : WMap) -> (cs : List Clause)
             -> hardGate fs wm cs = True -> GateEvidence fs wm cs
hardGateSound fs wm [] _ = Done
hardGateSound fs wm (c :: cs) prf with (isHard (verb c)) proof h
  _ | False = Soft h (hardGateSound fs wm cs prf)
  _ | True with (passes (classify fs wm c)) proof p
    _ | True  = Hard h (resolveSound fs wm c p) (hardGateSound fs wm cs prf)
    _ | False = absurd prf

||| Completeness: evidence for every hard clause makes the gate pass.
export
hardGateComplete : (fs : List Fact) -> (wm : WMap) -> (cs : List Clause)
                -> GateEvidence fs wm cs -> hardGate fs wm cs = True
hardGateComplete fs wm [] Done = Refl
hardGateComplete fs wm (c :: cs) (Hard h r rest) =
  rewrite h in rewrite resolveComplete fs wm c r in hardGateComplete fs wm cs rest
hardGateComplete fs wm (c :: cs) (Soft h rest) =
  rewrite h in hardGateComplete fs wm cs rest

-- ── Worked example (the template's real must.anchor-clause witness) ─────────

exampleFacts : List Fact
exampleFacts = [ MkFact "anchor.authority" "hyperpolymath/standards" True ]

exampleMap : WMap
exampleMap = [ ("must.anchor-clause", Descriptile [MkSpec "anchor.authority" Present]) ]

exampleClauses : List Clause
exampleClauses = [ MkClause "must.anchor-clause" Must False
                 , MkClause "adjust.placeholder-drift" Adjust False ]

||| The gate passes, so evidence exists, and it names the real fact.
exampleEvidence : GateEvidence Coaptation.exampleFacts Coaptation.exampleMap Coaptation.exampleClauses
exampleEvidence = hardGateSound _ _ _ Refl

-- A Must clause whose fact is missing has no witness: `Present` on the
-- absent default fact is False, so the gate is False and `Refl` cannot prove
-- it True. The expected error names the mismatch.
failing "Mismatch between: True and False"
  missingFactFailsGate : hardGate [] Coaptation.exampleMap Coaptation.exampleClauses = True
  missingFactFailsGate = Refl
