// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! FUSE/9P-neutral adapter names.
//!
//! No mount syscall or platform-specific FUSE crate belongs in the core. An
//! adapter can nevertheless depend on this module for the stable projected
//! read callback surface.

pub use crate::view::{direction_for_target, ProjectedFile};
