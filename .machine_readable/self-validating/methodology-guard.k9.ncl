K9!
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) {{CURRENT_YEAR}} {{AUTHOR}} ({{OWNER}}) <{{AUTHOR_EMAIL}}>
#
# K9 Validator: Methodology Guard
# Checks that agent work respects methodology constraints declared in the
# repo deed's (bot-directives (methodology)) clause, read with
# scripts/deed-field.sh.
#
# Usage: k9 validate methodology-guard

let methodology_guard = {
  name = "methodology-guard",
  version = "1.0.0",
  description = "Validates that agent work respects declared methodology constraints",

  pedigree = {
    schema_version = "1.0.0",
    metadata = {
      name = "methodology-guard",
      version = "1.0.0",
    },
    security = {
      leash = 'Yard,
    },
  },

  checks = {
    divergent_invariant_language = {
      description = "No files in languages violating the divergent language invariant",
      severity = "error",
      # When methodology.divergent-invariants.language-invariant is set,
      # check that no new files introduce a different language for that purpose.
      # Example: if language-invariant = "idris2", reject new .lean or .v files
      # in the proof directories.
      check_type = "file-extension-guard",
      scope = "src/",
    },

    believe_me_ceiling = {
      description = "believe_me count must not exceed declared ceiling",
      severity = "error",
      pattern = "believe_me",
      ceiling_key = "methodology.divergent-invariants.believe-me-ceiling",
      default_ceiling = 0,
    },

    assert_total_ceiling = {
      description = "assert_total count must not exceed declared ceiling",
      severity = "error",
      pattern = "assert_total",
      ceiling_key = "methodology.divergent-invariants.assert-total-ceiling",
      default_ceiling = 0,
    },

    state_not_template = {
      description = "The ROADMAP journal must not contain template placeholders",
      severity = "warning",
      # The journal, not the repo deed: a deed names rsr-template-repo in
      # (lineage :instantiated-from) by design, so this pattern would always
      # fire there.
      file = "docs/status/ROADMAP.adoc",
      # NOTE: the PROJECT token below is written as a Nickel concat
      # ("{{" ++ "PROJECT}}") ON PURPOSE. `just repo-init` runs a sed substitution for
      # the brace-PROJECT-brace token over EVERY text file, which would otherwise
      # rewrite this guard's own pattern into the consumer's name and break the
      # check. Splitting the literal across "++" keeps the contiguous token text
      # out of the file (in this comment too) so init cannot match it, while
      # Nickel still evaluates the element back to the full token. Do not
      # "simplify" it to a plain string. (The PLACEHOLDER token and
      # "rsr-template-repo" are not init tokens, so they survive as-is.)
      reject_patterns = ["{{PLACEHOLDER}}", "{{" ++ "PROJECT}}", "rsr-template-repo"],
    },

    coverage_updated = {
      description = "The deed's coverage record should be updated within 30 days",
      severity = "info",
      # The repo deed (<repo>_chora.deed, a glob: its stem is the repo slug).
      # The date is the clause's own :last-updated, not the file's mtime: the
      # deed changes for many reasons, so its mtime says nothing about coverage.
      file_glob = "*_chora.deed",
      deed_clause = "bot-directives/coverage/metadata",
      date_key = "last-updated",
      staleness_days = 30,
    },
  },
}
in methodology_guard
