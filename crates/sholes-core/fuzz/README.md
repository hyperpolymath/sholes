<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) -->

# cargo-fuzz harness

This directory is an optional `cargo fuzz` harness, kept outside the default
workspace so the production crates remain dependency-free. Run it with:

```sh
cargo fuzz run canonicalize -- -max_total_time=60
```

The target checks idempotence, binary identity, and the Windows projection
against the reusable streaming implementation.
