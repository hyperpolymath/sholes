// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// SHOLES FFI Implementation
//
// This module implements the C-compatible FFI declared in src/abi/Foreign.idr
// All types and layouts must match the Idris2 ABI definitions.
//

const std = @import("std");

// Version information (keep in sync with project)
const VERSION = "0.1.0";
const BUILD_INFO = "SHOLES built with Zig " ++ @import("builtin").zig_version_string;

/// Thread-local error storage
threadlocal var last_error: ?[]const u8 = null;

/// Set the last error message
fn setError(msg: []const u8) void {
    last_error = msg;
}

/// Clear the last error
fn clearError() void {
    last_error = null;
}

/// Duplicate a byte slice as a NUL-terminated buffer across Zig 0.15/0.16/0.17
/// (`Allocator.dupeZ` was removed in Zig 0.17).
/// The caller owns the returned slice and must free it with `allocator`.
/// Propagates allocation failure.
fn dupeZ(allocator: std.mem.Allocator, bytes: []const u8) ![:0]u8 {
    const buf = try allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf[0..bytes.len], bytes);
    return buf;
}

//==============================================================================
// Core Types (must match src/abi/Types.idr)
//==============================================================================

/// Result codes (must match Idris2 Result type)
pub const Result = enum(c_int) {
    ok = 0,
    @"error" = 1,
    invalid_param = 2,
    out_of_memory = 3,
    null_pointer = 4,
};

/// Library handle. C sees only a pointer, so the fields stay private to Zig.
pub const Handle = struct {
    // Internal state hidden from C
    allocator: std.mem.Allocator,
    initialized: bool,
    // Add your fields here
};

//==============================================================================
// Library Lifecycle
//==============================================================================

/// Initialize the library
/// Returns a handle, or null on failure
export fn sholes_init() ?*Handle {
    const allocator = std.heap.c_allocator;

    const handle = allocator.create(Handle) catch {
        setError("Failed to allocate handle");
        return null;
    };

    // Initialize handle
    handle.* = .{
        .allocator = allocator,
        .initialized = true,
    };

    clearError();
    return handle;
}

/// Free the library handle
export fn sholes_free(handle: ?*Handle) void {
    const h = handle orelse return;
    const allocator = h.allocator;

    // Clean up resources
    h.initialized = false;

    allocator.destroy(h);
    clearError();
}

//==============================================================================
// Core Operations
//==============================================================================

/// Process data (example operation)
export fn sholes_process(handle: ?*Handle, input: u32) Result {
    const h = handle orelse {
        setError("Null handle");
        return .null_pointer;
    };

    if (!h.initialized) {
        setError("Handle not initialized");
        return .@"error";
    }

    // Example processing logic
    _ = input;

    clearError();
    return .ok;
}

//==============================================================================
// String Operations
//==============================================================================

/// Get a string result (example)
/// Return a NUL-terminated "Example result" owned by the caller; free it with
/// `sholes_free_string`. Return null and set the thread-local error for a
/// null or uninitialized handle, or allocation failure. Clear the error on success.
export fn sholes_get_string(handle: ?*Handle) ?[*:0]const u8 {
    const h = handle orelse {
        setError("Null handle");
        return null;
    };

    if (!h.initialized) {
        setError("Handle not initialized");
        return null;
    }

    // Example: allocate and return a string
    const result = dupeZ(h.allocator, "Example result") catch {
        setError("Failed to allocate string");
        return null;
    };

    clearError();
    return result.ptr;
}

/// Free a string allocated by the library
export fn sholes_free_string(str: ?[*:0]const u8) void {
    const s = str orelse return;
    const allocator = std.heap.c_allocator;

    const slice = std.mem.span(s);
    allocator.free(slice);
}

//==============================================================================
// Array/Buffer Operations
//==============================================================================

/// Process an array of data
export fn sholes_process_array(
    handle: ?*Handle,
    buffer: ?[*]const u8,
    len: u32,
) Result {
    const h = handle orelse {
        setError("Null handle");
        return .null_pointer;
    };

    const buf = buffer orelse {
        setError("Null buffer");
        return .null_pointer;
    };

    if (!h.initialized) {
        setError("Handle not initialized");
        return .@"error";
    }

    // Access the buffer
    const data = buf[0..len];
    _ = data;

    // Process data here

    clearError();
    return .ok;
}

//==============================================================================
// Error Handling
//==============================================================================

/// Get the last error message.
/// Return an allocated NUL-terminated copy of the current thread's error, or
/// null if no error is set or allocation fails. Leave the stored error unchanged.
/// Caller must free a non-null returned string with `sholes_free_string`.
export fn sholes_last_error() ?[*:0]const u8 {
    const err = last_error orelse return null;

    const allocator = std.heap.c_allocator;
    const c_str = dupeZ(allocator, err) catch return null;
    return c_str.ptr;
}

//==============================================================================
// Version Information
//==============================================================================

/// Get the library version
export fn sholes_version() [*:0]const u8 {
    return VERSION.ptr;
}

/// Get build information
export fn sholes_build_info() [*:0]const u8 {
    return BUILD_INFO.ptr;
}

//==============================================================================
// Callback Support
//==============================================================================

/// Callback function type (C ABI)
pub const Callback = *const fn (u64, u32) callconv(.c) u32;

/// Register a callback
export fn sholes_register_callback(
    handle: ?*Handle,
    callback: ?Callback,
) Result {
    const h = handle orelse {
        setError("Null handle");
        return .null_pointer;
    };

    const cb = callback orelse {
        setError("Null callback");
        return .null_pointer;
    };

    if (!h.initialized) {
        setError("Handle not initialized");
        return .@"error";
    }

    // Store callback for later use
    _ = cb;

    clearError();
    return .ok;
}

//==============================================================================
// Utility Functions
//==============================================================================

/// Check if handle is initialized
export fn sholes_is_initialized(handle: ?*Handle) u32 {
    const h = handle orelse return 0;
    return if (h.initialized) 1 else 0;
}

//==============================================================================
// Tests
//==============================================================================

test "lifecycle" {
    const handle = sholes_init() orelse return error.InitFailed;
    defer sholes_free(handle);

    try std.testing.expect(sholes_is_initialized(handle) == 1);

    const str = sholes_get_string(handle) orelse return error.StringFailed;
    defer sholes_free_string(str);
    try std.testing.expectEqualStrings("Example result", std.mem.span(str));
}

test "error handling" {
    const result = sholes_process(null, 0);
    try std.testing.expectEqual(Result.null_pointer, result);

    const err = sholes_last_error();
    defer sholes_free_string(err);
    try std.testing.expect(err != null);
}

test "version" {
    const ver = sholes_version();
    const ver_str = std.mem.span(ver);
    try std.testing.expectEqualStrings(VERSION, ver_str);
}
