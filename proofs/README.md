<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) -->

# Formal proof artifacts

This directory is the publication-facing proof tree for SHOLES. The executable
Rust implementation remains in `crates/sholes-core`; these files define the
mathematical model independently of Rust.

| Prover | Entry points | Role |
| --- | --- | --- |
| Agda | `agda/Sholes/Core.agda`, `Equivalence.agda`, `Lens.agda` | Constructive source model and quotient/lens laws |
| Lean 4 | `lean/Sholes/Core.lean` | Structural cross-prover transcription |
| Coq/Rocq | `coq/Sholes_Core.v` | Structural cross-prover transcription |

The formal model uses `Byte = Fin 256` and `Stream = List Byte`. The classifier
has a binary branch for NUL-bearing streams and a UTF-8 text branch. The
operational Rust classifier is deliberately more conservative: malformed
UTF-8 is also binary, and NUL inspection is bounded to the first 8192 bytes.
That refinement is documented rather than silently conflated with the total-list
model.

The cryptographic theorem is parametric in `H`; it proves coherence for any
function over canonical bytes, not collision resistance of a particular hash.
The lens proof uses POSIX LF and Windows CRLF as presentations of one canonical
storage stream.

No generated compiler caches belong in this directory. Use the prover commands
in `docs/ARCHITECTURE.md` when Agda, Lean, or Coq/Rocq are installed.
