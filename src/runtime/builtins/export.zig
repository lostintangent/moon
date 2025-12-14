//! export builtin - export environment variables
const std = @import("std");
const builtins = @import("../builtins.zig");

// C setenv function
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const builtin = builtins.Builtin{
    .name = "export",
    .run = run,
    .help = "export [name [value]] | [name=value] - Export environment variables",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const argv = cmd.argv;

    // export with no args: list all exports
    if (argv.len == 1) {
        var iter = state.exports.iterator();
        while (iter.next()) |entry| {
            builtins.io.printStdout("export {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }

    // Check if first arg contains '=' (export foo=bar syntax)
    if (std.mem.indexOfScalar(u8, argv[1], '=') != null) {
        // Process each argument as name=value
        for (argv[1..]) |arg| {
            const result = exportVar(state, arg, null);
            if (result != 0) return result;
        }
    } else {
        // export name value syntax (2 args) or export name (1 arg to export existing)
        if (argv.len == 2) {
            // Just name: export existing variable
            return exportVar(state, argv[1], null);
        } else if (argv.len == 3) {
            // name value: export with separate value
            return exportVar(state, argv[1], argv[2]);
        } else {
            builtins.io.writeStderr("export: too many arguments\n");
            return 1;
        }
    }

    return 0;
}

fn exportVar(state: *builtins.State, arg: []const u8, separate_value: ?[]const u8) u8 {
    // Parse NAME=VALUE or just NAME
    const eq_pos = std.mem.indexOfScalar(u8, arg, '=');
    const name = if (eq_pos) |pos| arg[0..pos] else arg;
    const value = if (separate_value) |v| v else if (eq_pos) |pos| arg[pos + 1 ..] else blk: {
        // Just NAME: get existing value
        if (state.getVar(name)) |v| break :blk v;
        if (std.posix.getenv(name)) |v| break :blk v;
        builtins.io.printError("export: {s}: not set\n", .{name});
        return 1;
    };

    // Store in exports map (freeing old entry if exists)
    if (state.exports.fetchRemove(name)) |old| {
        state.allocator.free(old.key);
        state.allocator.free(old.value);
    }

    const key_copy = state.allocator.dupe(u8, name) catch return oomError();
    const val_copy = state.allocator.dupe(u8, value) catch return oomError();
    state.exports.put(key_copy, val_copy) catch return oomError();

    // Set in actual environment
    const name_z = state.allocator.dupeZ(u8, name) catch return oomError();
    defer state.allocator.free(name_z);
    const value_z = state.allocator.dupeZ(u8, value) catch return oomError();
    defer state.allocator.free(value_z);
    _ = setenv(name_z, value_z, 1);

    return 0;
}

fn oomError() u8 {
    builtins.io.writeStderr("export: out of memory\n");
    return 1;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const State = @import("../state.zig").State;
const expansion_types = @import("../../interpreter/expansion/types.zig");

fn makeCmd(argv: []const []const u8) builtins.ExpandedCmd {
    return builtins.ExpandedCmd{
        .argv = argv,
        .env = &.{},
        .redirs = &.{},
    };
}

test "export: NAME=VALUE syntax" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();

    const cmd = makeCmd(&[_][]const u8{ "export", "OSHEN_TEST_VAR=testvalue" });
    const result = run(&state, cmd);
    try testing.expectEqual(@as(u8, 0), result);

    // Verify it's in the exports map
    const exported = state.exports.get("OSHEN_TEST_VAR");
    try testing.expect(exported != null);
    try testing.expectEqualStrings("testvalue", exported.?);

    // Verify it's in the environment
    const env_value = std.posix.getenv("OSHEN_TEST_VAR");
    try testing.expect(env_value != null);
    try testing.expectEqualStrings("testvalue", env_value.?);
}

test "export: existing shell variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();

    // First set a shell variable
    try state.setVar("OSHEN_SHELLVAR", "shellvalue");

    // Now export it
    const cmd = makeCmd(&[_][]const u8{ "export", "OSHEN_SHELLVAR" });
    const result = run(&state, cmd);
    try testing.expectEqual(@as(u8, 0), result);

    // Verify it's in the environment
    const env_value = std.posix.getenv("OSHEN_SHELLVAR");
    try testing.expect(env_value != null);
    try testing.expectEqualStrings("shellvalue", env_value.?);
}

test "export: nonexistent variable fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();

    const cmd = makeCmd(&[_][]const u8{ "export", "OSHEN_NONEXISTENT_67890" });
    const result = run(&state, cmd);
    try testing.expectEqual(@as(u8, 1), result);
}

test "export: space-separated NAME VALUE syntax" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();

    const cmd = makeCmd(&[_][]const u8{ "export", "OSHEN_SPACE_VAR", "spacevalue" });
    const result = run(&state, cmd);
    try testing.expectEqual(@as(u8, 0), result);

    // Verify it's in the exports map
    const exported = state.exports.get("OSHEN_SPACE_VAR");
    try testing.expect(exported != null);
    try testing.expectEqualStrings("spacevalue", exported.?);

    // Verify it's in the environment
    const env_value = std.posix.getenv("OSHEN_SPACE_VAR");
    try testing.expect(env_value != null);
    try testing.expectEqualStrings("spacevalue", env_value.?);
}

test "export: too many arguments fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();

    const cmd = makeCmd(&[_][]const u8{ "export", "OSHEN_TOO_MANY", "value", "extra" });
    const result = run(&state, cmd);
    try testing.expectEqual(@as(u8, 1), result);
}

test "export: multiple NAME=VALUE pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();

    const cmd = makeCmd(&[_][]const u8{ "export", "OSHEN_MULTI_A=aval", "OSHEN_MULTI_B=bval" });
    const result = run(&state, cmd);
    try testing.expectEqual(@as(u8, 0), result);

    // Verify both are in the environment
    const env_a = std.posix.getenv("OSHEN_MULTI_A");
    try testing.expect(env_a != null);
    try testing.expectEqualStrings("aval", env_a.?);

    const env_b = std.posix.getenv("OSHEN_MULTI_B");
    try testing.expect(env_b != null);
    try testing.expectEqualStrings("bval", env_b.?);
}
