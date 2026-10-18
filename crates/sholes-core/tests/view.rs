// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

use sholes_core::{ProjectedFile, TargetEnvironment};

#[test]
fn projected_view_supports_random_reads_without_allocating_in_the_core() {
    let view = ProjectedFile::new(b"left\nright\n", TargetEnvironment::Windows);
    assert_eq!(view.len(), 13);
    let mut output = [0; 6];
    let count = view.read_at(5, &mut output).unwrap();
    assert_eq!(count, 6);
    assert_eq!(&output, b"\nright");
}

#[test]
fn projected_view_preserves_binary_offsets() {
    let blob = b"a\r\n\0\r\nb";
    let view = ProjectedFile::new(blob, TargetEnvironment::Windows);
    let mut output = [0; 32];
    let count = view.read_at(0, &mut output).unwrap();
    assert_eq!(&output[..count], blob);
}
