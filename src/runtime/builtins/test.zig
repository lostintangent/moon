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

fn runBracket(_: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    // [ requires closing ]
    if (cmd.argv.len < 2) {
        builtins.io.printError("[: missing ']'\n", .{});
        return 2;
    }

    const last = cmd.argv[cmd.argv.len - 1];
    if (!std.mem.eql(u8, last, "]")) {
        builtins.io.printError("[: missing ']'\n", .{});
        return 2;
    }

    // Strip [ and ] from argv for evaluation
    // Create a slice without first and last elements
    if (cmd.argv.len == 2) {
        // Just "[ ]" - no expression, returns false
        return 1;
    }

    const args = cmd.argv[1 .. cmd.argv.len - 1];
    return evaluateExpr(args);
}

fn run(_: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    if (cmd.argv.len < 2) {
        // No expression = false
        return 1;
    }

    const args = cmd.argv[1..];
    return evaluateExpr(args);
}

/// Evaluate a test expression and return 0 (true) or 1 (false), or 2 on error
fn evaluateExpr(args: []const []const u8) u8 {
    if (args.len == 0) return 1; // Empty = false

    // Handle negation
    if (args.len >= 1 and std.mem.eql(u8, args[0], "!")) {
        if (args.len == 1) return 0; // "!" alone is true (negation of empty)
        const result = evaluateExpr(args[1..]);
        return if (result == 0) 1 else if (result == 1) 0 else result;
    }

    // Handle parentheses for grouping
    if (args.len >= 1 and std.mem.eql(u8, args[0], "(")) {
        // Find matching )
        var depth: usize = 1;
        var close_idx: ?usize = null;
        for (args[1..], 1..) |arg, i| {
            if (std.mem.eql(u8, arg, "(")) {
                depth += 1;
            } else if (std.mem.eql(u8, arg, ")")) {
                depth -= 1;
                if (depth == 0) {
                    close_idx = i;
                    break;
                }
            }
        }

        if (close_idx) |idx| {
            const inner_result = evaluateExpr(args[1..idx]);
            if (idx + 1 < args.len) {
                // More after the )
                return evaluateBinaryLogical(inner_result, args[idx + 1 ..]);
            }
            return inner_result;
        } else {
            builtins.io.printError("test: missing ')'\n", .{});
            return 2;
        }
    }

    // Single argument: string length test (true if non-empty)
    if (args.len == 1) {
        return if (args[0].len > 0) 0 else 1;
    }

    // Two arguments: unary operators
    if (args.len == 2) {
        return evalUnary(args[0], args[1]);
    }

    // Three+ arguments: check for binary operators
    if (args.len >= 3) {
        // Try binary operator at position 1
        const result = evalBinary(args[0], args[1], args[2]);
        if (result != null) {
            if (args.len == 3) {
                return result.?;
            }
            // More arguments - check for -a/-o
            return evaluateBinaryLogical(result.?, args[3..]);
        }

        // Not a binary expression, might be complex
        builtins.io.printError("test: too many arguments\n", .{});
        return 2;
    }

    return 1;
}

/// Handle -a (and) / -o (or) chaining
fn evaluateBinaryLogical(left_result: u8, remaining: []const []const u8) u8 {
    if (remaining.len == 0) return left_result;

    const op = remaining[0];
    if (std.mem.eql(u8, op, "-a")) {
        // AND: short-circuit if left is false
        if (left_result != 0) return 1;
        if (remaining.len < 2) {
            builtins.io.printError("test: argument expected after -a\n", .{});
            return 2;
        }
        return evaluateExpr(remaining[1..]);
    } else if (std.mem.eql(u8, op, "-o")) {
        // OR: short-circuit if left is true
        if (left_result == 0) return 0;
        if (remaining.len < 2) {
            builtins.io.printError("test: argument expected after -o\n", .{});
            return 2;
        }
        return evaluateExpr(remaining[1..]);
    }

    builtins.io.printError("test: unknown operator: {s}\n", .{op});
    return 2;
}

/// Evaluate unary operators: -e, -f, -d, -r, -w, -x, -s, -L, -z, -n
fn evalUnary(op: []const u8, arg: []const u8) u8 {
    if (op.len < 2 or op[0] != '-') {
        builtins.io.printError("test: {s}: unary operator expected\n", .{op});
        return 2;
    }

    return switch (op[1]) {
        // File existence and type tests
        'e' => fileExists(arg),
        'f' => isRegularFile(arg),
        'd' => isDirectory(arg),
        'L', 'h' => isSymlink(arg),
        's' => fileHasSize(arg),

        // File permission tests
        'r' => isReadable(arg),
        'w' => isWritable(arg),
        'x' => isExecutable(arg),

        // String tests
        'z' => if (arg.len == 0) 0 else 1, // true if empty
        'n' => if (arg.len > 0) 0 else 1, // true if non-empty

        else => blk: {
            builtins.io.printError("test: {s}: unknown operator\n", .{op});
            break :blk 2;
        },
    };
}

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

    return null; // Not a recognized binary operator
}

// =============================================================================
// File test helpers
// =============================================================================

fn fileExists(path: []const u8) u8 {
    _ = std.fs.cwd().statFile(path) catch return 1;
    return 0;
}

fn isRegularFile(path: []const u8) u8 {
    const stat = std.fs.cwd().statFile(path) catch return 1;
    return if (stat.kind == .file) 0 else 1;
}

fn isDirectory(path: []const u8) u8 {
    const stat = std.fs.cwd().statFile(path) catch return 1;
    return if (stat.kind == .directory) 0 else 1;
}

fn isSymlink(path: []const u8) u8 {
    // Use posix.readlink to check if path is a symlink (lstat equivalent)
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.posix.readlink(path, &buf) catch return 1;
    return 0;
}

fn fileHasSize(path: []const u8) u8 {
    const stat = std.fs.cwd().statFile(path) catch return 1;
    return if (stat.size > 0) 0 else 1;
}

fn isReadable(path: []const u8) u8 {
    const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch return 1;
    file.close();
    return 0;
}

fn isWritable(path: []const u8) u8 {
    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch return 1;
    file.close();
    return 0;
}

fn isExecutable(path: []const u8) u8 {
    const stat = std.fs.cwd().statFile(path) catch return 1;
    // Check if any execute bit is set
    const mode = stat.mode;
    const exec_bits = 0o111; // owner, group, other execute
    return if (mode & exec_bits != 0) 0 else 1;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn makeCmd(argv: []const []const u8) builtins.ExpandedCmd {
    return builtins.ExpandedCmd{
        .argv = argv,
        .env = &.{},
        .redirs = &.{},
    };
}

test "test: no args returns false" {
    const cmd = makeCmd(&[_][]const u8{"test"});
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd));
}

test "test: single non-empty string returns true" {
    const cmd = makeCmd(&[_][]const u8{ "test", "hello" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd));
}

test "test: -z empty string returns true" {
    const cmd = makeCmd(&[_][]const u8{ "test", "-z", "" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd));
}

test "test: -z non-empty returns false" {
    const cmd = makeCmd(&[_][]const u8{ "test", "-z", "hello" });
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd));
}

test "test: -n non-empty returns true" {
    const cmd = makeCmd(&[_][]const u8{ "test", "-n", "hello" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd));
}

test "test: string equality" {
    const cmd1 = makeCmd(&[_][]const u8{ "test", "foo", "=", "foo" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd1));

    const cmd2 = makeCmd(&[_][]const u8{ "test", "foo", "=", "bar" });
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd2));
}

test "test: string inequality" {
    const cmd = makeCmd(&[_][]const u8{ "test", "foo", "!=", "bar" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd));
}

test "test: numeric equality" {
    const cmd1 = makeCmd(&[_][]const u8{ "test", "42", "-eq", "42" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd1));

    const cmd2 = makeCmd(&[_][]const u8{ "test", "42", "-eq", "43" });
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd2));
}

test "test: numeric less than" {
    const cmd1 = makeCmd(&[_][]const u8{ "test", "5", "-lt", "10" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd1));

    const cmd2 = makeCmd(&[_][]const u8{ "test", "10", "-lt", "5" });
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd2));
}

test "test: numeric greater than" {
    const cmd = makeCmd(&[_][]const u8{ "test", "10", "-gt", "5" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd));
}

test "test: negation" {
    const cmd1 = makeCmd(&[_][]const u8{ "test", "!", "-z", "hello" });
    try testing.expectEqual(@as(u8, 0), run(undefined, cmd1)); // !false = true

    const cmd2 = makeCmd(&[_][]const u8{ "test", "!", "-n", "hello" });
    try testing.expectEqual(@as(u8, 1), run(undefined, cmd2)); // !true = false
}

test "[: requires closing bracket" {
    const cmd = makeCmd(&[_][]const u8{ "[", "-n", "hello" });
    try testing.expectEqual(@as(u8, 2), runBracket(undefined, cmd));
}

test "[: with closing bracket" {
    const cmd = makeCmd(&[_][]const u8{ "[", "-n", "hello", "]" });
    try testing.expectEqual(@as(u8, 0), runBracket(undefined, cmd));
}

test "test: -e on existing file" {
    // Test on a file we know exists
    const cmd = makeCmd(&[_][]const u8{ "test", "-e", "build.zig" });
    // This will work when run from the project root
    _ = run(undefined, cmd);
}
