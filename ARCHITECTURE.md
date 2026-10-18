<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) -->

# SHOLES architecture

## Boundary

Git and other content-addressed stores hash raw bytes. SHOLES places a
canonicalization boundary between platform representations and storage:

```text
working tree -- clean --> canonical LF blob -- smudge --> POSIX LF / Windows CRLF
```

The canonical projection is total on byte slices:

```text
canon(CRLF) = LF
canon(CR)   = LF
canon(LF)   = LF
canon(binary) = binary
```

A bounded classifier scans the first 8192 bytes for NUL and validates complete
inputs as UTF-8. Invalid UTF-8 is fail-safe binary. The formal finite-stream
model uses `Byte = Fin 256` and `Stream = List Byte`; the runtime refinement is
explained in `proofs/README.md`.

## Components

- `crates/sholes-core`: `StreamingCodec` implements `CanonicalCodec` with no
  heap allocation. It carries only a pending CR and at most two pending output
  bytes, so CRLF pairs split across ring-buffer chunks are handled correctly.
  `ProjectedFile` is a FUSE/9P/WebDAV-neutral read callback adapter for random
  projected reads; an OS adapter can supply the syscall layer without moving
  platform policy into the proof core.
- `crates/sholes-cli`: a std-only CLI. `clean` and `smudge` are one-shot
  adapters; `filter-process` implements Git filter protocol v2 packet framing;
  `audit` recursively reports text/binary and line-ending status.
- `proofs/agda/Sholes`: constructive quotient, coherence, and lens artifacts.
  Lean 4 and Coq/Rocq files are structural transcriptions, not generated
  screenshots or unchecked pseudocode.
- `crates/sholes-core/src/contracts.rs`: Creusot/Why3 contract ledger. It is
  comments to ordinary `rustc`, keeping the default runtime dependency-free.

## Laws

For text streams:

1. **Idempotence:** `canon(canon(s)) = canon(s)`.
2. **Equivalence invariance:** `s₁ ~LE s₂` implies equal canonical bytes.
3. **Hash coherence:** any `H` gives `H(canon(s₁)) = H(canon(s₂))` for an
   equivalent pair. Collision resistance is not claimed by this theorem.
4. **Binary non-interference:** classification as binary implies exact identity.
5. **Lens round trip:** a presentation obtained with `get(e, s)` returns to
   the same canonical storage representative through `put(e, ...)`.

The Rust tests additionally cover chunk-boundary invariance, output
backpressure, invalid UTF-8, and Windows double-CR avoidance.

## Git protocol

`filter-process` performs the v2 handshake, advertises `clean` and `smudge`,
reads command metadata followed by a flush-delimited binary payload, and
returns a status section followed by transformed pkt-lines. Payload bytes are
not interpreted as text by the protocol layer.

## Verification commands

```sh
cargo test --workspace
agda --safe proofs/agda/Sholes/Core.agda
coqc proofs/coq/Sholes_Core.v
lean proofs/lean/Sholes/Core.lean
```

Creusot/Why3 verification is a separate optional pass over the contract ledger;
see `verification/creusot/README.md`. Generated prover caches are not source
proofs and are excluded from Git.
