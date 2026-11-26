K9!
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# claude-md.k9.ncl — k9 contract for the CLAUDE.md arrival-pack drift check.
#
# Yard-tier (pure evaluation / comparison; no exec, no network, no FS write):
# the check regenerates the arrival-pack region from this repo's deed and asserts
# the committed CLAUDE.md region byte-matches it. The runnable side is verify.sh;
# writing (Hunt-tier) is generate.sh. This record documents and validates the
# contract shape.
{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "drift-check:claude-md-arrival-pack",
    contractile_verb = "trust",   # provenance: the view must equal its source
    semantics = "projection-fidelity",
    security = {
      leash = 'Yard,
      trust_level = "read-only comparison",
      allow_network = false,
      allow_filesystem_write = false,
      allow_subprocess = false,   # verify.sh runs extract.sh + nickel; this record does not
    },
    metadata = {
      name = "claude-md-arrival-pack",
      version = "1.0.0",
      description = "CLAUDE.md arrival pack is a faithful projection of this repo's deed.",
      paired_runner = "verify.sh",
      writer = "generate.sh",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
  },

  # Inputs the projection reads (single source of truth).
  inputs = {
    # The repo deed (<repo>_chora.deed) is the only authored input; the golden
    # path is its (anchor (golden-path)) clause (rsr-template-repo#209).
    descriptiles = [
      "<repo>_chora.deed",
    ],
    # Facts read from the tree, never authored: the pack states them instead of
    # asserting them, so a repo with legacy A2ML is not told it has none.
    tree_facts = [
      "tracked .a2ml files: git ls-files '*.a2ml', each path once (every .a2ml under the tree, minus .git/, outside a git work tree, where the region says 'contains')",
      "which of (anchor) (agentic) (ecosystem) (status) (maturity) (neurosym) (playbook) (meta) (bot-directives (methodology) (coverage) (debt)) the deed has",
    ],
    estate_common = "hyperpolymath/manifesto@<pinned-sha>",  # DRAFT-unratified today
    target = "CLAUDE.md",
    markers = { begin = "<!-- ARRIVAL-PACK:BEGIN", end = "ARRIVAL-PACK:END" },
  },

  # Checks (all must hold).
  checks = [
    { id = "inputs-exist",   desc = "exactly one repo deed exists, parses as exactly one form (nothing but whitespace and comments outside it) and carries (anchor (golden-path))" },
    { id = "region-present", desc = "CLAUDE.md contains exactly one BEGIN/END region" },
    { id = "no-drift",       desc = "committed region byte-equals freshly generated region" },
    { id = "facts-derived",  desc = "the region names a clause as a deed clause only if the deed has it, says there are no .a2ml files only if none is tracked, and names a legacy file only if it is tracked" },
  ],

  run = {
    on_any_fail = "exit-nonzero",   # gate (trust-tier): drift blocks
    command = "bash .machine_readable/arrival-pack/verify.sh",
  },
}
