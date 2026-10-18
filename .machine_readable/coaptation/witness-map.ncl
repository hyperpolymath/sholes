# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# witness-map.ncl — the KNOWLEDGE layer of Coaptation (step 2 of the build path).
#
# Declares, for the clauses that CAN be witnessed by descriptive evidence, which
# descriptile fact(s) bear that witness and under what predicate. This is the one
# hand-authored, human-reviewable file in the pack: it encodes the correspondence
# between a normative obligation (a contractile clause) and the descriptive facts
# that attest it.
#
# A clause NOT listed here is graded automatically by the comparator:
#   - it has a runnable probe        -> "probe-deferred" (only Hunt can judge it)
#   - it has neither witness nor probe -> "unmeasured" (a real Yard coverage hole)
#
# Predicate ops (over a fact's value/present):
#   'present | 'absent | 'zero | 'nonzero | 'equals | 'contains | 'not_contains
# 'equals/'contains/'not_contains take `arg`. A clause's witnesses ALL must hold.
#
# Soundness-critical entries (the Must/Trust gates) are the ones to graduate to
# Idris2 `Witnesses` proofs in a later session (build-path step 6); today they are
# declarative. Keep this list HONEST: only assert a witness you can defend — the
# whole point is to make boundary-erosion visible, not to manufacture green.
{
  # --- MUST: presence obligations ---
  # must.machine-readable-dir has NO descriptile witness any more. It was
  # attested by "anchor.authority is present", which held because that fact was
  # read from descriptiles/anchors/ANCHOR.a2ml. The anchor now lives in the root
  # deed's (anchor …) clause, so the fact says nothing about the directory;
  # keeping the witness would manufacture green. It is probe-deferred to Hunt.
  "must.anchor-clause" = {
    kind = "descriptile",
    witnesses = [{ fact = "anchor.authority", op = 'present }],
    note = "anchor.authority is read from the deed's (anchor) clause, so its presence IS the clause's presence",
  },
  # must.six-directory-present has NO descriptile witness. Its probe needs
  # descriptiles/PLAYBOOK + NEUROSYM and exactly one deed, and no fact here
  # attests that: state and ecosystem are deed clauses since rsr-template-repo#209,
  # and the anchor facts come from the deed. It is probe-deferred to the Hunt tier.

  # --- TRUST: deliberately NO descriptile witness. ---
  # Every Trust obligation here (no-secrets / no-private-keys / author-correct /
  # license-content / …) is a filesystem-or-git probe. The descriptive self-model
  # carries NO security/provenance evidence that can attest them in the Yard tier,
  # so they are all reported `probe-deferred` and need a Hunt run. We do NOT witness
  # `trust.author-correct` with `clade.forge-github` — forge OWNERSHIP is not git
  # AUTHORSHIP, and resting a Trust gate on that proxy would be a manufactured green.
  # The `boolean_gate_provenance` grade (a witness carrying its source hash) is a
  # declared capability awaiting a descriptile that actually carries such evidence.

  # --- INTEND: a committed intent realised by the descriptive self-model ---
  "intend.repo-initialization" = {
    kind = "descriptile",
    witnesses = [{ fact = "ecosystem.type", op = 'equals, arg = "repository-template" }],
    note = "the deed (ecosystem :position-type) declares this repo IS a template ⇒ the init intent is realised",
  },

  # --- ADJUST: accessibility/hygiene posture (advisory; never gates) ---
  # The ANCHOR identity block still carries {{PROJECT_NAME}}; for the template
  # itself that is expected, but it is honestly a posture dip worth surfacing.
  "adjust.placeholder-drift" = {
    kind = "descriptile",
    witnesses = [{ fact = "anchor.project", op = 'not_contains, arg = "{{" }],
    note = "deed (anchor (identity :project)) is un-substituted ({{PROJECT_NAME}}) ⇒ posture dip",
  },

  # --- BUST: deliberately NO descriptile witness since rsr-template-repo#209. ---
  # The bust entries used to read STATE.a2ml open-failures / last-result. Those
  # were hand-written values ("0", "unknown") that no maintenance run ever
  # updated, and the deed has no such field, so there is no descriptive evidence
  # of an active break to witness. A bust clause without a witness reads
  # "latent", the same as a witnessed non-alarm: the receipt cannot tell the two
  # apart, so do not read "latent" as "checked".
}
