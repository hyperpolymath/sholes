# Verification tests

Runtime correspondence tests live in `crates/sholes-core/tests/` and exercise
idempotence, binary non-interference, chunk-boundary invariance, environment
projection, and audit counts. The CLI packet-line unit tests live beside the
Git protocol implementation.

The differential harness described in `verification/fuzzing/` uses the same
oracle as the formal model. External `dos2unix`/`unix2dos` binaries are
optional comparison tools, never trusted implementations: their output is
compared with the canonical Rust projection.
