// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Read-only line-ending audit information.

use crate::{classify, Classification, CR, LF};

/// Counts and classification produced by [`audit`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AuditReport {
    /// The classifier decision used by the codec.
    pub classification: Classification,
    /// Number of input bytes.
    pub bytes: usize,
    /// Number of CRLF pairs.
    pub crlf: usize,
    /// Number of carriage returns not followed by LF.
    pub lone_cr: usize,
    /// Number of LF bytes, including LFs in CRLF pairs.
    pub lf: usize,
    /// True for binary input, or text containing no CR bytes.
    pub canonical_lf: bool,
}

impl AuditReport {
    /// Whether the report represents binary content.
    pub const fn is_binary(self) -> bool {
        self.classification.is_binary()
    }

    /// Whether a text stream needs no line-ending conversion.
    pub const fn is_canonical(self) -> bool {
        self.canonical_lf
    }
}

/// Inspect bytes without changing them.
pub fn audit(input: &[u8]) -> AuditReport {
    let classification = classify(input);
    if classification.is_binary() {
        return AuditReport {
            classification,
            bytes: input.len(),
            crlf: 0,
            lone_cr: 0,
            lf: 0,
            canonical_lf: true,
        };
    }

    let mut crlf = 0;
    let mut lone_cr = 0;
    let mut lf = 0;
    let mut index = 0;
    while index < input.len() {
        match input[index] {
            CR => {
                if input.get(index + 1) == Some(&LF) {
                    crlf += 1;
                } else {
                    lone_cr += 1;
                }
            }
            LF => lf += 1,
            _ => {}
        }
        index += 1;
    }

    AuditReport {
        classification,
        bytes: input.len(),
        crlf,
        lone_cr,
        lf,
        canonical_lf: lone_cr == 0 && crlf == 0,
    }
}
