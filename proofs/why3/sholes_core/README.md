# Why3 / Creusot boundary

The runtime crate is intentionally dependency-free. Creusot consumes the
contract ledger in `crates/sholes-core/src/contracts.rs` and translates the
allocation-free state machine in `src/normalize.rs` into Why3 verification
conditions.

The model obligations are:

1. every emitted byte is either copied or a canonical line-ending byte;
2. binary classification implies byte-for-byte identity;
3. a pending CR is emitted exactly once, including at end-of-stream;
4. a Windows LF projection emits exactly CRLF and never CRCRLF;
5. progress is bounded by input/output slice lengths.

A local verification run, when the Creusot toolchain is installed, should be
performed from the workspace root with the project-specific Creusot command
provided by that toolchain. Generated Why3 sessions and `.vo`/`.why` caches are
build artifacts and must not be committed.
