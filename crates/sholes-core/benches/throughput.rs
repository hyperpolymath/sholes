// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! A deliberately dependency-free benchmark harness can call the same public
//! APIs from an external runner.  Criterion is intentionally not a runtime
//! dependency of sholes-core.

fn main() {
    println!("Use a release build and a reusable StreamingCodec for throughput measurements.");
}
