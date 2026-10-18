// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! A filesystem-adapter boundary for projected reads.
//!
//! This module deliberately does not depend on a FUSE crate. A FUSE, 9P, or
//! WebDAV adapter can implement its read callback by retaining `ProjectedFile`;
//! the projection and offset semantics stay in the verified core.

use crate::{classify, projected_len, CanonicalCodec, CodecDirection, CodecError, StreamingCodec, TargetEnvironment};

/// A read-only view of canonical blob bytes in one target environment.
///
/// `read_at` is allocation-free. It replays the small streaming state machine
/// from the beginning of the blob to honour the presented-file offset. An
/// adapter that needs high random-read throughput can cache checkpoints (the
/// cache is outside this core type and therefore outside its proof boundary).
#[derive(Clone, Copy, Debug)]
pub struct ProjectedFile<'a> {
    blob: &'a [u8],
    target: TargetEnvironment,
}

impl<'a> ProjectedFile<'a> {
    /// Borrow canonical/blob bytes as a target-environment view.
    pub const fn new(blob: &'a [u8], target: TargetEnvironment) -> Self {
        Self { blob, target }
    }

    /// Presented byte length.
    pub fn len(&self) -> usize {
        projected_len(self.blob, self.target)
    }

    /// Whether the view contains no bytes.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Read a presented range into a caller-owned buffer.
    ///
    /// Reading beyond EOF returns the available suffix, as a normal filesystem
    /// read callback does. The method never allocates.
    pub fn read_at(&self, offset: usize, output: &mut [u8]) -> Result<usize, CodecError> {
        if output.is_empty() || offset >= self.len() {
            return Ok(0);
        }

        let direction = self.target.direction();
        let mut codec = StreamingCodec::new(classify(self.blob), direction);
        let mut source_offset = 0;
        let mut presented_offset = 0;
        let wanted_end = offset.saturating_add(output.len()).min(self.len());
        let mut written = 0;
        let mut scratch = [0; 256];

        while source_offset < self.blob.len() && presented_offset < wanted_end {
            let source_end = (source_offset + 256).min(self.blob.len());
            let mut remaining = &self.blob[source_offset..source_end];
            while !remaining.is_empty() && presented_offset < wanted_end {
                let progress = codec.push(remaining, &mut scratch);
                copy_window(
                    &scratch[..progress.produced],
                    presented_offset,
                    offset,
                    wanted_end,
                    output,
                    &mut written,
                );
                source_offset += progress.consumed;
                remaining = &remaining[progress.consumed..];
                presented_offset += progress.produced;
                if progress.consumed == 0 && progress.produced == 0 {
                    break;
                }
            }
        }

        while presented_offset < wanted_end && !codec.is_finished() {
            let progress = codec.finish(&mut scratch);
            copy_window(
                &scratch[..progress.produced],
                presented_offset,
                offset,
                wanted_end,
                output,
                &mut written,
            );
            presented_offset += progress.produced;
            if progress.produced == 0 && !codec.is_finished() {
                return Err(CodecError::OutputTooSmall { required: self.len() });
            }
        }
        Ok(written)
    }
}

fn copy_window(
    produced: &[u8],
    logical_start: usize,
    wanted_start: usize,
    wanted_end: usize,
    output: &mut [u8],
    written: &mut usize,
) {
    let logical_end = logical_start + produced.len();
    let copy_start = logical_start.max(wanted_start);
    let copy_end = logical_end.min(wanted_end);
    if copy_start < copy_end {
        let source_start = copy_start - logical_start;
        let count = copy_end - copy_start;
        output[*written..*written + count].copy_from_slice(&produced[source_start..source_start + count]);
        *written += count;
    }
}

/// Name the codec mapping used by a filesystem adapter.
pub const fn direction_for_target(target: TargetEnvironment) -> CodecDirection {
    target.direction()
}
