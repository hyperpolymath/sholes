# Requirement traceability

| Mission requirement | Implementation/proof artifact |
| --- | --- |
| `Byte = Fin 256`, `Stream = List Byte` | `proofs/agda/Sholes/Core.agda`, `proofs/lean/Sholes/Core.lean`, `proofs/coq/Sholes_Core.v` |
| Quotient projection and idempotence | `proofs/*/Sholes*` `idempotence` theorem; `crates/sholes-core/src/normalize.rs` |
| Binary non-interference | classifier modules, `binary_preservation`, Rust tests |
| Cryptographic coherence | parametric `cryptographic_coherence` theorem; callers hash canonical bytes |
| POSIX/Windows lens | `proofs/agda/Sholes/Lens.agda`, Coq `get`/`put`, `TargetEnvironment` |
| Streaming implementation | `crates/sholes-core/src/normalize.rs` |
| FUSE/filesystem projection boundary | `crates/sholes-core/src/fuse.rs`, `src/view.rs` |
| Creusot contract surface | `crates/sholes-core/src/contracts.rs`, `verification/creusot/README.md` |
| Git filter protocol v2 | `crates/sholes-cli/src/packet_line.rs`, `src/main.rs` |
| Audit and differential testing | `crates/sholes-cli`, `crates/sholes-core/tests`, `verification/fuzzing` |
