//! Command history management with file persistence
const std = @import("std");

/// Maximum number of history entries to keep
const MAX_HISTORY_SIZE = 100;

/// History manager
pub const History = struct {
    allocator: std.mem.Allocator,
    /// History entries (oldest first)
    entries: std.ArrayListUnmanaged([]u8),

    pub fn init(allocator: std.mem.Allocator) History {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);
    }

    /// Add a line to history.
    /// Returns true if the line was added, false if it was skipped (empty/duplicate)
    /// or if allocation failed.
    pub fn add(self: *History, line: []const u8) bool {
        // Don't add empty lines
        if (line.len == 0) return false;

        // Don't add duplicates of the most recent entry
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, line)) return false;
        }

        // Remove oldest if at capacity
        if (self.entries.items.len >= MAX_HISTORY_SIZE) {
            const removed = self.entries.orderedRemove(0);
            self.allocator.free(removed);
        }

        // Add new entry - log OOM in debug builds
        const copy = self.allocator.dupe(u8, line) catch |err| {
            std.log.warn("history: failed to save entry: {}", .{err});
            return false;
        };
        self.entries.append(self.allocator, copy) catch |err| {
            std.log.warn("history: failed to append entry: {}", .{err});
            self.allocator.free(copy);
            return false;
        };
        return true;
    }

    /// Load history from a file
    pub fn load(self: *History, path: []const u8) void {
        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return;
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            _ = self.add(line);
        }
    }

    /// Save history to file
    pub fn save(self: *History, path: []const u8) void {
        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();

        for (self.entries.items) |entry| {
            file.writeAll(entry) catch return;
            _ = file.write("\n") catch return;
        }
    }

    /// Get entry count
    pub fn count(self: *const History) usize {
        return self.entries.items.len;
    }

    /// Get entry at index
    pub fn get(self: *const History, index: usize) ?[]const u8 {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    /// Search backwards for an entry containing the query.
    /// If `start` is provided, search starts before that index (for "find next").
    /// Returns the index of the matching entry, or null if not found.
    pub fn search(self: *const History, query: []const u8, start: ?usize) ?usize {
        if (query.len == 0) return null;

        var i = start orelse self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.indexOf(u8, self.entries.items[i], query) != null) {
                return i;
            }
        }
        return null;
    }

    /// Count total matches for a query in history
    pub fn countMatches(self: *const History, query: []const u8) usize {
        if (query.len == 0) return 0;
        var total: usize = 0;
        for (self.entries.items) |entry| {
            if (std.mem.indexOf(u8, entry, query) != null) {
                total += 1;
            }
        }
        return total;
    }

    /// Get the position (1-based) of a match index among all matches
    pub fn getMatchPosition(self: *const History, query: []const u8, match_index: usize) usize {
        var position: usize = 0;
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.indexOf(u8, entry, query) != null) {
                position += 1;
                if (i == match_index) return position;
            }
        }
        return 0;
    }
};

// Tests
const testing = std.testing;

test "history: add and retrieve" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();

    try testing.expect(hist.add("command 1"));
    try testing.expect(hist.add("command 2"));
    try testing.expect(hist.add("command 3"));

    try testing.expectEqual(@as(usize, 3), hist.count());
    try testing.expectEqualStrings("command 1", hist.get(0).?);
    try testing.expectEqualStrings("command 2", hist.get(1).?);
    try testing.expectEqualStrings("command 3", hist.get(2).?);
}

test "history: no duplicate consecutive entries" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();

    try testing.expect(hist.add("command 1"));
    try testing.expect(!hist.add("command 1")); // Duplicate - returns false
    try testing.expect(hist.add("command 2"));
    try testing.expect(!hist.add("command 2")); // Duplicate - returns false

    try testing.expectEqual(@as(usize, 2), hist.count());
}

test "history: empty lines ignored" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();

    try testing.expect(!hist.add("")); // Empty - returns false
    try testing.expect(hist.add("command"));
    try testing.expect(!hist.add("")); // Empty - returns false

    try testing.expectEqual(@as(usize, 1), hist.count());
}

test "history: search finds match" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();

    _ = hist.add("echo hello");
    _ = hist.add("ls -la");
    _ = hist.add("echo world");

    // Search for "echo" finds most recent match (index 2)
    try testing.expectEqual(@as(?usize, 2), hist.search("echo", null));
    // Search for "ls" finds index 1
    try testing.expectEqual(@as(?usize, 1), hist.search("ls", null));
    // Search for nonexistent returns null
    try testing.expectEqual(@as(?usize, null), hist.search("git", null));
}

test "history: search with start finds earlier match" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();

    _ = hist.add("echo first");
    _ = hist.add("echo second");
    _ = hist.add("echo third");

    // First search finds index 2
    try testing.expectEqual(@as(?usize, 2), hist.search("echo", null));
    // Search starting from 2 finds index 1
    try testing.expectEqual(@as(?usize, 1), hist.search("echo", 2));
    // Search starting from 1 finds index 0
    try testing.expectEqual(@as(?usize, 0), hist.search("echo", 1));
    // Search starting from 0 finds nothing
    try testing.expectEqual(@as(?usize, null), hist.search("echo", 0));
}

test "history: search empty query returns null" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();

    _ = hist.add("echo hello");
    try testing.expectEqual(@as(?usize, null), hist.search("", null));
}

test "history: countMatches counts all matching entries" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();

    _ = hist.add("echo hello");
    _ = hist.add("ls -la");
    _ = hist.add("echo world");
    _ = hist.add("echo again");

    try testing.expectEqual(@as(usize, 3), hist.countMatches("echo"));
    try testing.expectEqual(@as(usize, 1), hist.countMatches("ls"));
    try testing.expectEqual(@as(usize, 0), hist.countMatches("git"));
    try testing.expectEqual(@as(usize, 0), hist.countMatches(""));
}

test "history: getMatchPosition returns 1-based position" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();

    _ = hist.add("echo first"); // index 0, position 1
    _ = hist.add("ls -la"); // index 1, not a match
    _ = hist.add("echo second"); // index 2, position 2
    _ = hist.add("echo third"); // index 3, position 3

    // Position among "echo" matches
    try testing.expectEqual(@as(usize, 1), hist.getMatchPosition("echo", 0));
    try testing.expectEqual(@as(usize, 2), hist.getMatchPosition("echo", 2));
    try testing.expectEqual(@as(usize, 3), hist.getMatchPosition("echo", 3));
}

test "history: file persistence" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();

    // Create temp file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("history", .{});
    try file.writeAll("line1\nline2\nline3\n");
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("history", &path_buf);

    // Load history
    hist.load(path);
    try testing.expectEqual(@as(usize, 3), hist.count());
    try testing.expectEqualStrings("line1", hist.get(0).?);

    // Add and save
    try testing.expect(hist.add("line4"));
    hist.save(path);

    // Reload and verify
    var hist2 = History.init(testing.allocator);
    defer hist2.deinit();
    hist2.load(path);

    try testing.expectEqual(@as(usize, 4), hist2.count());
    try testing.expectEqualStrings("line4", hist2.get(3).?);
}
