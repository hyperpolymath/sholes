// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

#![no_main]

use libfuzzer_sys::fuzz_target;
use sholes_core::{canonicalize_to_vec, classify, project_to_vec, Classification, TargetEnvironment};

fuzz_target!(|input: Vec<u8>| {
    let canonical = canonicalize_to_vec(&input).expect("capacity is calculated exactly");
    let twice = canonicalize_to_vec(&canonical).expect("canonical output is valid input");
    assert_eq!(canonical, twice);
    if matches!(classify(&input), Classification::Binary) {
        assert_eq!(canonical, input);
    }
    let windows = project_to_vec(&canonical, TargetEnvironment::Windows)
        .expect("capacity is calculated exactly");
    assert!(windows.windows(2).all(|pair| pair != [b'\n', b'\r']));
});
