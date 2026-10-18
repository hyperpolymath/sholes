// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Allocation-free streaming transducers.

use crate::{classify, Classification, CR, LF};

/// A direction for a streaming codec.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodecDirection {
    /// Emit canonical LF text (the Git clean direction).
    Canonical,
    /// Emit canonical LF text for a POSIX working tree.
    Posix,
    /// Emit CRLF text for a Windows working tree.
    Windows,
}

/// Progress returned from every streaming operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CodecResult {
    /// Number of input bytes consumed.  A caller must retain the remainder.
    pub consumed: usize,
    /// Number of bytes written to the output buffer.
    pub produced: usize,
}

impl CodecResult {
    const fn new(consumed: usize, produced: usize) -> Self {
        Self { consumed, produced }
    }
}

/// Errors from all-at-once convenience functions.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodecError {
    /// The caller supplied an output slice shorter than the exact result.
    OutputTooSmall { required: usize },
    /// A stream was used after `finish` completed.
    Finished,
}

/// The interface implemented by all reusable codecs.
pub trait CanonicalCodec {
    /// Consume as much input as possible without allocating.
    fn push(&mut self, input: &[u8], output: &mut [u8]) -> CodecResult;
    /// Flush a pending CR or a partial Windows CRLF.
    fn finish(&mut self, output: &mut [u8]) -> CodecResult;
}

/// A reusable, allocation-free line-ending codec.
///
/// The only state is a pending CR and at most two pending output bytes.  This
/// makes a CR split across two ring-buffer chunks behave exactly like a CR in
/// one chunk.  The caller owns the buffers and can retry whenever
/// `consumed < input.len()` or `finish` has not drained its output.
#[derive(Clone, Debug)]
pub struct StreamingCodec {
    classification: Classification,
    direction: CodecDirection,
    pending_cr: bool,
    pending: [u8; 2],
    pending_len: usize,
    pending_pos: usize,
    finished: bool,
}

impl StreamingCodec {
    /// Construct a codec for a previously selected classification.
    pub const fn new(classification: Classification, direction: CodecDirection) -> Self {
        Self {
            classification,
            direction,
            pending_cr: false,
            pending: [0; 2],
            pending_len: 0,
            pending_pos: 0,
            finished: false,
        }
    }

    /// Construct a codec by classifying a complete input slice.
    pub fn for_input(input: &[u8], direction: CodecDirection) -> Self {
        Self::new(classify(input), direction)
    }

    /// The classification selected at construction time.
    pub const fn classification(&self) -> Classification {
        self.classification
    }

    /// Whether all pending output has been flushed by `finish`.
    pub const fn is_finished(&self) -> bool {
        self.finished
    }

    fn schedule_newline(&mut self) {
        if self.direction == CodecDirection::Windows {
            self.pending = [CR, LF];
            self.pending_len = 2;
        } else {
            self.pending = [LF, 0];
            self.pending_len = 1;
        }
        self.pending_pos = 0;
    }

    fn drain_pending(&mut self, output: &mut [u8], produced: &mut usize) -> bool {
        while self.pending_pos < self.pending_len && *produced < output.len() {
            output[*produced] = self.pending[self.pending_pos];
            *produced += 1;
            self.pending_pos += 1;
        }
        if self.pending_pos == self.pending_len {
            self.pending_len = 0;
            self.pending_pos = 0;
            true
        } else {
            false
        }
    }
}

impl CanonicalCodec for StreamingCodec {
    fn push(&mut self, input: &[u8], output: &mut [u8]) -> CodecResult {
        if self.finished {
            return CodecResult::new(0, 0);
        }

        if self.classification.is_binary() {
            let count = input.len().min(output.len());
            output[..count].copy_from_slice(&input[..count]);
            return CodecResult::new(count, count);
        }

        let mut consumed = 0;
        let mut produced = 0;
        while consumed < input.len() {
            if !self.drain_pending(output, &mut produced) {
                break;
            }

            if self.pending_cr {
                // CRLF and a lone CR are the same semantic line terminator.
                if input[consumed] == LF {
                    consumed += 1;
                }
                self.pending_cr = false;
                self.schedule_newline();
                continue;
            }

            let byte = input[consumed];
            if byte == CR {
                consumed += 1;
                self.pending_cr = true;
            } else if byte == LF && self.direction == CodecDirection::Windows {
                consumed += 1;
                self.schedule_newline();
            } else if produced < output.len() {
                output[produced] = byte;
                produced += 1;
                consumed += 1;
            } else {
                break;
            }
        }

        CodecResult::new(consumed, produced)
    }

    fn finish(&mut self, output: &mut [u8]) -> CodecResult {
        if self.finished {
            return CodecResult::new(0, 0);
        }
        let mut produced = 0;
        if self.pending_cr && self.pending_len == 0 {
            self.pending_cr = false;
            self.schedule_newline();
        }
        if self.drain_pending(output, &mut produced) && !self.pending_cr {
            self.finished = true;
        }
        CodecResult::new(0, produced)
    }
}

/// Count bytes emitted by the canonical LF projection.
pub fn canonical_len(input: &[u8]) -> usize {
    if classify(input).is_binary() {
        return input.len();
    }
    let mut output = 0;
    let mut index = 0;
    while index < input.len() {
        if input[index] == CR {
            if input.get(index + 1) == Some(&LF) {
                index += 1;
            }
        }
        output += 1;
        index += 1;
    }
    output
}

fn newline_count(input: &[u8]) -> usize {
    let mut count = 0;
    let mut index = 0;
    while index < input.len() {
        if input[index] == LF {
            count += 1;
        } else if input[index] == CR {
            count += 1;
            if input.get(index + 1) == Some(&LF) {
                index += 1;
            }
        }
        index += 1;
    }
    count
}

fn required_len(input: &[u8], direction: CodecDirection) -> usize {
    if classify(input).is_binary() {
        input.len()
    } else {
        match direction {
            CodecDirection::Canonical | CodecDirection::Posix => canonical_len(input),
            CodecDirection::Windows => canonical_len(input) + newline_count(input),
        }
    }
}

fn transform(input: &[u8], output: &mut [u8], direction: CodecDirection) -> Result<usize, CodecError> {
    let required = required_len(input, direction);
    if output.len() < required {
        return Err(CodecError::OutputTooSmall { required });
    }
    let mut codec = StreamingCodec::for_input(input, direction);
    let first = codec.push(input, output);
    if first.consumed != input.len() {
        return Err(CodecError::OutputTooSmall { required });
    }
    let tail = codec.finish(&mut output[first.produced..]);
    if !codec.is_finished() {
        return Err(CodecError::OutputTooSmall { required });
    }
    Ok(first.produced + tail.produced)
}

/// Normalize one complete input slice into canonical LF storage.
pub fn canonicalize(input: &[u8], output: &mut [u8]) -> Result<usize, CodecError> {
    transform(input, output, CodecDirection::Canonical)
}

/// Project a complete canonical/blob slice into a target environment.
pub fn project(input: &[u8], target: crate::TargetEnvironment, output: &mut [u8]) -> Result<usize, CodecError> {
    transform(input, output, target.direction())
}

/// Return the exact length of a projected representation.
pub fn projected_len(input: &[u8], target: crate::TargetEnvironment) -> usize {
    required_len(input, target.direction())
}

/// Normalize a bounded chunk.  This is the entry point named by the Creusot
/// contract ledger; callers needing cross-chunk semantics should retain the
/// [`StreamingCodec`] state instead.
pub fn normalize_chunk(input: &[u8], output: &mut [u8]) -> Result<usize, CodecError> {
    canonicalize(input, output)
}

/// Allocate a canonical result for command-line and test convenience.
pub fn canonicalize_to_vec(input: &[u8]) -> Result<Vec<u8>, CodecError> {
    let mut output = vec![0; canonical_len(input)];
    let size = canonicalize(input, &mut output)?;
    output.truncate(size);
    Ok(output)
}

/// Allocate a target-environment result for command-line convenience.
pub fn project_to_vec(input: &[u8], target: crate::TargetEnvironment) -> Result<Vec<u8>, CodecError> {
    let mut output = vec![0; required_len(input, target.direction())];
    let size = project(input, target, &mut output)?;
    output.truncate(size);
    Ok(output)
}

/// Whether text is already in canonical LF form. Binary input is considered
/// canonical because the binary non-interference law requires identity.
pub fn is_canonical_lf(input: &[u8]) -> bool {
    if classify(input).is_binary() {
        return true;
    }
    !input.contains(&CR)
}
