//! path_prepend builtin - prepend paths to a variable with deduplication
const std = @import("std");
const builtins = @import("../builtins.zig");

// C setenv function
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const builtin = builtins.Builtin{
    .name = "path_prepend",
    .run = run,
    .help = "path_prepend VAR path... - Prepend paths to a variable (deduplicates)",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const argv = cmd.argv;

    if (argv.len < 3) {
        builtins.io.writeStderr("path_prepend: usage: path_prepend VAR path...\n");
        return 1;
    }

    const var_name = argv[1];
    const new_paths = argv[2..];

    // Get current value (from exports or environment)
    const current = state.exports.get(var_name) orelse std.posix.getenv(var_name) orelse "";

    // Build new path list: new_paths first, then existing (minus duplicates)
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(state.allocator);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(state.allocator);

    // Add new paths first, then existing paths (deduplicating)
    appendPaths(state.allocator, &result, &seen, new_paths) catch return oomError();
    appendPaths(state.allocator, &result, &seen, &.{current}) catch return oomError();

    const new_value = result.toOwnedSlice(state.allocator) catch return oomError();

    // Store in exports map (free old entry if present)
    if (state.exports.fetchRemove(var_name)) |old| {
        state.allocator.free(old.key);
        state.allocator.free(old.value);
    }

    const key_copy = state.allocator.dupe(u8, var_name) catch return oomError();
    state.exports.put(key_copy, new_value) catch return oomError();

    // Set in actual environment
    const name_z = state.allocator.dupeZ(u8, var_name) catch return oomError();
    defer state.allocator.free(name_z);
    const value_z = state.allocator.dupeZ(u8, new_value) catch return oomError();
    defer state.allocator.free(value_z);
    _ = setenv(name_z, value_z, 1);

    return 0;
}

fn appendPaths(
    allocator: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(u8),
    seen: *std.StringHashMapUnmanaged(void),
    paths: []const []const u8,
) !void {
    for (paths) |path_or_list| {
        var iter = std.mem.splitScalar(u8, path_or_list, ':');
        while (iter.next()) |path| {
            if (path.len == 0) continue;
            if (seen.contains(path)) continue;

            try seen.put(allocator, path, {});
            if (result.items.len > 0) try result.append(allocator, ':');
            try result.appendSlice(allocator, path);
        }
    }
}

fn oomError() u8 {
    builtins.io.writeStderr("path_prepend: out of memory\n");
    return 1;
}
