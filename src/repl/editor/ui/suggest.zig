//! Suggest: context-aware autosuggestions for the line editor.
//!
//! Provides fish-style autosuggestions using the unified scoring from history.zig.
//! See that module for scoring weights and algorithm details.

const std = @import("std");
const history = @import("../history.zig");
const History = history.History;

/// Find the best suggestion for the given input.
/// Returns the suffix to append (not the full command) or null if none found.
pub fn fromHistory(input: []const u8, hist: *const History, cwd: []const u8) ?[]const u8 {
    if (input.len == 0) return null;

    const now = std.time.timestamp();
    var best: ?[]const u8 = null;
    var best_score: f64 = -1;

    for (hist.entries.items) |e| {
        if (e.command.len <= input.len) continue;
        if (!std.mem.startsWith(u8, e.command, input)) continue;

        const score = history.scoreEntry(&e, cwd, now);
        if (score > best_score) {
            best_score = score;
            best = e.command[input.len..];
        }
    }

    return best;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "match: returns suffix for matching prefix" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    _ = hist.add(.{ .command = "git commit -m 'test'", .cwd = "/", .exit_status = 0 });

    const suggestion = fromHistory("git co", &hist, "/");
    try testing.expect(suggestion != null);
    try testing.expectEqualStrings("mmit -m 'test'", suggestion.?);
}

test "match: selects most recent when multiple matches" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    _ = hist.add(.{ .command = "echo hello", .cwd = "/", .exit_status = 0 });
    _ = hist.add(.{ .command = "echo world", .cwd = "/", .exit_status = 0 });

    const suggestion = fromHistory("echo", &hist, "/");
    try testing.expect(suggestion != null);
    try testing.expectEqualStrings(" world", suggestion.?);
}

test "match: no suggestion when no prefix match" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    _ = hist.add(.{ .command = "echo hello", .cwd = "/", .exit_status = 0 });
    try testing.expect(fromHistory("xyz", &hist, "/") == null);
}

test "match: no suggestion for exact match" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    _ = hist.add(.{ .command = "echo hello", .cwd = "/", .exit_status = 0 });
    try testing.expect(fromHistory("echo hello", &hist, "/") == null);
}

test "empty: no suggestion for empty input" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    _ = hist.add(.{ .command = "echo hello", .cwd = "/", .exit_status = 0 });
    try testing.expect(fromHistory("", &hist, "/") == null);
}

test "empty: no suggestion from empty history" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    try testing.expect(fromHistory("echo", &hist, "/") == null);
}

test "ranking: prefers current directory over other" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    _ = hist.add(.{ .command = "make test", .cwd = "/project", .exit_status = 0 });
    _ = hist.add(.{ .command = "make build", .cwd = "/other", .exit_status = 0 });

    const suggestion = fromHistory("make", &hist, "/project");
    try testing.expect(suggestion != null);
    try testing.expectEqualStrings(" test", suggestion.?);
}

test "ranking: prefers successful over failed" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    _ = hist.add(.{ .command = "make success", .cwd = "/", .exit_status = 0 });
    _ = hist.add(.{ .command = "make failed", .cwd = "/", .exit_status = 1 });

    const suggestion = fromHistory("make", &hist, "/");
    try testing.expect(suggestion != null);
    try testing.expectEqualStrings(" success", suggestion.?);
}

test "ranking: prefers frequent over rare" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();

    // Add rare command once
    _ = hist.add(.{ .command = "npm run rare", .cwd = "/", .exit_status = 0 });

    // Add frequent command multiple times to build frequency
    _ = hist.add(.{ .command = "npm run frequent", .cwd = "/", .exit_status = 0 });
    _ = hist.add(.{ .command = "npm run frequent", .cwd = "/", .exit_status = 0 });
    _ = hist.add(.{ .command = "npm run frequent", .cwd = "/", .exit_status = 0 });

    const suggestion = fromHistory("npm run", &hist, "/");
    try testing.expect(suggestion != null);
    try testing.expectEqualStrings(" frequent", suggestion.?);
}
