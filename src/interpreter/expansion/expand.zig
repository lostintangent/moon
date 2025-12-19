//! Word expansion: transforms shell words into executable arguments.
//!
//! This module implements the second parsing layer that interprets expansion
//! syntax within words. While the structural parser handles command grammar,
//! this expander interprets the content of each word segment:
//!
//! - Variables: `$var`, `${var}`, `$var[1]`, `$1`, `$#`, `$*`, `$?`
//! - Command substitution: `$(cmd)`
//! - Tilde expansion: `~` → home directory
//! - Glob patterns: `*.txt`, `**/*.zig`, `[a-z].md`
//! - Escape sequences: `\n`, `\t`, `\$`
//!
//! Expansion respects quoting context:
//! - Single quotes (`'...'`): No expansion, literal text
//! - Double quotes (`"..."`): Variables and escapes expand, globs don't
//! - Bare words: Full expansion including globs
//!
//! List variables expand to multiple arguments (no word-splitting surprises).
//! For example, if `$xs` is `["a", "b"]`, then `echo $xs` becomes `echo a b`.

const std = @import("std");
const token_types = @import("../../language/tokens.zig");
const State = @import("../../runtime/state.zig").State;
const interpreter_mod = @import("../interpreter.zig");
const glob = @import("glob.zig");
const WordPart = token_types.WordPart;

// Re-export glob utilities for external use
pub const globMatch = glob.globMatch;
pub const hasGlobChars = glob.hasGlobChars;

// Re-use shared helper from glob module
const singletonSlice = glob.singletonSlice;

pub const ExpandError = error{
    UnterminatedVariable,
    InvalidVariableName,
    EmptyCommandSubstitution,
    CommandSubstitutionFailed,
};

// =============================================================================
// Ownership Convention
// =============================================================================
//
// All slices returned by functions in this module (expandWord, expandWords, etc.)
// are allocated using the ExpandContext's allocator. Callers should:
//
// 1. Use an ArenaAllocator for the ExpandContext (recommended)
// 2. Free the arena after the expanded values are no longer needed
// 3. NOT manually free individual returned slices - the arena handles cleanup
//
// The typical pattern is:
//   var arena = std.heap.ArenaAllocator.init(allocator);
//   defer arena.deinit();
//   var ctx = ExpandContext.init(arena.allocator(), state);
//   const expanded = try expandWord(&ctx, segs);  // Valid until arena.deinit()
// =============================================================================

pub const ExpandContext = struct {
    allocator: std.mem.Allocator,
    state: *State,
    mock_cmdsub: ?std.StringHashMap([]const u8),
    mock_glob: ?std.StringHashMap([]const []const u8),

    pub fn init(allocator: std.mem.Allocator, state: *State) ExpandContext {
        return .{
            .allocator = allocator,
            .state = state,
            .mock_cmdsub = null,
            .mock_glob = null,
        };
    }

    pub fn deinit(self: *ExpandContext) void {
        if (self.mock_cmdsub) |*m| m.deinit();
        if (self.mock_glob) |*m| m.deinit();
    }

    /// Get variable value from shell state or environment
    pub fn getVar(self: *ExpandContext, name: []const u8) ?[]const []const u8 {
        // Special variables
        if (std.mem.eql(u8, name, "?") or std.mem.eql(u8, name, "status")) {
            // Status is handled specially - return as single-element list
            return null; // Let caller handle status formatting
        }

        // Check shell vars first
        if (self.state.getVarList(name)) |list| {
            return list;
        }

        // Fall back to environment - wrap single value in slice
        // Note: For env vars, we return null and let expandText handle it
        return null;
    }

    /// Get home directory from state
    pub fn getHome(self: *ExpandContext) []const u8 {
        return self.state.home orelse "/home/user";
    }

    /// Get current status as string
    pub fn getStatus(self: *ExpandContext) u8 {
        return self.state.status;
    }

    pub fn setMockCmdsub(self: *ExpandContext, cmd: []const u8, output: []const u8) !void {
        if (self.mock_cmdsub == null) {
            self.mock_cmdsub = std.StringHashMap([]const u8).init(self.allocator);
        }
        try self.mock_cmdsub.?.put(cmd, output);
    }

    pub fn setMockGlob(self: *ExpandContext, pattern: []const u8, matches: []const []const u8) !void {
        if (self.mock_glob == null) {
            self.mock_glob = std.StringHashMap([]const []const u8).init(self.allocator);
        }
        try self.mock_glob.?.put(pattern, matches);
    }

    /// Set a variable (delegates to state, used by tests)
    pub fn setVar(self: *ExpandContext, name: []const u8, values: []const []const u8) !void {
        try self.state.setVarList(name, values);
    }
};

pub fn expandWord(ctx: *ExpandContext, segs: []const WordPart) (ExpandError || std.mem.Allocator.Error)![]const []const u8 {
    var results: std.ArrayListUnmanaged([]const u8) = .empty;
    try results.append(ctx.allocator, "");

    for (segs) |seg| {
        const expanded = try expandSegment(ctx, seg);
        results = try cartesian(ctx.allocator, results.items, expanded);
    }

    return try results.toOwnedSlice(ctx.allocator);
}

fn expandSegment(ctx: *ExpandContext, seg: WordPart) (ExpandError || std.mem.Allocator.Error)![]const []const u8 {
    switch (seg.quotes) {
        .single => return singletonSlice(ctx.allocator, seg.text),
        .double => return expandText(ctx, seg.text, .{ .expand_glob = false }),
        .none => return expandText(ctx, seg.text, .{ .expand_glob = true }),
    }
}

const ExpandOptions = struct {
    expand_vars: bool = true,
    expand_cmdsub: bool = true,
    expand_escapes: bool = true,
    expand_glob: bool = false,
};

fn appendLiteral(allocator: std.mem.Allocator, current: []const []const u8, literal: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var next: std.ArrayListUnmanaged([]const u8) = .empty;
    for (current) |s| {
        const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ s, literal });
        try next.append(allocator, combined);
    }
    return next;
}

/// Unified text expansion function - handles variables, command substitution, escapes, and globs
fn expandText(ctx: *ExpandContext, text: []const u8, opts: ExpandOptions) (ExpandError || std.mem.Allocator.Error)![]const []const u8 {
    // Handle tilde expansion for bare words at the start
    if (opts.expand_glob and text.len > 0 and text[0] == '~') {
        if (text.len == 1 or text[1] == '/') {
            const rest = if (text.len > 1) text[1..] else "";
            const expanded = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ ctx.getHome(), rest });
            return singletonSlice(ctx.allocator, expanded);
        }
    }

    var results: std.ArrayListUnmanaged([]const u8) = .empty;
    try results.append(ctx.allocator, "");

    var i: usize = 0;
    var literal_start: usize = 0;

    while (i < text.len) {
        const is_var = text[i] == '$' and opts.expand_vars;
        const is_escape = text[i] == '\\' and i + 1 < text.len and opts.expand_escapes;

        if (is_var or is_escape) {
            // Flush literal if any
            if (i > literal_start) {
                const chunk = text[literal_start..i];
                const next_results = try appendLiteral(ctx.allocator, results.items, chunk);
                results = next_results;
            }

            if (is_var) {
                if (i + 1 < text.len and text[i + 1] == '(' and opts.expand_cmdsub) {
                    const end = findMatchingParen(text, i + 1) orelse return ExpandError.EmptyCommandSubstitution;
                    const cmd = text[i + 2 .. end];
                    const output = try runCmdsub(ctx, cmd);

                    // Split output into lines ($() produces a list of lines)
                    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
                    var iter = std.mem.splitScalar(u8, output, '\n');
                    while (iter.next()) |line| {
                        try lines.append(ctx.allocator, line);
                    }
                    // If empty output, produce empty list element for proper concatenation
                    if (lines.items.len == 0) {
                        try lines.append(ctx.allocator, "");
                    }
                    results = try cartesian(ctx.allocator, results.items, try lines.toOwnedSlice(ctx.allocator));
                    i = end + 1;
                } else {
                    const var_result = try parseAndExpandVar(ctx, text, i);
                    results = try cartesian(ctx.allocator, results.items, var_result.values);
                    i = var_result.new_pos;
                }
            } else {
                // is_escape
                const ch = text[i + 1];
                const escaped = switch (ch) {
                    'n' => "\n",
                    't' => "\t",
                    '\\' => "\\",
                    '"' => "\"",
                    '$' => "$",
                    else => blk: {
                        const s = try ctx.allocator.alloc(u8, 2);
                        s[0] = '\\';
                        s[1] = ch;
                        break :blk s;
                    },
                };
                const escaped_list = try ctx.allocator.alloc([]const u8, 1);
                escaped_list[0] = escaped;
                results = try cartesian(ctx.allocator, results.items, escaped_list);
                i += 2;
            }
            literal_start = i;
        } else {
            i += 1;
        }
    }

    // Flush remaining literal
    if (i > literal_start) {
        const chunk = text[literal_start..i];
        const next_results = try appendLiteral(ctx.allocator, results.items, chunk);
        results = next_results;
    }

    const expanded_items = try results.toOwnedSlice(ctx.allocator);

    // Handle glob expansion for bare words
    if (opts.expand_glob and expanded_items.len == 1) {
        const pattern = expanded_items[0];
        if (glob.hasGlobChars(pattern)) {
            return try glob.expandGlob(ctx.allocator, pattern, ctx.mock_glob);
        }
    }

    return expanded_items;
}

/// Return type for variable expansion functions
const VarExpansionResult = struct { values: []const []const u8, new_pos: usize };

fn parseAndExpandVar(ctx: *ExpandContext, text: []const u8, start: usize) (ExpandError || std.mem.Allocator.Error)!VarExpansionResult {
    var i = start + 1;

    if (i < text.len and text[i] == '{') {
        i += 1;
        const name_start = i;
        while (i < text.len and text[i] != '}') : (i += 1) {}
        if (i >= text.len) return ExpandError.UnterminatedVariable;
        const name = text[name_start..i];
        i += 1;
        const values = ctx.getVar(name) orelse try getEnvOrStatus(ctx, name);
        // Check for indexing after ${var}
        if (i < text.len and text[i] == '[') {
            return try applyIndexing(ctx, values, text, i);
        }
        return .{ .values = values, .new_pos = i };
    }

    // Handle special single-character variables: $#, $*, $?
    if (i < text.len) {
        const ch = text[i];
        if (ch == '#' or ch == '*' or ch == '?') {
            const name = text[i .. i + 1];
            const values = try getEnvOrStatus(ctx, name);
            return .{ .values = values, .new_pos = i + 1 };
        }
    }

    const name_start = i;
    while (i < text.len and token_types.isIdentChar(text[i])) : (i += 1) {}
    const name = text[name_start..i];

    if (name.len == 0) {
        return .{ .values = try singletonSlice(ctx.allocator, "$"), .new_pos = start + 1 };
    }

    const values = ctx.getVar(name) orelse try getEnvOrStatus(ctx, name);

    // Check for indexing: $var[index] or $var[start..end]
    if (i < text.len and text[i] == '[') {
        return try applyIndexing(ctx, values, text, i);
    }

    return .{ .values = values, .new_pos = i };
}

/// Apply array indexing to a list of values.
/// Supports: [n], [-n], [start..end], [start..], [..end]
/// Indices are 1-based. Negative indices count from end.
fn applyIndexing(ctx: *ExpandContext, values: []const []const u8, text: []const u8, bracket_pos: usize) (ExpandError || std.mem.Allocator.Error)!VarExpansionResult {
    var i = bracket_pos + 1; // skip '['

    // Find the closing bracket
    const close_bracket = std.mem.indexOfScalarPos(u8, text, i, ']') orelse {
        return ExpandError.UnterminatedVariable;
    };

    const index_expr = text[i..close_bracket];
    i = close_bracket + 1;

    // Check for range syntax (..)
    if (std.mem.indexOf(u8, index_expr, "..")) |dot_pos| {
        // Range: [start..end], [start..], [..end]
        const start_str = index_expr[0..dot_pos];
        const end_str = index_expr[dot_pos + 2 ..];

        const start_idx = if (start_str.len == 0)
            @as(isize, 1) // default to first element
        else
            std.fmt.parseInt(isize, start_str, 10) catch return ExpandError.InvalidVariableName;

        const end_idx = if (end_str.len == 0)
            @as(isize, @intCast(values.len)) // default to last element
        else
            std.fmt.parseInt(isize, end_str, 10) catch return ExpandError.InvalidVariableName;

        const resolved_start = resolveIndex(start_idx, values.len);
        const resolved_end = resolveIndex(end_idx, values.len);

        if (resolved_start == null or resolved_end == null or resolved_start.? > resolved_end.?) {
            return .{ .values = &[_][]const u8{}, .new_pos = i };
        }

        const slice = values[resolved_start.? .. resolved_end.? + 1];
        return .{ .values = slice, .new_pos = i };
    } else {
        // Single index: [n] or [-n]
        const idx = std.fmt.parseInt(isize, index_expr, 10) catch {
            return ExpandError.InvalidVariableName;
        };

        const resolved = resolveIndex(idx, values.len);
        if (resolved == null) {
            return .{ .values = try singletonSlice(ctx.allocator, ""), .new_pos = i };
        }

        return .{ .values = try singletonSlice(ctx.allocator, values[resolved.?]), .new_pos = i };
    }
}

/// Convert 1-based (possibly negative) index to 0-based index.
/// Returns null if out of bounds.
/// Positive: 1 = first element, 2 = second, etc.
/// Negative: -1 = last element, -2 = second-to-last, etc.
fn resolveIndex(idx: isize, len: usize) ?usize {
    if (len == 0) return null;

    const len_signed: isize = @intCast(len);

    if (idx > 0) {
        // 1-based positive index
        if (idx > len_signed) return null;
        return @intCast(idx - 1);
    } else if (idx < 0) {
        // Negative index: -1 = last element
        const resolved = len_signed + idx;
        if (resolved < 0) return null;
        return @intCast(resolved);
    } else {
        // idx == 0 is invalid in 1-based indexing
        return null;
    }
}

/// Get variable from environment or handle special variables like $?, $status, $1, $#, $*
fn getEnvOrStatus(ctx: *ExpandContext, name: []const u8) ![]const []const u8 {
    // Handle status variables
    if (std.mem.eql(u8, name, "?") or std.mem.eql(u8, name, "status")) {
        const status_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{ctx.getStatus()});
        return singletonSlice(ctx.allocator, status_str);
    }

    // Handle $# (argument count)
    if (std.mem.eql(u8, name, "#")) {
        const argv = ctx.state.getVarList("argv") orelse &[_][]const u8{};
        const count_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{argv.len});
        return singletonSlice(ctx.allocator, count_str);
    }

    // Handle $* (all arguments as separate words)
    if (std.mem.eql(u8, name, "*")) {
        const argv = ctx.state.getVarList("argv") orelse &[_][]const u8{};
        if (argv.len == 0) {
            return singletonSlice(ctx.allocator, "");
        }
        return argv;
    }

    // Handle positional parameters $1, $2, etc.
    if (name.len > 0 and name[0] >= '1' and name[0] <= '9') {
        const idx = std.fmt.parseInt(usize, name, 10) catch {
            // Not a valid number, fall through to env lookup
            return singletonSlice(ctx.allocator, std.posix.getenv(name) orelse "");
        };

        const argv = ctx.state.getVarList("argv") orelse &[_][]const u8{};
        // $1 is argv[0], $2 is argv[1], etc.
        if (idx > 0 and idx <= argv.len) {
            return singletonSlice(ctx.allocator, argv[idx - 1]);
        }
        return singletonSlice(ctx.allocator, "");
    }

    // Check environment, fall back to empty string
    return singletonSlice(ctx.allocator, std.posix.getenv(name) orelse "");
}

fn findMatchingParen(text: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start + 1;
    while (i < text.len) {
        if (text[i] == '(') {
            depth += 1;
        } else if (text[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

pub fn runCmdsub(ctx: *ExpandContext, cmd: []const u8) (ExpandError || std.mem.Allocator.Error)![]const u8 {
    if (ctx.mock_cmdsub) |mock| {
        if (mock.get(cmd)) |output| {
            return output;
        }
    }

    return interpreter_mod.executeAndCapture(ctx.allocator, ctx.state, cmd) catch {
        return ExpandError.CommandSubstitutionFailed;
    };
}

fn cartesian(allocator: std.mem.Allocator, left: []const []const u8, right: []const []const u8) std.mem.Allocator.Error!std.ArrayListUnmanaged([]const u8) {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;

    for (left) |l| {
        for (right) |r| {
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ l, r });
            try result.append(allocator, combined);
        }
    }

    return result;
}

pub fn expandWords(ctx: *ExpandContext, words: []const []const WordPart) (ExpandError || std.mem.Allocator.Error)![]const []const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;

    for (words) |word| {
        const expanded = try expandWord(ctx, word);
        for (expanded) |e| {
            try result.append(ctx.allocator, e);
        }
    }

    return try result.toOwnedSlice(ctx.allocator);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "simple bare word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const segs = [_]WordPart{.{ .quotes = .none, .text = "hello" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("hello", result[0]);
}

test "variable expansion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("a", result[0]);
    try testing.expectEqualStrings("b", result[1]);
}

test "tilde expansion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    state.home = "/home/user";

    const segs = [_]WordPart{.{ .quotes = .none, .text = "~/src" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("/home/user/src", result[0]);
}

test "single quotes preserve literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .single, .text = "$xs" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("$xs", result[0]);
}

test "double quoted escaped dollar is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const segs = [_]WordPart{.{ .quotes = .double, .text = "\\$HOME" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("$HOME", result[0]);
}

test "bare escaped dollar is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const segs = [_]WordPart{.{ .quotes = .none, .text = "\\$HOME" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("$HOME", result[0]);
}

test "cartesian product prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{ .{ .quotes = .none, .text = "pre" }, .{ .quotes = .none, .text = "$xs" } };
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("prea", result[0]);
    try testing.expectEqualStrings("preb", result[1]);
}

test "cartesian two lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const xs_values = [_][]const u8{ "a", "b" };
    const ys_values = [_][]const u8{ "1", "2" };
    try ctx.setVar("xs", &xs_values);
    try ctx.setVar("ys", &ys_values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs$ys" }};
    const result = try expandWord(&ctx, &segs);

    // a*{1,2} + b*{1,2} = a1, a2, b1, b2
    try testing.expectEqual(@as(usize, 4), result.len);
    try testing.expectEqualStrings("a1", result[0]);
    try testing.expectEqualStrings("a2", result[1]);
    try testing.expectEqualStrings("b1", result[2]);
    try testing.expectEqualStrings("b2", result[3]);
}

test "command substitution mock" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    try ctx.setMockCmdsub("whoami", "jon");

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$(whoami)" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("jon", result[0]);
}

test "glob mock" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const matches = [_][]const u8{ "src/main.zig", "src/util.zig" };
    try ctx.setMockGlob("src/*.zig", &matches);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "src/*.zig" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("src/main.zig", result[0]);
    try testing.expectEqualStrings("src/util.zig", result[1]);
}

test "positional parameter $1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const argv = [_][]const u8{ "foo", "bar", "baz" };
    try ctx.setVar("argv", &argv);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$1" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("foo", result[0]);
}

test "positional parameter $2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const argv = [_][]const u8{ "foo", "bar", "baz" };
    try ctx.setVar("argv", &argv);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$2" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("bar", result[0]);
}

test "positional parameter $# count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const argv = [_][]const u8{ "foo", "bar", "baz" };
    try ctx.setVar("argv", &argv);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$#" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("3", result[0]);
}

test "positional parameter $* all args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const argv = [_][]const u8{ "foo", "bar" };
    try ctx.setVar("argv", &argv);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$*" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("foo", result[0]);
    try testing.expectEqualStrings("bar", result[1]);
}

test "positional parameter out of range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const argv = [_][]const u8{"foo"};
    try ctx.setVar("argv", &argv);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$5" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("", result[0]);
}

// =============================================================================
// Array Indexing Tests
// =============================================================================

test "array index: single positive index [1]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[1]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("a", result[0]);
}

test "array index: single positive index [2]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[2]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("b", result[0]);
}

test "array index: negative index [-1] = last" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[-1]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("c", result[0]);
}

test "array index: negative index [-2] = second-to-last" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[-2]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("b", result[0]);
}

test "array index: out of bounds returns empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[10]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("", result[0]);
}

test "array index: range [1..2]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c", "d" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[1..2]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("a", result[0]);
    try testing.expectEqualStrings("b", result[1]);
}

test "array index: range [2..4]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c", "d", "e" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[2..4]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("b", result[0]);
    try testing.expectEqualStrings("c", result[1]);
    try testing.expectEqualStrings("d", result[2]);
}

test "array index: range [2..] from index to end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c", "d" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[2..]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("b", result[0]);
    try testing.expectEqualStrings("c", result[1]);
    try testing.expectEqualStrings("d", result[2]);
}

test "array index: range [..2] from start to index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c", "d" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[..2]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("a", result[0]);
    try testing.expectEqualStrings("b", result[1]);
}

test "array index: negative range [-2..-1]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c", "d" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[-2..-1]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("c", result[0]);
    try testing.expectEqualStrings("d", result[1]);
}

test "array index: with braced variable ${xs}[1]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "${xs}[2]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("b", result[0]);
}

test "array index: argv[1]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const argv = [_][]const u8{ "foo", "bar", "baz" };
    try ctx.setVar("argv", &argv);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$argv[1]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("foo", result[0]);
}

test "array index: zero index returns empty (1-based)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const values = [_][]const u8{ "a", "b", "c" };
    try ctx.setVar("xs", &values);

    const segs = [_]WordPart{.{ .quotes = .none, .text = "$xs[0]" }};
    const result = try expandWord(&ctx, &segs);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("", result[0]);
}
