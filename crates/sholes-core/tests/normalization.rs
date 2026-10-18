// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

use sholes_core::{
    audit, canonicalize, canonicalize_to_vec, classify, project_to_vec, Classification, CodecDirection,
    Encoding, StreamingCodec, TargetEnvironment, CanonicalCodec,
};

#[test]
fn canonicalizes_all_line_terminators() {
    let input = b"a\r\nb\nc\rd";
    assert_eq!(canonicalize_to_vec(input).unwrap(), b"a\nb\nc\nd");
}

#[test]
fn canonicalization_is_idempotent() {
    let first = canonicalize_to_vec(b"a\r\nb\rc\n").unwrap();
    let second = canonicalize_to_vec(&first).unwrap();
    assert_eq!(first, second);
}

#[test]
fn binary_and_invalid_utf8_are_exactly_preserved() {
    let binary = b"header\r\n\0\r\n";
    assert_eq!(classify(binary), Classification::Binary);
    assert_eq!(canonicalize_to_vec(binary).unwrap(), binary);

    let invalid = [0xff, b'\r', 0xfe];
    assert_eq!(classify(&invalid), Classification::Binary);
    assert_eq!(canonicalize_to_vec(&invalid).unwrap(), invalid);
}

#[test]
fn windows_projection_does_not_double_cr() {
    let canonical = b"a\nb\n";
    assert_eq!(
        project_to_vec(canonical, TargetEnvironment::Windows).unwrap(),
        b"a\r\nb\r\n"
    );
    assert_eq!(
        project_to_vec(b"a\r\nb\r\n", TargetEnvironment::Windows).unwrap(),
        b"a\r\nb\r\n"
    );
}

#[test]
fn a_carriage_return_split_at_a_chunk_boundary_is_lossless() {
    let mut codec = StreamingCodec::new(
        Classification::Text(Encoding::Utf8),
        CodecDirection::Canonical,
    );
    let mut output = [0; 32];
    let first = codec.push(b"left\r", &mut output);
    assert_eq!(first.consumed, 5);
    let second = codec.push(b"\nright", &mut output[first.produced..]);
    let tail = codec.finish(&mut output[first.produced + second.produced..]);
    assert_eq!(&output[..first.produced + second.produced + tail.produced], b"left\nright");
}

#[test]
fn small_output_buffers_support_backpressure() {
    let mut codec = StreamingCodec::new(
        Classification::Text(Encoding::Utf8),
        CodecDirection::Canonical,
    );
    let mut output = [0; 8];
    let mut input = b"a\r\nb\n";
    let mut written = 0;
    while !input.is_empty() {
        let result = codec.push(input, &mut output[written..written + 1]);
        written += result.produced;
        input = &input[result.consumed..];
        if result.consumed == 0 && result.produced == 0 {
            panic!("codec made no progress");
        }
    }
    loop {
        let result = codec.finish(&mut output[written..]);
        written += result.produced;
        if codec.is_finished() {
            break;
        }
        assert!(result.produced > 0);
    }
    assert_eq!(&output[..written], b"a\nb\n");
}

#[test]
fn audit_counts_noncanonical_text() {
    let report = audit(b"a\r\nb\rc\n");
    assert_eq!(report.crlf, 1);
    assert_eq!(report.lone_cr, 1);
    assert!(!report.canonical_lf);
}

#[test]
fn empty_text_is_utf8_and_canonical() {
    assert_eq!(classify(b""), Classification::Text(Encoding::Utf8));
    let mut output = [0; 1];
    assert_eq!(canonicalize(b"", &mut output).unwrap(), 0);
}
