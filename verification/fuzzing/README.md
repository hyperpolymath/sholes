# Differential and property-based testing

The core crate has no third-party runtime dependencies, so its deterministic
properties are ordinary Rust tests. A downstream workspace may add `proptest`
or `cargo-fuzz` harnesses that generate:

* arbitrary UTF-8 text with LF, CRLF, and lone-CR permutations;
* arbitrary NUL-bearing and malformed byte streams;
* chunks that split a CRLF pair at every possible boundary;
* canonical blobs projected to POSIX and Windows presentations.

The required properties are:

```text
canon(canon(s)) = canon(s)
binary(s)       => canon(s) = s
canon(chunks(s)) = canon(s)
project(posix, canon(s)) = canon(s)
project(windows, canon(s)) has CRLF-only line endings
```

If GNU `dos2unix` or `unix2dos` is installed, the harness can compare text
outputs. A difference is reported rather than used to weaken the SHOLES
classifier, especially for malformed UTF-8 and binary data.
