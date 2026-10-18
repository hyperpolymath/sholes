// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Template FFI build (Zig 0.15.2+).
//
//   zig build test    runs the unit tests in src/main.zig and test/integration_test.zig
//
// src/main.zig carries template tokens until `just repo-init` fills them, so the
// test step compiles only in an instantiated repository.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run the FFI unit and integration tests");
    for ([_][]const u8{ "src/main.zig", "test/integration_test.zig" }) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .link_libc = true, // main.zig allocates with std.heap.c_allocator
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
