# Creusot verification boundary

SHOLES keeps the production crates free of runtime dependencies. The
Creusot-facing contract ledger is in `crates/sholes-core/src/contracts.rs` and
uses source annotations for `valid_buffer`, `is_binary`, `is_text`, and
`is_canonical_lf`.

The proof target is the `StreamingCodec` state machine. Why3/Coq discharge
memory-safety and functional obligations; the Agda/Lean/Coq files under
`proofs/` define the independent quotient model. This separation is
intentional: a proof assistant can validate a finite-list specification
without pretending that OS pipes, scheduling, or filesystem syscalls are part
of the same theorem.
