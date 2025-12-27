//! increment builtin - increment or decrement a variable's value
//!
//! Provides a clean, ergonomic way to increment numeric variables without
//! needing nested math expressions and command substitution.
//!
//! Syntax:
//!   increment <varname>           - Increment variable by 1
//!   increment <varname> --by <n>  - Increment variable by n (can be negative)
//!
//! Examples:
//!   increment count              → count = count + 1
//!   increment count --by 5       → count = count + 5
//!   increment count --by -3      → count = count - 3

const std = @import("std");
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "increment",
    .run = run,
    .help = "increment <varname> [--by <n>] - Increment variable by n (default: 1)",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const argv = cmd.argv;

    if (argv.len < 2) {
        builtins.io.printError("increment: usage: increment <varname> [--by <n>]\n", .{});
        return 1;
    }

    const var_name = argv[1];
    const increment_by = parseIncrementAmount(argv[2..]) catch |err| {
        return reportParseError(err, argv);
    };

    const current_str = state.getVar(var_name) orelse {
        builtins.io.printError("increment: variable '{s}' does not exist\n", .{var_name});
        return 1;
    };

    const current_val = std.fmt.parseInt(i64, current_str, 10) catch {
        builtins.io.printError("increment: variable '{s}' is not a number (value: '{s}')\n", .{ var_name, current_str });
        return 1;
    };

    const new_val = std.math.add(i64, current_val, increment_by) catch {
        builtins.io.printError("increment: integer overflow\n", .{});
        return 1;
    };

    // Format the new value - i64 range is -9,223,372,036,854,775,808 to 9,223,372,036,854,775,807
    // which is at most 20 digits plus a minus sign, so 32 bytes is more than sufficient
    var buf: [32]u8 = undefined;
    const new_str = std.fmt.bufPrint(&buf, "{d}", .{new_val}) catch unreachable;

    // Set the new value - scope-based allocation handles performance
    state.setVar(var_name, new_str) catch {
        builtins.io.printError("increment: out of memory\n", .{});
        return 1;
    };

    return 0;
}

// =============================================================================
// Helper Functions
// =============================================================================

const ParseError = error{
    InvalidOption,
    MissingValue,
    InvalidNumber,
    TooManyArgs,
};

/// Parse the --by option and return the increment amount.
fn parseIncrementAmount(args: []const []const u8) ParseError!i64 {
    return switch (args.len) {
        0 => 1, // Default increment
        1 => if (std.mem.eql(u8, args[0], "--by")) error.MissingValue else error.InvalidOption,
        2 => blk: {
            if (!std.mem.eql(u8, args[0], "--by")) break :blk error.InvalidOption;
            break :blk std.fmt.parseInt(i64, args[1], 10) catch error.InvalidNumber;
        },
        else => error.TooManyArgs,
    };
}

fn reportParseError(err: ParseError, argv: []const []const u8) u8 {
    switch (err) {
        error.InvalidOption => builtins.io.printError("increment: invalid option '{s}' (expected --by)\n", .{argv[2]}),
        error.MissingValue => builtins.io.printError("increment: --by option requires a value\n", .{}),
        error.InvalidNumber => builtins.io.printError("increment: --by value '{s}' is not a valid number\n", .{argv[3]}),
        error.TooManyArgs => builtins.io.printError("increment: too many arguments\n", .{}),
    }
    return 1;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const test_utils = @import("testing.zig");
const State = @import("../state.zig").State;

fn testWithState(comptime f: fn (*State) anyerror!void) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    state.initCurrentScope();
    defer state.deinit();
    try f(&state);
}

fn runIncrement(state: *State, argv: []const []const u8) u8 {
    return run(state, test_utils.makeCmd(argv));
}

test "basic: increment by 1" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try state.setVar("count", "5");
            try testing.expectEqual(@as(u8, 0), runIncrement(state, &.{ "increment", "count" }));
            try testing.expectEqualStrings("6", state.getVar("count").?);
        }
    }.f);
}

test "basic: increment by custom amount" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try state.setVar("count", "10");
            try testing.expectEqual(@as(u8, 0), runIncrement(state, &.{ "increment", "count", "--by", "5" }));
            try testing.expectEqualStrings("15", state.getVar("count").?);
        }
    }.f);
}

test "basic: decrement with negative value" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try state.setVar("count", "10");
            try testing.expectEqual(@as(u8, 0), runIncrement(state, &.{ "increment", "count", "--by", "-3" }));
            try testing.expectEqualStrings("7", state.getVar("count").?);
        }
    }.f);
}

test "basic: increment from zero" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try state.setVar("count", "0");
            try testing.expectEqual(@as(u8, 0), runIncrement(state, &.{ "increment", "count" }));
            try testing.expectEqualStrings("1", state.getVar("count").?);
        }
    }.f);
}

test "basic: increment negative number" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try state.setVar("count", "-5");
            try testing.expectEqual(@as(u8, 0), runIncrement(state, &.{ "increment", "count" }));
            try testing.expectEqualStrings("-4", state.getVar("count").?);
        }
    }.f);
}

test "error: nonexistent variable" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try testing.expectEqual(@as(u8, 1), runIncrement(state, &.{ "increment", "nonexistent" }));
        }
    }.f);
}

test "error: non-numeric variable" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try state.setVar("text", "hello");
            try testing.expectEqual(@as(u8, 1), runIncrement(state, &.{ "increment", "text" }));
        }
    }.f);
}

test "error: invalid --by value" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try state.setVar("count", "5");
            try testing.expectEqual(@as(u8, 1), runIncrement(state, &.{ "increment", "count", "--by", "abc" }));
        }
    }.f);
}

test "error: missing --by value" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try state.setVar("count", "5");
            try testing.expectEqual(@as(u8, 1), runIncrement(state, &.{ "increment", "count", "--by" }));
        }
    }.f);
}

test "error: too many arguments" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try state.setVar("count", "5");
            try testing.expectEqual(@as(u8, 1), runIncrement(state, &.{ "increment", "count", "--by", "1", "extra" }));
        }
    }.f);
}

test "error: invalid option" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try state.setVar("count", "5");
            try testing.expectEqual(@as(u8, 1), runIncrement(state, &.{ "increment", "count", "--invalid", "1" }));
        }
    }.f);
}

test "error: missing variable name" {
    try testWithState(struct {
        fn f(state: *State) !void {
            try testing.expectEqual(@as(u8, 1), runIncrement(state, &.{"increment"}));
        }
    }.f);
}
