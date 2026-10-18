// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

use sholes_core::{canonicalize_to_vec, classify, CodecDirection, CanonicalCodec, StreamingCodec, TargetEnvironment};

fn chunked(input: &[u8], direction: CodecDirection) -> Vec<u8> {
    let mut codec = StreamingCodec::new(classify(input), direction);
    let mut result = Vec::new();
    for chunk in input.chunks(7) {
        let mut output = [0; 32];
        let mut remaining = chunk;
        while !remaining.is_empty() {
            let progress = codec.push(remaining, &mut output);
            result.extend_from_slice(&output[..progress.produced]);
            remaining = &remaining[progress.consumed..];
            assert!(progress.consumed != 0 || progress.produced != 0);
        }
    }
    loop {
        let mut output = [0; 32];
        let progress = codec.finish(&mut output);
        result.extend_from_slice(&output[..progress.produced]);
        if codec.is_finished() {
            break;
        }
        assert!(progress.produced > 0);
    }
    result
}

#[test]
fn chunked_codec_matches_complete_projection_for_many_inputs() {
    let mut seed = 0x5eed_u64;
    for length in 0..512 {
        let mut input = Vec::with_capacity(length);
        for _ in 0..length {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            input.push(match seed % 11 {
                0 => b'\r',
                1 => b'\n',
                2 => 0,
                3 => 0xff,
                _ => b'a' + (seed as u8 % 26),
            });
        }
        let expected = if matches!(sholes_core::classify(&input), sholes_core::Classification::Binary) {
            input.clone()
        } else {
            canonicalize_to_vec(&input).unwrap()
        };
        assert_eq!(chunked(&input, CodecDirection::Canonical), expected);
        let windows = sholes_core::project_to_vec(&input, TargetEnvironment::Windows).unwrap();
        assert_eq!(chunked(&input, CodecDirection::Windows), windows);
    }
}
