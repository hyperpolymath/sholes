// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Conservative, deterministic input classification.

use core::str;

/// The maximum prefix used by the streaming/header classifier.
///
/// A NUL byte is a strong binary signal.  UTF-8 is checked for the complete
/// slice by [`classify`]; [`classify_header`] is provided for callers that
/// deliberately make a bounded decision before consuming a stream.
pub const CLASSIFICATION_WINDOW: usize = 8 * 1024;

/// The text encoding understood by the canonicalizer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Encoding {
    /// Unicode UTF-8, including ASCII (which is valid UTF-8).
    Utf8,
}

/// The result of the binary/text oracle.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Classification {
    /// Preserve every byte exactly; no line-ending rewrite is permitted.
    Binary,
    /// Text together with the encoding accepted by the implementation.
    Text(Encoding),
}

impl Classification {
    /// Whether this result selects the non-interference path.
    pub const fn is_binary(self) -> bool {
        matches!(self, Self::Binary)
    }

    /// Whether this result selects the text path.
    pub const fn is_text(self) -> bool {
        matches!(self, Self::Text(_))
    }
}

/// Inspect a bounded prefix for the two fail-safe binary signals.
///
/// This function does not allocate and never reads past `CLASSIFICATION_WINDOW`.
/// It is useful at a streaming boundary.  Callers processing a complete slice
/// should normally use [`classify`], which also validates the complete UTF-8
/// sequence so an invalid byte after the header cannot be rewritten.
pub fn classify_header(input: &[u8]) -> Classification {
    let header = &input[..input.len().min(CLASSIFICATION_WINDOW)];
    if header.contains(&0) || str::from_utf8(header).is_err() {
        Classification::Binary
    } else {
        Classification::Text(Encoding::Utf8)
    }
}

/// Classify a complete byte stream.
///
/// NUL detection is bounded to the first 8 KiB, while UTF-8 validation covers
/// the complete slice.  This combination makes the usual binary fast path
/// cheap without allowing malformed trailing input to be normalised.
pub fn classify(input: &[u8]) -> Classification {
    let header = &input[..input.len().min(CLASSIFICATION_WINDOW)];
    if header.contains(&0) || str::from_utf8(input).is_err() {
        Classification::Binary
    } else {
        Classification::Text(Encoding::Utf8)
    }
}

/// Shorthand for `classify(input).is_binary()`.
pub fn is_binary(input: &[u8]) -> bool {
    classify(input).is_binary()
}

/// Shorthand for `classify(input).is_text()`.
pub fn is_text(input: &[u8]) -> bool {
    classify(input).is_text()
}
