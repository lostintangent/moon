//! test/[ builtin - evaluate conditional expressions
//!
//! Supports:
//!   File tests: -e, -f, -d, -r, -w, -x, -s, -L
//!   String tests: -z, -n, =, !=
//!   Numeric tests: -eq, -ne, -lt, -le, -gt, -ge
//!   Logical: !, -a, -o, (, )
//!
//! Usage:
//!   test EXPRESSION
//!   [ EXPRESSION ]

const std = @import("std");
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "test",
    .run = run,
    .help = "test EXPR - Evaluate conditional expression",
};

pub const bracket_builtin = builtins.Builtin{
    .name = "[",
    .run = runBracket,
    .help = "[ EXPR ] - Evaluate conditional expression (alias for test)",
};

// =============================================================================
// Entry Points
// =============================================================================

fn runBracket(_: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    if (cmd.argv.len < 2) {
        builtins.io.printError("[: missing ']'\n", .{});
        return 2;
    }

    const last = cmd.argv[cmd.argv.len - 1];
    if (!std.mem.eql(u8, last, "]")) {
        builtins.io.printError("[: missing ']'\n", .{});
        return 2;
    }

    // Just "[ ]" - no expression, returns false
    if (cmd.argv.len == 2) return 1;

    return evaluateExpr(cmd.argv[1 .. cmd.argv.len - 1]);
}

fn run(_: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    if (cmd.argv.len < 2) return 1; // No expression = false
    return evaluateExpr(cmd.argv[1..]);
}

// =============================================================================
// Expression Evaluation
// =============================================================================

/// Evaluate a test expression. Returns 0 (true), 1 (false), or 2 (error).
fn evaluateExpr(args: []const []const u8) u8 {
    if (args.len == 0) return 1;

    // Handle negation: ! EXPR
    if (std.mem.eql(u8, args[0], "!")) {
        if (args.len == 1) return 0; // "!" alone is true (negation of empty)
        return negateResult(evaluateExpr(args[1..]));
    }

    // Handle parentheses: ( EXPR )
    if (std.mem.eql(u8, args[0], "(")) {
        return evaluateParenExpr(args);
    }

    // Dispatch by argument count
    return switch (args.len) {
        1 => if (args[0].len > 0) 0 else 1, // Non-empty string = true
        2 => evalUnary(args[0], args[1]),
        else => evaluateMultiArg(args),
    };
}

/// Negate a result: 0 <-> 1, preserve 2 (error).
fn negateResult(result: u8) u8 {
    return if (result == 0) 1 else if (result == 1) 0 else result;
}

/// Evaluate parenthesized expression: ( EXPR ) [OP EXPR...]
fn evaluateParenExpr(args: []const []const u8) u8 {
    const close_idx = findMatchingParen(args) orelse {
        builtins.io.printError("test: missing ')'\n", .{});
        return 2;
    };

    const inner_result = evaluateExpr(args[1..close_idx]);

    // Check for chained logical operators after )
    if (close_idx + 1 < args.len) {
        return evaluateBinaryLogical(inner_result, args[close_idx + 1 ..]);
    }
    return inner_result;
}

/// Find the index of the matching closing paren.
fn findMatchingParen(args: []const []const u8) ?usize {
    var depth: usize = 1;
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "(")) {
            depth += 1;
        } else if (std.mem.eql(u8, arg, ")")) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Evaluate 3+ argument expressions (binary operators or chained).
fn evaluateMultiArg(args: []const []const u8) u8 {
    if (args.len >= 3) {
        if (evalBinary(args[0], args[1], args[2])) |result| {
            if (args.len == 3) return result;
            return evaluateBinaryLogical(result, args[3..]);
        }
    }

    if (args.len >= 2) {
        const unary_result = evalUnary(args[0], args[1]);
        if (unary_result == 2) return 2;
        if (args.len == 2) return unary_result;
        return evaluateBinaryLogical(unary_result, args[2..]);
    }

    builtins.io.printError("test: too many arguments\n", .{});
    return 2;
}

/// Handle -a (and) / -o (or) chaining.
fn evaluateBinaryLogical(left_result: u8, remaining: []const []const u8) u8 {
    if (remaining.len == 0) return left_result;

    const op = remaining[0];

    if (std.mem.eql(u8, op, "-a")) {
        if (left_result != 0) return 1; // Short-circuit: false AND x = false
        if (remaining.len < 2) {
            builtins.io.printError("test: argument expected after -a\n", .{});
            return 2;
        }
        return evaluateExpr(remaining[1..]);
    }

    if (std.mem.eql(u8, op, "-o")) {
        if (left_result == 0) return 0; // Short-circuit: true OR x = true
        if (remaining.len < 2) {
            builtins.io.printError("test: argument expected after -o\n", .{});
            return 2;
        }
        return evaluateExpr(remaining[1..]);
    }

    builtins.io.printError("test: unknown operator: {s}\n", .{op});
    return 2;
}

// =============================================================================
// Unary Operators
// =============================================================================

/// Evaluate unary operators: -e, -f, -d, -r, -w, -x, -s, -L, -z, -n
fn evalUnary(op: []const u8, arg: []const u8) u8 {
    if (op.len < 2 or op[0] != '-') {
        builtins.io.printError("test: {s}: unary operator expected\n", .{op});
        return 2;
    }

    return switch (op[1]) {
        // File tests
        'e' => testFileStat(arg, null), // exists
        'f' => testFileStat(arg, .file), // regular file
        'd' => testFileStat(arg, .directory), // directory
        'L', 'h' => testSymlink(arg), // symlink
        's' => testFileHasSize(arg), // non-empty file

        // Permission tests
        'r' => testFileAccess(arg, .read_only),
        'w' => testFileAccess(arg, .write_only),
        'x' => testExecutable(arg),

        // String tests
        'z' => if (arg.len == 0) 0 else 1, // true if empty
        'n' => if (arg.len > 0) 0 else 1, // true if non-empty

        else => blk: {
            builtins.io.printError("test: {s}: unknown operator\n", .{op});
            break :blk 2;
        },
    };
}

// =============================================================================
// Binary Operators
// =============================================================================

/// Evaluate binary operators: =, ==, !=, -eq, -ne, -lt, -le, -gt, -ge
fn evalBinary(left: []const u8, op: []const u8, right: []const u8) ?u8 {
    // String comparisons
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
        return if (std.mem.eql(u8, left, right)) 0 else 1;
    }
    if (std.mem.eql(u8, op, "!=")) {
        return if (!std.mem.eql(u8, left, right)) 0 else 1;
    }

    // Numeric comparisons (all start with -)
    if (op.len < 2 or op[0] != '-') return null;

    const left_num = std.fmt.parseInt(i64, left, 10) catch {
        builtins.io.printError("test: {s}: integer expression expected\n", .{left});
        return 2;
    };
    const right_num = std.fmt.parseInt(i64, right, 10) catch {
        builtins.io.printError("test: {s}: integer expression expected\n", .{right});
        return 2;
    };

    const cmp = op[1..];
    if (std.mem.eql(u8, cmp, "eq")) return if (left_num == right_num) 0 else 1;
    if (std.mem.eql(u8, cmp, "ne")) return if (left_num != right_num) 0 else 1;
    if (std.mem.eql(u8, cmp, "lt")) return if (left_num < right_num) 0 else 1;
    if (std.mem.eql(u8, cmp, "le")) return if (left_num <= right_num) 0 else 1;
    if (std.mem.eql(u8, cmp, "gt")) return if (left_num > right_num) 0 else 1;
    if (std.mem.eql(u8, cmp, "ge")) return if (left_num >= right_num) 0 else 1;

    return null;
}

// =============================================================================
// File Test Helpers
// =============================================================================

/// Test file stat with optional kind check.
fn testFileStat(path: []const u8, kind: ?std.fs.File.Kind) u8 {
    const stat = std.fs.cwd().statFile(path) catch return 1;
    if (kind) |k| {
        return if (stat.kind == k) 0 else 1;
    }
    return 0;
}

/// Test if path is a symlink.
fn testSymlink(path: []const u8) u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.posix.readlink(path, &buf) catch return 1;
    return 0;
}

/// Test if file has non-zero size.
fn testFileHasSize(path: []const u8) u8 {
    const stat = std.fs.cwd().statFile(path) catch return 1;
    return if (stat.size > 0) 0 else 1;
}

/// Test file access mode (read/write).
fn testFileAccess(path: []const u8, mode: std.fs.File.OpenMode) u8 {
    const file = std.fs.cwd().openFile(path, .{ .mode = mode }) catch return 1;
    file.close();
    return 0;
}

/// Test if file is executable (any execute bit set).
fn testExecutable(path: []const u8) u8 {
    const stat = std.fs.cwd().statFile(path) catch return 1;
    const exec_bits = 0o111; // owner, group, other execute
    return if (stat.mode & exec_bits != 0) 0 else 1;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const test_utils = @import("testing.zig");

test "test: no args returns false" {
    const cmd = test_utils.makeCmd(&[_][]const u8{"test"});
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd));
}

test "test: single non-empty string returns true" {
    const cmd = test_utils.makeCmd(&[_][]const u8{ "test", "hello" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd));
}

test "test: -z empty string returns true" {
    const cmd = test_utils.makeCmd(&[_][]const u8{ "test", "-z", "" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd));
}

test "test: -z non-empty returns false" {
    const cmd = test_utils.makeCmd(&[_][]const u8{ "test", "-z", "hello" });
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd));
}

test "test: -n non-empty returns true" {
    const cmd = test_utils.makeCmd(&[_][]const u8{ "test", "-n", "hello" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd));
}

test "test: string equality" {
    const cmd1 = test_utils.makeCmd(&[_][]const u8{ "test", "foo", "=", "foo" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd1));

    const cmd2 = test_utils.makeCmd(&[_][]const u8{ "test", "foo", "=", "bar" });
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd2));
}

test "test: string inequality" {
    const cmd = test_utils.makeCmd(&[_][]const u8{ "test", "foo", "!=", "bar" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd));
}

test "test: numeric equality" {
    const cmd1 = test_utils.makeCmd(&[_][]const u8{ "test", "42", "-eq", "42" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd1));

    const cmd2 = test_utils.makeCmd(&[_][]const u8{ "test", "42", "-eq", "43" });
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd2));
}

test "test: numeric less than" {
    const cmd1 = test_utils.makeCmd(&[_][]const u8{ "test", "5", "-lt", "10" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd1));

    const cmd2 = test_utils.makeCmd(&[_][]const u8{ "test", "10", "-lt", "5" });
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd2));
}

test "test: numeric greater than" {
    const cmd = test_utils.makeCmd(&[_][]const u8{ "test", "10", "-gt", "5" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd));
}

test "test: negation" {
    const cmd1 = test_utils.makeCmd(&[_][]const u8{ "test", "!", "-z", "hello" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd1)); // !false = true

    const cmd2 = test_utils.makeCmd(&[_][]const u8{ "test", "!", "-n", "hello" });
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd2)); // !true = false
}

test "[: requires closing bracket" {
    const cmd = test_utils.makeCmd(&[_][]const u8{ "[", "-n", "hello" });
    try testing.expectEqual(@as(u8, 2), runBracket(undefined, cmd));
}

test "[: with closing bracket" {
    const cmd = test_utils.makeCmd(&[_][]const u8{ "[", "-n", "hello", "]" });
    try testing.expectEqual(@as(u8, 0), runBracket(undefined, cmd));
}

test "test: -e on existing file" {
    const cmd = test_utils.makeCmd(&[_][]const u8{ "test", "-e", "build.zig" });
    _ = run(undefined, cmd);
}
