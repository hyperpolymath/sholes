<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) -->

# sholes-core

`sholes-core` is the dependency-free runtime projection used by the CLI and
Git filter process.

## Guarantees

* `clean` maps UTF-8 text with `LF`, `CRLF`, or lone `CR` terminators to `LF`.
* `smudge` maps canonical text to POSIX `LF` or Windows `CRLF`.
* A stream classified as binary is copied byte-for-byte.
* Invalid UTF-8 is treated as binary and copied byte-for-byte.
* `StreamingCodec` allocates no memory. It keeps only a pending carriage return
  and at most two pending output bytes, so chunk boundaries cannot change the
  result.

The complete-slice helpers allocate their result only because their API returns
an owned `Vec`; the transformation itself is shared with the streaming path.
Production integrations should drive `CanonicalCodec::push` and `finish` over
reusable buffers. `ProjectedFile` provides an allocation-free random-read
boundary for a FUSE, 9P, or WebDAV adapter; the operating-system mount
protocol remains an integration concern.
