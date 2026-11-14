K9!
# SPDX-License-Identifier: MPL-2.0
# Adversarial and negative-control test fixtures (proven-tests-and-benches
# Silence + Firing doctrine). Documents why negative test suites name banned
# patterns or feed malformed inputs into gates so human reviewers and scanners
# do not mistake Firing controls for production defects.

{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "testing:adversarial-controls",
    metadata = {
      name = "rsr-adversarial-controls",
      version = "0.1.0",
    },
    security = {
      leash = 'Kennel,
    },
  },

  adversarial_suites = [
    {
      path = "tests/proven_suite_test.sh",
      purpose = "Generates ephemeral Idris2 escape-hatch mutants and benchmark regressions inside mktemp to prove check-escape-hatches.sh, check-bench-regression.sh, compute-bench-baseline.sh, and emit-aggregate-inputs.sh fire with exact 0/1/2 exit codes.",
    },
    {
      path = "tests/workflows/check_ijson_jcs_test.sh",
      purpose = "Feeds duplicate keys, integers outside +/-(2^53-1), lone UTF-16 surrogates, Unicode noncharacters, and non-JCS formatting into check-ijson-jcs.sh.",
    },
    {
      path = "tests/workflows/squabble_gate_test.sh",
      purpose = "Plants admin-override strings, continue-on-error masks, and phantom ruleset contexts into ephemeral workflow fixtures to prove cicd-squabbler and check-required-contexts.sh fire.",
    },
    {
      path = "tests/workflows/secret_scanner_contract_test.sh",
      purpose = "Mutates the shipped secret-scanner workflow — renames a job, deletes one, adds `secrets: inherit`, adds a secrets.* read, widens the permission grant, unpins an action, retargets push away from the default branch, drops pull_request, drops concurrency, and converts a job to a remote reusable call — to prove the three stable scanner contexts stay this repository's own.",
    },
    {
      path = "tests/workflows/governance_badge_test.js",
      purpose = "Feeds malformed lane artifacts, malformed existing badge files, 401/403/429/5xx responses, a dead API and 409 sha conflicts into scripts/governance-badge.js against a mock GitHub API, and runs the workflow-wiring checks against a mutated workflow, to prove the publisher never publishes a false green and never dedupes a changed badge.",
    },
    {
      path = "www/tests/controls",
      purpose = "Planted open-recursion BIND9, over-broad Caddyfile, and invalid AIBDP status controls.",
    },
  ],
}
