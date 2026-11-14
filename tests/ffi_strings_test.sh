#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression tests for the dupeZ compatibility helper and its two callers.
# Instantiate only the FFI fixture, using the repository's zig build test.
# Usage: bash tests/ffi_strings_test.sh (requires Zig 0.15.2+)
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
command -v zig >/dev/null || { echo 'FAIL: Zig is required' >&2; exit 1; }
zig_bin=$(command -v zig)
# Resolve mise shims while still inside the configured repository.
if command -v mise >/dev/null 2>&1; then
  zig_bin=$(mise which zig 2>/dev/null || printf '%s' "$zig_bin")
fi
cp -R "$repo/src/interface/ffi" "$work/ffi"
sed -i -e 's/{{project}}/test_project/g' -e 's/{{PROJECT}}/TEST_PROJECT/g' \
  "$work/ffi/build.zig" "$work/ffi/src/main.zig" "$work/ffi/test/integration_test.zig"
# A minted repository has its own export prefix where the template has the
# token; map that prefix too, so the appended tests name the same functions.
# Only the exported symbols are renamed: a slug such as `root` must not turn
# Zig's `.root_module` into `.test_project_module`.
prefix=$(sed -nE 's/^export fn ([a-z0-9_]+)_init\(\).*/\1/p' "$work/ffi/src/main.zig" | head -1)
[[ -n "$prefix" ]] || { echo 'FAIL: no `export fn <prefix>_init()` in src/interface/ffi/src/main.zig' >&2; exit 1; }
if [[ "$prefix" != test_project ]]; then
  while IFS= read -r sym; do
    sed -i -E "s/\\b${prefix}_${sym}\\b/test_project_${sym}/g" \
      "$work/ffi/build.zig" "$work/ffi/src/main.zig" "$work/ffi/test/integration_test.zig"
  done < <(sed -nE "s/^export fn ${prefix}_([a-z0-9_]+)\\(.*/\\1/p" "$work/ffi/src/main.zig")
fi
# Tests share the production module so the private helper can be exercised
# with the leak-detecting allocator without changing the public FFI surface.
cat >> "$work/ffi/src/main.zig" <<'ZIG'

test "dupeZ owns a sentinel terminated copy including empty and binary inputs" {
    for ([_][]const u8{ "", "abc", "héllo 😀", "a\x00b" }) |input| {
        const copy = try dupeZ(std.testing.allocator, input);
        defer std.testing.allocator.free(copy);
        try std.testing.expectEqualSlices(u8, input, copy);
        try std.testing.expectEqual(@as(u8, 0), copy.ptr[copy.len]);
    }
    var input = [_]u8{ 'a', 'b' };
    const copy = try dupeZ(std.testing.allocator, &input);
    defer std.testing.allocator.free(copy);
    input[0] = 'z';
    try std.testing.expectEqualStrings("ab", copy);
}

test "dupeZ propagates allocation failure without leaking" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, dupeZ(failing.allocator(), "data"));
}

test "get_string returns independent owned C strings and clears an old error" {
    const handle = test_project_init() orelse return error.InitFailed;
    defer test_project_free(handle);
    _ = test_project_process(null, 0);
    const first = test_project_get_string(handle) orelse return error.StringFailed;
    defer test_project_free_string(first);
    const second = test_project_get_string(handle) orelse return error.StringFailed;
    defer test_project_free_string(second);
    try std.testing.expect(first != second);
    try std.testing.expectEqualStrings("Example result", std.mem.span(first));
    try std.testing.expectEqual(@as(u8, 0), first[14]);
    try std.testing.expect(test_project_last_error() == null);
}

test "last_error copies survive subsequent error clearing" {
    const handle = test_project_init() orelse return error.InitFailed;
    defer test_project_free(handle);
    try std.testing.expect(test_project_get_string(null) == null);
    const first = test_project_last_error() orelse return error.ExpectedError;
    defer test_project_free_string(first);
    const second = test_project_last_error() orelse return error.ExpectedError;
    defer test_project_free_string(second);
    try std.testing.expect(first != second);
    try std.testing.expectEqualStrings("Null handle", std.mem.span(first));
    try std.testing.expectEqual(Result.ok, test_project_process(handle, 0));
    try std.testing.expect(test_project_last_error() == null);
    try std.testing.expectEqualStrings("Null handle", std.mem.span(second));
}

test "get_string reports allocation failure on an initialized handle" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var handle = Handle{ .allocator = failing.allocator(), .initialized = true };
    defer clearError();
    try std.testing.expect(test_project_get_string(&handle) == null);
    const message = test_project_last_error() orelse return error.ExpectedError;
    defer test_project_free_string(message);
    try std.testing.expectEqualStrings("Failed to allocate string", std.mem.span(message));
}

test "an empty C string still needs allocation for its sentinel" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, dupeZ(failing.allocator(), ""));
}

test "get_string refuses an uninitialized handle before allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var handle = Handle{ .allocator = failing.allocator(), .initialized = false };
    defer clearError();
    try std.testing.expect(test_project_get_string(&handle) == null);
    const message = test_project_last_error() orelse return error.ExpectedError;
    defer test_project_free_string(message);
    try std.testing.expectEqualStrings("Handle not initialized", std.mem.span(message));
    try std.testing.expect(!failing.has_induced_failure);
}

test "freeing one error copy preserves the stored error and other copies" {
    defer clearError();
    try std.testing.expect(test_project_get_string(null) == null);
    const first = test_project_last_error() orelse return error.ExpectedError;
    test_project_free_string(first);
    const second = test_project_last_error() orelse return error.ExpectedError;
    defer test_project_free_string(second);
    try std.testing.expectEqualStrings("Null handle", std.mem.span(second));
    test_project_free_string(null);
    const third = test_project_last_error() orelse return error.ExpectedError;
    defer test_project_free_string(third);
    try std.testing.expectEqualStrings("Null handle", std.mem.span(third));
}
ZIG
(cd "$work/ffi" && "$zig_bin" build test)
