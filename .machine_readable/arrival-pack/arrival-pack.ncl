# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# arrival-pack.ncl — the projection ENGINE for the CLAUDE.md arrival pack.
#
# Pure Nickel. Imports the deterministic JSON produced by extract.sh (the deed
# reader) and renders the generated CLAUDE.md region as a single string.
# Emit with:  nickel export --format raw --file arrival-pack.ncl
#
# Two halves (see ARRIVAL-PACK-DESIGN):
#   A. estate-common  — identical everywhere; DRAFT doctrine, pinned to a
#                        Manifesto SHA once ratified (today: DRAFT-unratified).
#   B. repo-specific  — projected from this repo's deed (data.*).
#
# The deed remains the single source of truth; this is a VIEW. Hand-editing
# the emitted region is a flagged error (see claude-md.k9.ncl drift check).
let data = import "claude-md-data.json" in

# Pin to a Manifesto commit once the doctrine wording is ratified into the
# owner's voice. Until then the estate-common block is explicitly DRAFT.
let manifesto_pin = "DRAFT-unratified" in

# The estate deny list, stated once: the language-policy line below prints it,
# and the anchor override compares the anchor's allowed list against it.
let estate_denied = ["Nix", "Python", "Go", "TypeScript", "ReScript", "AGPL"] in

# An anchor overrides the estate policy for its repo in two ways: it forbids
# what the estate permits, and it allows what the estate denies. Both are
# rendered, or the pack would tell an agent that an estate denial applies in a
# repo whose anchor allows the language (Codex review of sholes#13). A language
# the anchor allows and the estate does not deny is no override and is not
# listed. Names are compared as written. AGPL is a licence, not a language: no
# anchor can lift that denial (owner ruling by selector, 2026-11-19), so it is
# never counted as allowed.
let anchor_allows_denied =
  std.array.filter
    (fun l => l != "AGPL" && std.array.elem l estate_denied)
    data.anchor_allowed
in
let anchor_override =
  let allows = std.string.join ", " anchor_allows_denied in
  let forbids = std.string.join ", " data.anchor_forbidden in
  let has_allows = std.array.length anchor_allows_denied > 0 in
  let has_forbids = std.array.length data.anchor_forbidden > 0 in
  let lead = "\n- **Anchor override** (ANCHOR) — This repo's anchor " in
  let tail = ". The anchor overrides the estate policy above." in
  if has_allows && has_forbids then
    "%{lead}allows, where the estate policy above denies: %{allows}; it forbids: %{forbids}%{tail}"
  else if has_allows then
    "%{lead}allows, where the estate policy above denies: %{allows}%{tail}"
  else if has_forbids then
    "%{lead}forbids: %{forbids}%{tail}"
  else ""
in

# The Constraints line must not contradict the override line: where the anchor
# allows a denied language, "banned langs" names the exception (Codex review of
# bactrian#39). With no such allowance the line is unchanged.
let banned_langs =
  if std.array.length anchor_allows_denied > 0 then
    "banned langs (above, except those this repo's anchor allows: %{std.string.join ", " anchor_allows_denied})"
  else "banned langs (above)"
in

let provenance = "DEED@%{data.h_deed} ANCHOR@%{data.h_anchor}"
in

# What the deed holds and what the tree still tracks are FACTS read by
# extract.sh, not assertions of this engine: the clauses the deed has (`has`),
# the tracked legacy .a2ml files (`a2ml_count`), and the ones that carry the
# name of a clause (`legacy`). A clause the deed lacks is stated as absent, and
# a legacy file is named only if extract.sh found it tracked. This template
# (every clause, every field the pack reads, no .a2ml file) gets the text below
# unchanged. A deed that has a clause but not the field the pack reads from it
# (a (status) with no :phase) now reads "not declared" where it read empty.
let has = data.has in
let legacy = data.legacy in
# A pipe would end a GFM table cell even inside backticks, so it is escaped.
let ticks = fun files => std.string.join ", " (std.array.map (fun f => "`%{std.string.replace "|" "\\|" f}`") files) in
let legacy_what = fun files =>
  let n = std.array.length files in
  if n == 0 then ""
  else if n == 1 then "legacy file %{ticks files}, read-only pending conversion"
  else "legacy files %{ticks files}, read-only pending conversion"
in
# After a sentence part, inside parentheses ("; …"), and as a parenthesis (" (…)").
let legacy_note = fun files => if files == [] then "" else "; %{legacy_what files}" in
let legacy_paren = fun files => if files == [] then "" else " (%{legacy_what files})" in
let undeclared = fun clause key v =>
  if v == "" then "(not declared — the deed's %{clause} has no :%{key})" else v
in

# The substrate paragraph: the clauses the deed has, then the .a2ml sentence.
let clauses = [
  { name = "(anchor)",    present = has.anchor,    files = legacy.anchor },
  { name = "(agentic)",   present = has.agentic,   files = legacy.agentic },
  { name = "(ecosystem)", present = has.ecosystem, files = legacy.ecosystem },
  { name = "(status)",    present = has.status,    files = legacy.state },
  { name = "(maturity)",  present = has.maturity,  files = legacy.state },
  { name = "(neurosym)",  present = has.neurosym,  files = legacy.neurosym },
  { name = "(playbook)",  present = has.playbook,  files = legacy.playbook },
] in
let missing = std.array.filter (fun c => !c.present) clauses in
let clause_sentence =
  if std.array.length missing == 0 then
    "ANCHOR, AGENTIC, ECOSYSTEM, STATE, NEUROSYM and PLAYBOOK are clauses of the CHORA deed — `(anchor)`, `(agentic)`, `(ecosystem)`, `(status)` and `(maturity)`, `(neurosym)`, `(playbook)` — not files; STATE's journal is `docs/status/ROADMAP.adoc`."
  else
    let in_deed = std.array.filter (fun c => c.present) clauses in
    let in_list = std.string.join ", " (std.array.map (fun c => "`%{c.name}`") in_deed) in
    let out_list = std.string.join "; " (std.array.map (fun c => "`%{c.name}`%{legacy_paren c.files}") missing) in
    "ANCHOR, AGENTIC, ECOSYSTEM, STATE, NEUROSYM and PLAYBOOK are meant to be clauses of the CHORA deed, not files, but this repo's deed does not have them all yet. In its deed: %{in_list}. Not yet in its deed: %{out_list}. STATE's journal is `docs/status/ROADMAP.adoc`."
in
let a2ml_sentence =
  let n = data.a2ml_count in
  # Outside a git work tree the files were found on disk; nothing is tracked.
  let holds = if data.a2ml_source == "git-index" then "tracks" else "contains" in
  if n == 0 then "There are no `.a2ml` files in this estate."
  else if n == 1 then "This repo still %{holds} 1 legacy `.a2ml` file, awaiting conversion to deed clauses (kyX, ruling D313): it is read-only pending that conversion; never create, restore or extend one, and you may only delete content from it."
  else "This repo still %{holds} %{std.string.from_number n} legacy `.a2ml` files, awaiting conversion to deed clauses (kyX, ruling D313): they are read-only pending that conversion; never create, restore or extend one, and you may only delete content from one."
in

# The CHORA row names the clauses the deed has, in the order it always has.
let chora_clauses =
  let status_part =
    if has.status && has.maturity then ["`(status)` and `(maturity)` where it is now"]
    else if has.status then ["`(status)` where it is now"]
    else if has.maturity then ["`(maturity)` where it is now"]
    else []
  in
  # each part carries its own "; " so that a deed with none of them adds nothing
  std.string.join "" (std.array.map (fun p => "; %{p}") (
    (if has.meta then ["`(meta)` the architecture axes"] else [])
    @ (if has.agentic then ["`(agentic)` *may I act now?*"] else [])
    @ (if has.ecosystem then ["`(ecosystem)` where it sits and what it is not"] else [])
    @ status_part
  ))
in
let neurosym_row =
  if has.neurosym then "| `(neurosym)` | *Meaning* of operations — proof obligations. |"
  else "| `(neurosym)` | *Meaning* of operations — proof obligations. Not yet in this repo's deed%{legacy_note legacy.neurosym}. |"
in
let playbook_row =
  if has.playbook then "| `(playbook)` | *How* permitted actions run. |"
  else "| `(playbook)` | *How* permitted actions run. Not yet in this repo's deed%{legacy_note legacy.playbook}. |"
in

# The per-repo block: each line reads clauses that may be absent.
let absent_ecosystem = "not yet in the deed: no `(ecosystem)` clause%{legacy_paren legacy.ecosystem}" in
let is_line =
  if has.ecosystem then undeclared "(ecosystem)" "purpose" data.purpose else absent_ecosystem
in
let isnot_line = if has.ecosystem then data.isnot else absent_ecosystem in
let sits_line =
  if has.ecosystem then
    "pipeline position **%{undeclared "(ecosystem)" "pipeline-position" data.pipeline_pos}**; chain `%{undeclared "(ecosystem)" "chain" data.chain}`; coordination = `%{undeclared "(ecosystem)" "coordination" data.coordination}`."
  else "%{absent_ecosystem}."
in
let bd_subs = std.string.join " " (std.array.map (fun s => "(%{s})") has.bot_directives) in
let bd_sentence =
  if std.array.length has.bot_directives == 0 then
    " Details: not yet in the deed (`(bot-directives)` has no `(methodology)`, `(coverage)` or `(debt)` clause%{legacy_note legacy.bot_directives})."
  else " Details: the deed's `(bot-directives %{bd_subs})` clauses."
in
let constraints_line =
  if has.agentic then
    "fail-closed; evidence-per-step; no-silent-skip; rerun-after-fix; release-claim-requires-hard-pass. Never: %{banned_langs}, secrets, state files in repo root, AGPL.%{bd_sentence}"
  else
    "not yet in the deed: no `(agentic)` clause%{legacy_paren legacy.agentic}. The estate policy above applies.%{bd_sentence}"
in
let phase_text =
  if has.status then undeclared "(status)" "phase" data.phase
  else "unknown (not yet in the deed: no `(status)` clause%{legacy_note legacy.state})"
in
let maturity_text =
  if has.maturity then undeclared "(maturity)" "level" data.maturity
  else "unknown (not yet in the deed: no `(maturity)` clause%{legacy_note legacy.state})"
in

m%"
<!-- ARRIVAL-PACK:BEGIN — estate-common @Manifesto:%{manifesto_pin} · repo @deed:%{provenance} — generated by `just claude-md`, do not hand-edit -->

# You are in the hyperpolymath estate — orient before acting

**First, read `metadatastician/standards` `STANDING-RULES.adoc` at the start of every session; it overrides anything older here.** Raw: https://raw.githubusercontent.com/metadatastician/standards/main/STANDING-RULES.adoc

If you are unsure what something is, **read the canon; do not guess** (guessing is how the fake `lith` monorepo got fabricated). Start here, then the files named below.

## Doctrine (the rules here)
1. **Holes before anything else** — fix soundness holes before features/perf/docs.
2. **Fixes first, on firm foundations** — ground-truth by running the tool, not trusting status docs.
3. **Fail loudly, seal soundly** — no silent green; seams (ABI/FFI) sealed & proven.
4. **Distrust the neural for exactness** — licences/invariants/equivalence belong to **PLASMA** (formal), not to an LLM. Your edits there are provisional + supervised.
5. **Squabble, don't bypass** — reach green by *satisfying* the gate, never by admin-override.
6. **No automated licence edits — ever** — manual, owner-only; third-party untouchable.
7. **No deletion by access-recency** — cold ≠ disposable.
8. **Wire first** — unwired is not done.
9. **Always sign** commits (`id_ed25519_signing`; verify `status:G`).
10. **Report faithfully — no overclaim** (the AFFIRMATION ethos).
11. **Stop-first** when an action is costly to undo or outward-facing.
12. **Boundaries are real** — respect IS / IS-NOT; never assimilate or rename across them.
13. **Equivalence as identity** — the estate's intellectual through-line.
14. **Solutions at source** — fix the canonical/upstream origin, never patch the downstream symptom; trace and respect every up- and down-stream before you act.
15. **Elegance by default** — treat the most elegant and correct long-term option as the default arm; when you put a choice to the owner, LABEL which option that is, and if you recommend another, name both arms and say why you depart. Binds unasked design calls too: report the departure, never absorb it.
16. **Cheap models for upkeep**: CI/CD, workflow, template-drift and status-file work does not get a top-tier model. If it needs real effort, stop and say so, then open a thread on cheaper models (Sonnet and Haiku). Keep top-tier models for proof work and hard design.

## The machine-readable substrate (read in this order on arrival)
**CHORA** → **ANCHOR** → **AGENTIC** → **ECOSYSTEM** → **STATE** -> **NEUROSYM** -> **PLAYBOOK**

%{clause_sentence} %{a2ml_sentence}

The descriptive family (working name *descriptiles*) describes what-is; the **contractiles** are the normative set-point.

| File | Answers |
|---|---|
| `%{data.deed}` | **CHORA**, the repo deed. Its header `:repo-uuid` is the repo's one id, and `(identity)` and `(lineage)` say what this repo IS; a `(clade)` clause, when present, records the repo's clade placements: identity facts about where it sits, never its id and never an edict. chora-registry is authoritative for them; this repo's validation checks only that a declared clade is one of the 12 shelves%{chora_clauses}. Read fields with `scripts/deed-field.sh`. |
| `(anchor)` | *Semantic authority + golden path* — what downstream may extend-not-redefine; if a recognised-drift / re-anchor marker is present, it **supersedes** accumulated context — read it first. |
%{neurosym_row}
%{playbook_row}
| `docs/status/ROADMAP.adoc` | *What is next* — milestones, blockers, next actions. |
| contractiles | Normative doctrine: **Intend** (north-star) · **Must** (invariants) · **Trust** (security) · **Adjust** (accessibility / inclusive design) — the integral core that holds strong; plus **Dust** (exnovation drift) · **Bust** (failure / breakage, not drift). |
| k9 | *Validation*. Kennel (data) / Yard (pure eval) / Hunt (guarded exec). |

**The chora and CLADE are different things** (owner, 2026-11-15; standards A1 CHORA-SPEC §11.1):
- **The chora is ontological/metaphysical**: what this repo *is* and is meant to be in its context, code as identity: its intension (what defines it) and its extension (what it is an instance of). A `(clade …)` placement in it is an identity fact, copied from chora-registry, and the registry wins; never take one from a legacy file.
- **`CLADE.deed` is logical/epistemological**: how this repo's own content is ordered. Its scheme may be strict (Linnaean), judgement or none; membership may be single or multiple; a category is decided by its criterion. It is a descriptile and never identity; none is created until A7 M3 `clade` lands.
- **The aesthetic spans both**: what one experiences of the repo from outside, and in its ordering within.
- A legacy `CLADE.a2ml`, or A2ML named `CLADE.deed`, feeds the chora and `STATE.deed` (standards `clade-to-repo-deed.adoc`), never a `CLADE.deed`.

## Canon pointers
Estate data-format route: **kyq** handles exactly **TOML, Dhall, KYAML,
I-JSON/JCS**. Preserve TOML/Dhall; migrate YAML/YML to KYAML and JSON variants
through kyq using **hyperpolymath/ijson-jcs**, the actual estate implementation
repository. **kyX** owns wider projection. DEED/K9/coordination keep their own
grammars. Canon: `metadatastician/standards/3-practice/DATA-FORMAT-ROUTING.adoc`.
Planned support is not operational evidence: retain explicit transitional
checks until a pinned kyq executable passes positive and negative tests.

- `metadatastician/standards` — the canon source. · `hyperpolymath/chora-registry` — the estate registry of repo identities and classification schemes. · `hyperpolymath/manifesto` — this doctrine.
- **Before you invent, rename, or consolidate anything: STOP and check the map + IS-NOT.**

## Estate language policy (overridable per-repo via AGENTIC)
Deny: **%{std.string.join ", " estate_denied}**. (Guix, not Nix.)
JavaScript runtime: **Bun** > Deno > pnpm > npm (last resort, permitted), from one `package.json` that carries every runtime's lock (`bun.lock`, `deno.lock`, `pnpm-lock.yaml`), all written by `js-runtimes regen` (owner ruling 2026-10-14, standards LANGUAGE-POLICY §1.3–§1.4). Deno is permitted again; `package-lock.json` stays refused.
Use plain JavaScript when this tooling is needed. TypeScript and ReScript migrate to AffineScript.

## Asking the owner
Put every question that needs the owner's decision through the selector (the AskUserQuestion tool), not as prose at the end of a report. Batch up to four per call, offer concrete options with the recommended one first, and say what each option would cause.

## Proofs — which prover for which obligation

Normative source: `3-practice/PROOF-POLICY.adoc` in `hyperpolymath/standards`.
Read it there; `verification/proofs/README.adoc` maps it onto this repo.

| Code or obligation | Verifier |
|---|---|
| Rust code | **Creusot** with **Pearlite** contracts, and **Verus**, by default and on the code (§1.2). Kani for `unsafe`/FFI seams and Aeneas for Rust that implements an Agda theorem run alongside, never instead |
| Ada code | **SPARK** |
| APIs, ABIs, engineering properties | **Idris2** |
| Theory | **Agda**, rechecked in **Rocq** and **Lean** (no Mathlib) |

Always name Creusot, Pearlite and Verus in Rust verification plans and in
`docs/status/PROOF-STATUS.adoc`. Pearlite is Creusot's specification
language, not a third verifier. Plan scopes for both verifiers, and record
any that is unsupported, inapplicable or not yet run, with its reason; never
present an unexecuted check as a pass. Using both does not make two
independent witnesses (policy §1.2).

Third-party code (crates such as Bevy, libraries, forks) is **not** converted
or re-proved. Where a proof relies on a dependency the prover does not check,
state the reliance as an `ASSUMED` boundary specification. Where the
dependency's whole import cone compiles under the prover's safe mode with zero
postulates, it is *checked, not assumed*: record the cone (root module, flags,
postulate count of zero, library name, version and pin) instead of an
`ASSUMED` row (policy §1.1). A cone with a postulate, or compiled outside safe
mode, is not checked. When choosing between dependencies that fit equally
well, prefer one that carries its own verification. A preference, not a gate.

Proof Witness Grades are policy §8. They apply to *theory* theorems only: Agda
source, rechecked in Rocq and Lean (§8.1). Engineering proofs (Creusot, Verus,
SPARK, Idris2) are not graded on this ladder; they use the §5 tokens only. For
a theory theorem, `PWG-3` < `PWG-2i` < `PWG-2ii` < `PWG-1`, where `PWG-1` is
strongest. A theorem that does not reach `PWG-3` is `ungraded`, with no
qualifier. A grade is derived from receipts, never asserted. A "verified" or
"machine-checked" claim needs current receipts. Report a census with its
denominator, never a percentage. Always write the `PWG-` prefix: CRG, TRG, ARG
and FRG letters, and ECHIDNA's `TrustLevel`, are different schemes.

---

# This repo: `%{data.canonical_name}`

- **Identity** — chora id `%{data.uuid}`; clade: %{data.clade_aid}; born %{data.born}; forge `%{data.forge_gh}`.
- **IS** — %{is_line}
- **IS-NOT** — %{isnot_line}
- **Where it sits** — %{sits_line}
- **Constraints here** (AGENTIC) — %{constraints_line}
- **Golden path** (ANCHOR) — `%{data.golden_smoke}` → %{data.golden_crit}.%{anchor_override}
- **State** — phase %{phase_text}; maturity %{maturity_text}. Milestones and next actions: `docs/status/ROADMAP.adoc`.

<!-- ARRIVAL-PACK:END · provenance: %{provenance} · Manifesto@%{manifesto_pin} · regenerate: `just claude-md` (k9 drift-detects; do not hand-edit above) -->
"%
