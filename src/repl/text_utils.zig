//! Text utilities: shared helpers for text manipulation in the REPL.
//!
//! Provides common text operations used across the editor and completion:
//! - Word boundary detection for cursor movement and editing
//! - Path utilities for tilde expansion and contraction

const std = @import("std");

// =============================================================================
// Word boundaries
// =============================================================================

/// Find the position of the previous word boundary (moving left).
/// Skips trailing whitespace, then skips the word.
pub inline fn findWordBoundaryLeft(buf: []const u8, cursor: usize) usize {
    var pos = cursor;
    // Skip trailing whitespace
    while (pos > 0 and isWordBreak(buf[pos - 1])) pos -= 1;
    // Skip the word
    while (pos > 0 and !isWordBreak(buf[pos - 1])) pos -= 1;
    return pos;
}

/// Find the position of the next word boundary (moving right).
/// Skips the current word, then skips whitespace.
pub inline fn findWordBoundaryRight(buf: []const u8, cursor: usize) usize {
    var pos = cursor;
    // Skip current word
    while (pos < buf.len and !isWordBreak(buf[pos])) pos += 1;
    // Skip whitespace
    while (pos < buf.len and isWordBreak(buf[pos])) pos += 1;
    return pos;
}

/// Find the start of the word at or before the given position.
/// Used for completion to determine what word is being typed.
pub inline fn findWordStart(buf: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (isWordBreak(buf[i])) {
            return i + 1;
        }
    }
    return 0;
}

/// Check if a character is a word break (whitespace).
pub inline fn isWordBreak(c: u8) bool {
    return c == ' ' or c == '\t';
}

// =============================================================================
// Path utilities
// =============================================================================

/// Expand a tilde prefix to the home directory.
/// Returns the expanded path in the provided buffer, or null on error.
/// If the path doesn't start with ~, returns null.
pub fn expandTilde(path: []const u8, home: []const u8, buf: []u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '~') return null;
    if (path.len == 1 or path[1] == '/') {
        const rest = if (path.len > 1) path[1..] else "";
        return std.fmt.bufPrint(buf, "{s}{s}", .{ home, rest }) catch null;
    }
    return null;
}

/// Contract a path by replacing the home directory prefix with ~.
/// Returns the contracted path in the provided buffer, or the original path if no contraction.
pub fn contractTilde(path: []const u8, home: []const u8, buf: []u8) []const u8 {
    if (!std.mem.startsWith(u8, path, home)) return path;
    if (path.len == home.len) return "~";
    if (path[home.len] == '/') {
        return std.fmt.bufPrint(buf, "~{s}", .{path[home.len..]}) catch path;
    }
    return path;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "findWordBoundaryLeft: end of second word" {
    try testing.expectEqual(@as(usize, 6), findWordBoundaryLeft("hello world", 11));
}

test "findWordBoundaryLeft: start of second word" {
    try testing.expectEqual(@as(usize, 0), findWordBoundaryLeft("hello world", 6));
}

test "findWordBoundaryLeft: single word" {
    try testing.expectEqual(@as(usize, 0), findWordBoundaryLeft("hello", 5));
}

test "findWordBoundaryLeft: at start" {
    try testing.expectEqual(@as(usize, 0), findWordBoundaryLeft("hello", 0));
}

test "findWordBoundaryRight: from start" {
    try testing.expectEqual(@as(usize, 6), findWordBoundaryRight("hello world", 0));
}

test "findWordBoundaryRight: from middle of first word" {
    try testing.expectEqual(@as(usize, 6), findWordBoundaryRight("hello world", 3));
}

test "findWordBoundaryRight: from second word" {
    try testing.expectEqual(@as(usize, 11), findWordBoundaryRight("hello world", 6));
}

test "findWordStart: no spaces" {
    try testing.expectEqual(@as(usize, 0), findWordStart("echo", 4));
}

test "findWordStart: with space" {
    try testing.expectEqual(@as(usize, 5), findWordStart("echo hello", 10));
}

test "findWordStart: at start" {
    try testing.expectEqual(@as(usize, 0), findWordStart("echo hello", 3));
}

test "findWordStart: with tab" {
    try testing.expectEqual(@as(usize, 5), findWordStart("echo\thello", 10));
}

test "expandTilde: home only" {
    var buf: [256]u8 = undefined;
    const result = expandTilde("~", "/home/user", &buf);
    try testing.expectEqualStrings("/home/user", result.?);
}

test "expandTilde: with subpath" {
    var buf: [256]u8 = undefined;
    const result = expandTilde("~/src/project", "/home/user", &buf);
    try testing.expectEqualStrings("/home/user/src/project", result.?);
}

test "expandTilde: not a tilde path" {
    var buf: [256]u8 = undefined;
    try testing.expect(expandTilde("/usr/bin", "/home/user", &buf) == null);
}

test "expandTilde: tilde with username (unsupported)" {
    var buf: [256]u8 = undefined;
    try testing.expect(expandTilde("~other/path", "/home/user", &buf) == null);
}

test "contractTilde: exact home" {
    var buf: [256]u8 = undefined;
    const result = contractTilde("/home/user", "/home/user", &buf);
    try testing.expectEqualStrings("~", result);
}

test "contractTilde: with subpath" {
    var buf: [256]u8 = undefined;
    const result = contractTilde("/home/user/src/project", "/home/user", &buf);
    try testing.expectEqualStrings("~/src/project", result);
}

test "contractTilde: not in home" {
    var buf: [256]u8 = undefined;
    const result = contractTilde("/usr/bin", "/home/user", &buf);
    try testing.expectEqualStrings("/usr/bin", result);
}

test "contractTilde: partial match (not at boundary)" {
    var buf: [256]u8 = undefined;
    // /home/username should NOT match /home/user
    const result = contractTilde("/home/username/foo", "/home/user", &buf);
    try testing.expectEqualStrings("/home/username/foo", result);
}
