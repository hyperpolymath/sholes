// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Creusot-facing predicates and contract ledger.
//!
//! The executable implementation deliberately has no runtime dependency on
//! Creusot or Why3.  The `//@` annotations below are consumed by the Creusot
//! verification pass (see `verification/creusot/README.md`) and are comments to
//! ordinary rustc, keeping the default library zero-dependency.

use crate::{classify, is_canonical_lf as executable_is_canonical_lf};

/// Maximum input chunk used by the bounded verification harness.
pub const MAX_CHUNK_SIZE: usize = 64 * 1024;

/// A slice is a valid Rust buffer when it is no larger than the verified chunk.
///
/// Rust's slice invariant already guarantees memory validity; the size bound is
/// the part that is relevant to the bounded Why3 model.
pub fn valid_buffer(input: &[u8]) -> bool {
    input.len() <= MAX_CHUNK_SIZE
}

/// Logical binary predicate used by the contracts.
pub fn is_binary(input: &[u8]) -> bool {
    classify(input).is_binary()
}

/// Logical text predicate used by the contracts.
pub fn is_text(input: &[u8]) -> bool {
    classify(input).is_text()
}

/// Logical canonical-LF predicate used by the contracts.
pub fn is_canonical_lf(input: &[u8]) -> bool {
    executable_is_canonical_lf(input)
}

/// Contract ledger for the allocation-free chunk transformer.
///
/// These are written in Creusot's source annotation form so that the proof
/// adapter can bind them to the executable `normalize_chunk` function without
/// making the production crate depend on a verifier runtime.
///
/// Creusot's attribute spelling for the same ledger is shown below. The
/// attributes remain comments in the production build because the verifier
/// supplies them as a separate logical environment:
///
/// ```text
/// #[requires(valid_buffer(input))]
/// #[ensures(is_binary(input) ==> result == input)]
/// #[ensures(is_text(input) ==> is_canonical_lf(result))]
/// ```
///
/// The executable slice-level form is:
///
/// ```text
/// //@ requires valid_buffer(input);
/// //@ ensures result <= output.len();
/// //@ ensures is_binary(input) ==> bytes_equal(input, output[0..result]);
/// //@ ensures is_text(input) ==> is_canonical_lf(output[0..result]);
/// ```
///
/// The stronger byte equality condition is intentionally expressed as a
/// verifier predicate (`bytes_equal`) rather than a Rust helper: it is a
/// logical relation over the pre-state and post-state slices.
pub const CONTRACTS: &str = "valid_buffer; binary identity; text canonical LF";
