#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# PR #244 configuration regressions: the retired runtime policy must not ship,
# and governance must run for pull requests targeting any branch, running the
# standards policy at a full 40-hex SHA: a locked checkout of
# metadatastician/standards, or a locked call of its reusable governance
# workflow.
# PR #257 adds the proof-policy mapping and adopts canon 2.1.3; canon 2.1.4 (an
# editorial PATCH: criteria and gates hashes unchanged) followed, and canon
# 2.1.5 (a PATCH: the gate table 0.3.1 and the applicability policy changed,
# the criteria did not) is adopted here. Since that
# change is documentation and configuration only, check its published contract
# here without invoking any proof compiler or making network requests.
# Usage: bash tests/workflows/governance_policy_test.sh
# Requires Bun; reads local policy documents, YAML and deed fields only.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v bun >/dev/null 2>&1 || { echo 'FAIL: Bun is required' >&2; exit 1; }

bun run - "$REPO_DIR" <<'JS'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const workflows = resolve(process.argv[2], ".github/workflows");
const readYaml = (name) => Bun.YAML.parse(readFileSync(resolve(workflows, name), "utf8"));
const governance = readYaml("governance.yml");
const lock = readYaml("actions.lock");

for (const extension of ["yml", "yaml"]) {
  const retired = `runtime-policy.${extension}`;
  assert.equal(existsSync(resolve(workflows, retired)), false,
    `${retired} must not be copied into newly minted repositories`);
  assert.equal(Object.hasOwn(lock.workflows, `.github/workflows/${retired}`), false,
    `actions.lock must not retain the retired ${retired} record`);
}
console.log("PASS: runtime policy workflow and lock records are retired");

// Check the parsed event, rather than grep for 'branches': push deliberately
// retains its branch filter, while pull_request must have no branch/path/type
// restrictions. Missing pull_request must fail as well as a filtered event.
assert.ok(Object.hasOwn(governance.on, "pull_request"),
  "governance must be triggered by pull requests");
assert.deepEqual(governance.on.pull_request ?? {}, {},
  "governance must accept pull requests targeting any branch without filters");
assert.deepEqual(governance.on.push.branches, ["main", "master"],
  "removing the pull-request branch filter must preserve the push filter");
assert.ok(Object.hasOwn(governance.on, "workflow_dispatch"),
  "manual governance dispatch must remain available");
console.log("PASS: unrestricted pull requests coexist with filtered pushes and manual dispatch");

// Governance must run the standards policy pinned at a full 40-hex SHA, and
// actions.lock must record what it runs. Two shapes satisfy that, and each is
// checked in full:
//   * inline: a step checks out standards at the SHA and runs its scripts
//     (the template's own governance.yml);
//   * caller: the governance job calls standards' reusable governance
//     workflow at the SHA, so the policy is defined once, in standards (the
//     form children such as secret-types use).
// Anything else fails: a missing pin, a tag or branch ref, or a lock record
// that does not match.
const job = governance.jobs.governance;
const lockRecord = lock.workflows[".github/workflows/governance.yml"] ?? [];
const caller = String(job.uses ?? "").match(
  /^(metadatastician|hyperpolymath)\/standards\/\.github\/workflows\/governance-reusable\.yml@([a-f0-9]{40})$/
);
if (job.uses !== undefined) {
  assert.ok(caller,
    "a governance caller must call standards' governance-reusable.yml at a full 40-hex commit SHA");
  const callerUse = `${caller[1]}/standards@${caller[2]}`;
  assert.ok(lockRecord.includes(callerUse),
    "governance's lock record must match the reusable workflow it calls");
  assert.ok(lock.dependencies[callerUse]?.commit,
    "governance's reusable workflow must have a corresponding locked dependency commit");
  console.log("PASS: governance calls the pinned standards policy, and the call is locked");
} else {
  const steps = job.steps ?? [];
  const standardsCheckout = steps.find(
    (s) => s.with && /^(metadatastician|hyperpolymath)\/standards$/.test(String(s.with.repository ?? ""))
  );
  assert.ok(standardsCheckout, "governance must check out standards policy scripts");
  assert.match(String(standardsCheckout.with.ref ?? ""), /^[a-f0-9]{40}$/,
    "governance must pin standards at a full 40-hex commit SHA");
  const checkoutUse = String(standardsCheckout.uses ?? "");
  assert.ok(lockRecord.includes(checkoutUse),
    "governance's lock record must match its checkout action");
  assert.ok(lock.dependencies[checkoutUse]?.commit,
    "governance's checkout action must have a corresponding locked dependency commit");
  console.log("PASS: governance executes the pinned standards policy with locked actions");
}

const root = process.argv[2];
const read = (path) => readFileSync(resolve(root, path), "utf8");
// Ignore wrapping and emphasis when checking prose; keep headings and table
// boundaries intact until the relevant section or row has been selected.
const prose = (text) => text.replace(/[*`]/g, "").replace(/\s+/g, " ").trim();
const section = (text, heading) => {
  const lines = text.split(/\r?\n/);
  const start = lines.findIndex((line) => line.trim() === heading);
  assert.notEqual(start, -1, `missing section: ${heading}`);
  const depth = heading.match(/^[#=]+/)[0].length;
  const end = lines.findIndex((line, index) => index > start &&
    new RegExp(`^[#=]{1,${depth}} `).test(line));
  return lines.slice(start + 1, end < 0 ? undefined : end).join("\n");
};
const claude = read("CLAUDE.md");
const arrival = section(claude, "## Proofs — which prover for which obligation");
const guide = read("verification/proofs/README.adoc");
const mapping = section(guide, "== Which prover for which obligation");
const dependencies = section(guide, "== Third-party code");
const layout = section(guide, "== Directory structure");
const adding = section(guide, "== Adding new proofs");

for (const [name, text] of [["arrival guidance", arrival], ["proof guide", guide]]) {
  assert.match(text, /`3-practice\/PROOF-POLICY\.adoc`/,
    `${name} must name the normative proof policy`);
  assert.match(text, /`hyperpolymath\/standards`/,
    `${name} must identify the policy's authoritative repository`);
}
assert.match(arrival, /`verification\/proofs\/README\.adoc`/);
assert.notEqual(claude.indexOf("<!-- ARRIVAL-PACK:END"), -1,
  "arrival guidance must retain its generated-region boundary");
assert.ok(claude.indexOf("## Proofs — which prover for which obligation") >
  claude.indexOf("<!-- ARRIVAL-PACK:END"),
  "hand-authored proof guidance must survive arrival-pack regeneration");
console.log("PASS: proof guidance points to the canon and lives outside the generated arrival pack");

// Check each association independently: finding every prover somewhere in the
// document would still pass if Rust and Ada, or theory and engineering, swapped.
const markdownRows = arrival.split(/\r?\n/).filter((line) => line.startsWith("|"))
  .map((line) => line.split("|").slice(1, -1).map(prose));
const adocTable = mapping.split("|===")[1];
assert.ok(adocTable, "proof guide must contain the obligation table");
const adocCells = adocTable.split("|").slice(1).map(prose);
assert.equal(adocCells.length % 3, 0, "proof guide table must have three cells per row");
const adocRows = [];
for (let index = 0; index < adocCells.length; index += 3) {
  adocRows.push(adocCells.slice(index, index + 3));
}
for (const [label, arrivalLabel, verifier] of [
  ["Rust code", "Rust code", "Creusot"],
  ["Ada code", "Ada code", "SPARK"],
  ["APIs, ABIs and engineering properties", "APIs, ABIs, engineering properties", "Idris2"],
  ["Theory", "Theory", "Agda"],
]) {
  for (const [name, rows, key] of [
    ["arrival guidance", markdownRows, arrivalLabel], ["proof guide", adocRows, label],
  ]) {
    const matches = rows.filter((row) => row[0] === key);
    assert.equal(matches.length, 1, `${name} must map ${key} exactly once`);
    assert.match(matches[0][1], new RegExp(`^${verifier}\\b`),
      `${name} must assign ${key} to ${verifier}`);
    if (key === "Theory") {
      assert.match(matches[0][1], /Agda, rechecked in Rocq and Lean/);
    }
  }
  console.log(`PASS: both policy tables assign ${arrivalLabel} to ${verifier}`);
}
const location = (label) => adocRows.find((row) => row[0] === label)[2];
assert.match(location("Rust code"), /on the Rust code itself/i);
// PROOF-POLICY section 1.2: agent-facing summaries name Creusot, Pearlite and Verus.
// The proof guide may cite the policy section after the tool list (#303).
assert.match(adocRows.find((row) => row[0] === "Rust code")[1],
  /^Creusot with Pearlite contracts, and Verus( \(policy §1\.2\))?$/);
assert.match(location("Ada code"), /on the Ada code itself.*gnatprove/i);
assert.match(location("APIs, ABIs and engineering properties"), /idris2\/.*ABI proofs are mandatory/);
assert.match(location("Theory"), /agda\/ is the source of truth; coq\/ and lean4\/ hold the recheck legs/);
assert.match(location("Theory"), /Dedukti transport first, hand re-proof as the fallback; no Mathlib/);
assert.match(prose(arrival), /no Mathlib/);
console.log("PASS: proof locations preserve mandatory ABI proofs and both theory recheck legs");

const obligations = prose(mapping);
assert.match(obligations, /types, functions or wire formats are engineering \(Idris2\)/);
assert.match(obligations, /any implementation are theory \(Agda\)/);
assert.match(obligations, /first-party Rust or Ada code.*Creusot\/Pearlite and Verus \(Rust\) or SPARK \(Ada\) on that code, not restated in Idris2/);
assert.match(obligations, /Plan scopes for both Rust verifiers/);
assert.match(obligations, /recorded beside the artefact and in docs\/status\/PROOF-STATUS\.adoc/);
assert.match(obligations, /tlaplus\/.*finite model check is reported as TESTED, with its bounds/);
assert.match(obligations, /Kani \(unsafe and FFI seams, reported TESTED with bounds\)/);
assert.match(obligations, /Aeneas \(Rust that implements an Agda-proved theorem\)/);
assert.match(obligations, /alongside the default toolset, never instead of it/);
assert.match(prose(arrival), /Kani for unsafe\/FFI seams and Aeneas.*Agda theorem.*alongside, never instead/);
console.log("PASS: engineering boundaries and bounded exceptions preserve the primary verifier");

assert.match(prose(dependencies), /not converted, re-proved or annotated/);
assert.match(prose(dependencies), /trusted boundary specification.*ASSUMED.*dependency and version.*docs\/status\/PROOF-STATUS\.adoc/);
assert.match(prose(arrival), /not converted or re-proved.*ASSUMED boundary specification/);
for (const text of [dependencies, arrival]) {
  assert.match(prose(text), /fit equally well.*prefer one that carries its own verification/i);
  assert.match(prose(text), /preference, not a gate/i);
}
console.log("PASS: third-party dependencies remain ASSUMED boundaries and verification is a preference");

// Negative regression: a shipped example, even one with a gated manifest
// entry, must never become evidence of completed proofs or a theory recheck.
const examples = prose(layout);
for (const file of ["Properties.agda", "TypeSafety.v", "ApiTypes.lean", "Types.idr", "StateMachine.tla"]) {
  assert.ok(examples.includes(file), `layout guidance must identify example ${file}`);
}
assert.match(examples, /layout examples, not evidence/);
assert.match(examples, /quarantine.*MANIFEST/);
assert.match(examples, /TypeSafety\.v and ApiTypes\.lean are not rechecks of Properties\.agda/);
assert.match(examples, /replaces them with its own proofs or deletes them, and never counts them in docs\/status\/PROOF-STATUS\.adoc/);
console.log("PASS: shipped examples cannot be counted as proof evidence or theory rechecks");

assert.match(prose(adding), /classify the obligation.*docs\/status\/PROOF-NEEDS\.adoc/i);
assert.match(prose(adding), /put Rust and Ada proofs on the code/i);
assert.match(prose(adding), /%default total/);
assert.match(prose(adding), /run the verification command/i);
assert.match(prose(adding), /docs\/status\/PROOF-STATUS\.adoc.*recheck legs.*ASSUMED boundary specifications/);
for (const path of ["docs/status/PROOF-NEEDS.adoc", "docs/status/PROOF-STATUS.adoc"]) {
  assert.ok(existsSync(resolve(root, path)), `proof tracking document must exist: ${path}`);
}
console.log("PASS: new proof instructions require needs, verification, rechecks and assumptions");

// Keep the independently specified release tuple together: a version-only
// bump or retaining the previous gates hash would misidentify the canon.
// Update this expectation deliberately when adopting the next canon release.
const field = (key) => execFileSync("bash", [resolve(root, "scripts/deed-field.sh"),
  resolve(root, "rsr-template-repo_chora.deed"), "canon", key], { encoding: "utf8" }).trim();
assert.deepEqual([field("version"), field("criteria-sha256"), field("gates-sha256")], [
  "2.1.5",
  "6a5aa8857bd0d0d58ef48827938ca17c251b6b854dacf59d306388d61694d82a",
  "5c510bba025be718deebb12d0333bfe7db2da43c66578b728b1a334df65290b1",
], "canon 2.1.5 keeps the criteria identity and adopts the gate table 0.3.1 identity");
console.log("PASS: the deed adopts the complete canon 2.1.5 identity");
JS
