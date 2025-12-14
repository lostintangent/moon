//! Tab completion for the line editor
//!
//! Provides completions for:
//! - File paths (when word contains '/' or starts with '.', '~')
//! - Executable commands from PATH (for first word)
//! - Builtins (for first word)

const std = @import("std");
const builtins = @import("../../../runtime/builtins.zig");

/// Result of a completion attempt
pub const Completion = struct {
    /// The text to insert (replaces the current word)
    text: []const u8,
    /// Whether this is the only completion (can auto-insert)
    unique: bool,
};

/// Find completions for the given input at cursor position
/// Returns a list of possible completions, or null if none found
pub fn complete(allocator: std.mem.Allocator, input: []const u8, cursor: usize) !?CompletionResult {
    // Find the word being completed (from last space to cursor)
    const word_start = findWordStart(input, cursor);
    const word = input[word_start..cursor];
    const is_first_word = isFirstWord(input, word_start);

    if (word.len == 0) return null;

    var completions: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (completions.items) |c| allocator.free(c);
        completions.deinit(allocator);
    }

    // Determine completion type based on context
    if (isPathLike(word)) {
        // File/directory completion
        try completeFiles(allocator, word, &completions);
    } else if (is_first_word) {
        // Command completion (builtins + executables)
        try completeCommands(allocator, word, &completions);
    } else {
        // Argument position - try file completion
        try completeFiles(allocator, word, &completions);
    }

    if (completions.items.len == 0) return null;

    // Sort completions for consistent display
    std.mem.sort([]const u8, completions.items, {}, lessThan);

    return CompletionResult{
        .completions = try completions.toOwnedSlice(allocator),
        .word_start = word_start,
        .word_end = cursor,
    };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Result of completion with metadata
pub const CompletionResult = struct {
    completions: []const []const u8,
    word_start: usize, // Start of word being completed
    word_end: usize, // End of word (cursor position)

    pub fn deinit(self: *CompletionResult, allocator: std.mem.Allocator) void {
        for (self.completions) |c| allocator.free(c);
        allocator.free(self.completions);
    }

    /// Get common prefix of all completions (for partial completion)
    pub fn commonPrefix(self: *const CompletionResult) []const u8 {
        if (self.completions.len == 0) return "";
        if (self.completions.len == 1) return self.completions[0];

        const first = self.completions[0];
        var prefix_len: usize = first.len;

        for (self.completions[1..]) |c| {
            var i: usize = 0;
            while (i < prefix_len and i < c.len and first[i] == c[i]) : (i += 1) {}
            prefix_len = i;
        }

        return first[0..prefix_len];
    }
};

/// Find start of current word (after last unquoted space)
fn findWordStart(input: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;

    var i = cursor;
    while (i > 0) {
        i -= 1;
        if (input[i] == ' ' or input[i] == '\t') {
            return i + 1;
        }
    }
    return 0;
}

/// Check if this is the first word (command position)
fn isFirstWord(input: []const u8, word_start: usize) bool {
    // If word starts at 0, it's the first word
    if (word_start == 0) return true;

    // Check if everything before word_start is whitespace
    for (input[0..word_start]) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

/// Check if word looks like a path
fn isPathLike(word: []const u8) bool {
    if (word.len == 0) return false;
    return word[0] == '/' or word[0] == '.' or word[0] == '~' or
        std.mem.indexOf(u8, word, "/") != null;
}

/// Complete file/directory names
fn completeFiles(allocator: std.mem.Allocator, word: []const u8, completions: *std.ArrayListUnmanaged([]const u8)) !void {
    // Handle tilde expansion
    var expanded_buf: [std.fs.max_path_bytes]u8 = undefined;
    var prefix: []const u8 = "";
    const search_word = if (word.len > 0 and word[0] == '~') blk: {
        if (std.posix.getenv("HOME")) |home| {
            const rest = if (word.len > 1) word[1..] else "";
            const expanded = std.fmt.bufPrint(&expanded_buf, "{s}{s}", .{ home, rest }) catch return;
            prefix = "~";
            break :blk expanded;
        }
        break :blk word;
    } else word;

    // Split into directory and file prefix
    const last_slash = std.mem.lastIndexOf(u8, search_word, "/");
    const dir_path = if (last_slash) |idx| search_word[0 .. idx + 1] else "./";
    const file_prefix = if (last_slash) |idx| search_word[idx + 1 ..] else search_word;

    // Calculate the prefix to preserve in completions
    const preserve_prefix = if (last_slash) |idx|
        if (prefix.len > 0) blk: {
            // ~/ case - show ~/ + relative path
            break :blk word[0 .. idx + 1];
        } else word[0 .. idx + 1]
    else if (prefix.len > 0)
        "~/"
    else
        "";

    // Open directory
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    // Iterate and find matches
    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        if (file_prefix.len == 0 or std.mem.startsWith(u8, entry.name, file_prefix)) {
            // Skip hidden files unless prefix starts with '.'
            if (entry.name[0] == '.' and (file_prefix.len == 0 or file_prefix[0] != '.')) {
                continue;
            }

            const is_dir = entry.kind == .directory;
            const suffix: []const u8 = if (is_dir) "/" else "";

            const completion = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
                preserve_prefix,
                entry.name,
                suffix,
            });
            try completions.append(allocator, completion);
        }
    }
}

/// Complete command names (builtins + PATH executables)
fn completeCommands(allocator: std.mem.Allocator, word: []const u8, completions: *std.ArrayListUnmanaged([]const u8)) !void {
    // Add matching builtins (from centralized registry)
    for (builtins.getNames()) |name| {
        if (std.mem.startsWith(u8, name, word)) {
            try completions.append(allocator, try allocator.dupe(u8, name));
        }
    }

    // Add matching executables from PATH
    const path_env = std.posix.getenv("PATH") orelse return;
    var path_iter = std.mem.splitScalar(u8, path_env, ':');

    // Track seen names to avoid duplicates
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    while (path_iter.next()) |path_dir| {
        if (path_dir.len == 0) continue;

        var dir = std.fs.cwd().openDir(path_dir, .{ .iterate = true }) catch continue;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch continue) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.startsWith(u8, entry.name, word)) continue;
            if (seen.contains(entry.name)) continue;

            // Check if executable (best effort)
            const completion = try allocator.dupe(u8, entry.name);
            try completions.append(allocator, completion);
            try seen.put(try allocator.dupe(u8, entry.name), {});
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "findWordStart: no spaces" {
    try std.testing.expectEqual(@as(usize, 0), findWordStart("echo", 4));
}

test "findWordStart: with space" {
    try std.testing.expectEqual(@as(usize, 5), findWordStart("echo hello", 10));
}

test "findWordStart: at start" {
    try std.testing.expectEqual(@as(usize, 0), findWordStart("echo hello", 3));
}

test "isFirstWord: at start" {
    try std.testing.expect(isFirstWord("echo", 0));
}

test "isFirstWord: second word" {
    try std.testing.expect(!isFirstWord("echo hello", 5));
}

test "isPathLike: absolute path" {
    try std.testing.expect(isPathLike("/usr/bin"));
}

test "isPathLike: relative path" {
    try std.testing.expect(isPathLike("./test"));
}

test "isPathLike: tilde" {
    try std.testing.expect(isPathLike("~/"));
}

test "isPathLike: simple word" {
    try std.testing.expect(!isPathLike("echo"));
}

test "commonPrefix: single item" {
    var result = CompletionResult{
        .completions = &[_][]const u8{"hello"},
        .word_start = 0,
        .word_end = 0,
    };
    try std.testing.expectEqualStrings("hello", result.commonPrefix());
}

test "commonPrefix: multiple items" {
    const items = [_][]const u8{ "hello", "help", "helicopter" };
    var result = CompletionResult{
        .completions = &items,
        .word_start = 0,
        .word_end = 0,
    };
    try std.testing.expectEqualStrings("hel", result.commonPrefix());
}
