<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->
<!-- Authoritative source: docs/practice/AI-CONVENTIONS.adoc -->

# Copilot Instructions

## Before Writing Code

- Read the repo deed (`*_chora.deed` in the repo root) for canonical file locations
  (its `(ply ...)` clauses carry the canonical-locations tables).
- No `.a2ml` file may exist anywhere: state and metadata are clauses of the repo deed.

## License

- SPDX: `MPL-2.0` on all new files.
- Never use AGPL-3.0.
- Copyright: `Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>`

## Code Style

- Use descriptive variable names.
- Annotate and document all files.
- Add SPDX header to every source file.
- Use `just` for build/test/lint commands.

## Banned Patterns

- Idris2: no `believe_me`, no `assert_total`
- Haskell: no `unsafeCoerce`, no `unsafePerformIO`
- OCaml: no `Obj.magic`
- Coq: no `Admitted`
- Lean: no `sorry`
- Rust: no `transmute` unless FFI with `// SAFETY:` comment

## JavaScript / TypeScript runtimes

Ordered preference (`standards/3-practice/LANGUAGE-POLICY.adoc` §1) — reach for the first
that can do the job:

1. **Bun** — default for all new work. Runs compiled ESM/JS directly, no bundler
   step. Uses an npm-compatible `package.json` plus `bun.lock`; both are
   expected, not anti-patterns.
2. **Deno** — permitted (tier 2). Deno 2 reads the same `package.json` and runs
   its scripts with `deno task`.
3. **pnpm** — tier 3.
4. **npm** — last resort. Permitted, never preferred; it keeps no lock
   (`package-lock.json` stays refused).

**One manifest, every runtime** (owner ruling 2026-10-14, `LANGUAGE-POLICY.adoc`
§1.3–§1.4). `package.json` is the only manifest and carries every runtime's lock:
`bun.lock`, `deno.lock` and `pnpm-lock.yaml`. `js-runtimes regen` is the only
writer; run it after every `bun add`. Governance checks each runtime against its
lock. The ruling supersedes the 2026-08-26 one that removed Deno.

**TypeScript is not the language for new application code — AffineScript is.**
`LANGUAGE-POLICY.adoc` §1.2, ruled 2026-08-25, separates two questions the older
text ran together: *runtime* is Bun (where `.ts` runs at all, Bun runs it), while
the *language* target is AffineScript. TypeScript is permitted only where
AffineScript cannot reach — the same narrow, transitional carve-out JavaScript
holds for MCP protocol glue and runtime APIs. ReScript remains banned; its
migration destination is AffineScript.

## Banned Languages

- No Go (use Rust)
- No Python (use Julia or Rust)
- No Nix (use Guix)
- No ReScript (`LANGUAGE-POLICY.adoc` §3) — migrate to AffineScript

## Containers

- Use Podman, never Docker.
- Name the file `Containerfile`, never `Dockerfile`.
- Base image: `cgr.dev/chainguard/wolfi-base:latest`.

## ABI/FFI

- ABI definitions in Idris2 (`src/interface/abi/`).
- FFI implementations in Zig (`src/interface/ffi/`).
- Generated C headers in `src/interface/generated/`.

## State Files

No `.a2ml` file may exist anywhere: the format is retired. State, metadata,
`(neurosym)` and `(playbook)` are clauses of the repo deed (`*_chora.deed`);
the journal is `docs/status/ROADMAP.adoc`. Never recreate them as separate files.
