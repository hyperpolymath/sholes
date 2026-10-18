// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! The small, allocation-free core of sholes.
//!
//! The storage representation is canonical UTF-8 text with `LF` terminators.
//! Binary or invalid UTF-8 input is copied byte-for-byte.  [`StreamingCodec`]
//! never allocates and can be driven by a pipe, a ring buffer, or a Git
//! packet-line reader.  The convenience functions allocate only in the caller
//! (the core transformation itself still uses the streaming codec).

#![forbid(unsafe_code)]
#![deny(missing_debug_implementations)]
#![warn(missing_docs)]

mod audit;
mod classifier;
mod normalize;
mod view;
pub mod contracts;
pub mod fuse;

pub use audit::{audit, AuditReport};
pub use classifier::{classify, classify_header, is_binary, Classification, Encoding, CLASSIFICATION_WINDOW};
pub use normalize::{
    canonical_len, canonicalize, canonicalize_to_vec, is_canonical_lf, is_text,
    normalize_chunk, project, projected_len, project_to_vec, CodecDirection, CodecError,
    CodecResult, CanonicalCodec, StreamingCodec,
};
pub use view::ProjectedFile;

/// The byte used by Unix text files for a line feed.
pub const LF: u8 = 0x0a;
/// The byte used by classic Mac and DOS text files for a carriage return.
pub const CR: u8 = 0x0d;

/// A target platform for a smudged working-tree representation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TargetEnvironment {
    /// LF line endings (POSIX, Linux, macOS, BSD, and canonical storage).
    Posix,
    /// CRLF line endings (Windows working trees).
    Windows,
}

impl TargetEnvironment {
    /// Select the host's conventional working-tree line ending.
    pub const fn host() -> Self {
        if cfg!(windows) {
            Self::Windows
        } else {
            Self::Posix
        }
    }

    /// Select the codec direction corresponding to this environment.
    pub const fn direction(self) -> CodecDirection {
        match self {
            Self::Posix => CodecDirection::Posix,
            Self::Windows => CodecDirection::Windows,
        }
    }
}

/// Return the environment selected by `SHOLES_TARGET`, falling back to host.
///
/// This is deliberately a tiny parser so the core remains independent of the
/// CLI.  Unknown values use the safe POSIX default rather than silently
/// emitting CRLF.
pub fn target_from_env(value: Option<&str>) -> TargetEnvironment {
    match value {
        Some(value) if value.eq_ignore_ascii_case("windows") || value.eq_ignore_ascii_case("crlf") => {
            TargetEnvironment::Windows
        }
        Some(value) if value.eq_ignore_ascii_case("posix") || value.eq_ignore_ascii_case("lf") => {
            TargetEnvironment::Posix
        }
        Some(_) => TargetEnvironment::Posix,
        None => TargetEnvironment::host(),
    }
}
