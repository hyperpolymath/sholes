<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) -->

# SHOLES

SHOLES is a formally specified, dependency-free line-ending canonicalization
layer for content-addressed storage. It treats LF, CRLF, and lone CR text
spellings as one quotient class while preserving binary and malformed UTF-8
streams byte-for-byte.

The repository uses AsciiDoc as its canonical estate documentation format;
[`README.adoc`](README.adoc) is the complete project README. This Markdown
entry point exists for tooling and points to the implementation map:

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — short architecture and invariants;
- [`docs/ARCHITECTURE.adoc`](docs/ARCHITECTURE.adoc) — detailed design;
- [`proofs/`](proofs/) — Agda source plus Lean 4 and Coq/Rocq transcriptions;
- [`crates/sholes-core/`](crates/sholes-core/) — allocation-free streaming core;
- [`crates/sholes-cli/`](crates/sholes-cli/) — clean, smudge, audit, and Git
  filter-process CLI.

## Quick start

```sh
cargo test --workspace
printf 'one\r\ntwo\r\n' | cargo run -p sholes-cli -- clean
cargo run -p sholes-cli -- audit .
```

`sholes clean` emits canonical LF storage. `sholes smudge --target windows`
emits CRLF for a Windows working tree. `sholes filter-process` speaks Git's
long-running pkt-line protocol v2. The default Rust workspace has no external
crate dependencies.

The proof assistants and Creusot are optional development toolchains. Their
absence must not be confused with a proof result; see the manifests and the
verification instructions in [`ARCHITECTURE.md`](ARCHITECTURE.md).
