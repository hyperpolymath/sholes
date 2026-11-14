# gitbot-fleet report-backs

One JSON envelope per enrolled fleet member, `<member>.json`, in the shape
metadatastician/standards `docs/VERDICT-GRID-SPEC.adoc` defines ("The
report-back envelope"). The Hypatia verdict grid gives every member named in
`../enrolment.json` one row; the row stays **orange** ("enrolled, but no
report-back was received") until an envelope is present here when the grid
renders.

**This directory is empty in git on purpose, and stays so.** Envelopes are
produced per run by the `fleet` job of `.github/workflows/fork-governance.yml`
(gitbot-fleet `scripts/fleet-report-back.sh`), uploaded as the
`fleet-report-backs` artifact, and read from that artifact at render time by the
`verdict` job of the same workflow, which passes this directory to the grid
renderer. A committed envelope would be stale evidence about an older commit, so
none is ever committed. Do not add a placeholder to turn a row green; only a
real run may.

Two related rules:

* an enrolled member with **no** envelope renders **orange** ("enrolled, but no
  report-back was received") — never green, and never grey
  (`docs/HYPATIA-RULE-ORDER.adoc`);
* a member that reports back without an enrolment entry still gets a row from
  its envelope alone. Enrolment decides what a *missing* envelope means; it does
  not decide what a present one is allowed to say
  (metadatastician/standards `docs/VERDICT-GRID-SPEC.adoc`).

When instantiating a repository from this template, edit `../enrolment.json`:
enrol what is true of the repository, with a reason for every member that does
not apply. The template defaults enrol rhodibot, finishingbot and glambot,
which apply to every estate repository. Adoption guide: standards
`3-practice/fork-governance/ADOPTION.adoc` §8.

Only files matching `*.json` are read, so this README is inert.
