//! Suggest: autosuggestions for the line editor.
//!
//! Provides fish-style autosuggestions based on command history prefix matching.
//! As the user types, shows the most recent history entry that starts with
//! the current input as dimmed text after the cursor.

const std = @import("std");

const History = @import("../history.zig").History;

// =============================================================================
// Public API
// =============================================================================

/// Find a suggestion for the given input by searching history.
/// Returns the suffix to append (not the full suggestion) or null if none found.
pub fn fromHistory(input: []const u8, hist: *const History) ?[]const u8 {
    if (input.len == 0) return null;

    // Search history from most recent to oldest
    var i = hist.entries.items.len;
    while (i > 0) {
        i -= 1;
        const entry = hist.entries.items[i];

        // Check if this history entry starts with the current input
        if (entry.len > input.len and std.mem.startsWith(u8, entry, input)) {
            return entry[input.len..];
        }
    }

    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "no suggestion for empty input" {
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    hist.add("echo hello");
    try std.testing.expect(fromHistory("", &hist) == null);
}

test "finds matching history entry" {
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    hist.add("echo hello");
    hist.add("echo world");

    // Should match "echo world" (most recent) and return " world"
    const suggestion = fromHistory("echo", &hist);
    try std.testing.expect(suggestion != null);
    try std.testing.expectEqualStrings(" world", suggestion.?);
}

test "returns suffix only" {
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    hist.add("git commit -m 'test'");

    const suggestion = fromHistory("git co", &hist);
    try std.testing.expect(suggestion != null);
    try std.testing.expectEqualStrings("mmit -m 'test'", suggestion.?);
}

test "no match returns null" {
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    hist.add("echo hello");

    try std.testing.expect(fromHistory("xyz", &hist) == null);
}

test "prefers most recent match" {
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    hist.add("cd src");
    hist.add("cd test");
    hist.add("cd docs");

    const suggestion = fromHistory("cd ", &hist);
    try std.testing.expect(suggestion != null);
    try std.testing.expectEqualStrings("docs", suggestion.?);
}

test "exact match returns null (no suffix)" {
    var hist = History.init(std.testing.allocator);
    defer hist.deinit();

    hist.add("echo hello");

    // Exact match - nothing to suggest
    try std.testing.expect(fromHistory("echo hello", &hist) == null);
}
