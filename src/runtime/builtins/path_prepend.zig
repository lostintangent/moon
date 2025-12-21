//! path_prepend builtin - prepend paths to a variable with deduplication
//!
//! Prepends new paths to the front of a PATH-style variable,
//! automatically removing duplicates.

const std = @import("std");
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "path_prepend",
    .run = run,
    .help = "path_prepend VAR PATH... - Prepend paths to variable (deduplicates)",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const argv = cmd.argv;

    if (argv.len < 3) {
        builtins.io.writeStderr("path_prepend: usage: path_prepend VAR PATH...\n");
        return 1;
    }

    const var_name = argv[1];
    const new_paths = argv[2..];

    // Get current value (from exports or environment)
    const current = state.exports.get(var_name) orelse builtins.env.get(var_name) orelse "";

    // Build deduplicated path list: new paths first, then existing
    const new_value = buildPathList(state.allocator, new_paths, current) catch {
        return builtins.reportOOM("path_prepend");
    };

    // Store in exports and environment
    storeExport(state, var_name, new_value) catch return builtins.reportOOM("path_prepend");
    builtins.env.set(state.allocator, var_name, new_value) catch return builtins.reportOOM("path_prepend");

    return 0;
}

// =============================================================================
// Path Building
// =============================================================================

/// Build a colon-separated path list with deduplication.
fn buildPathList(
    allocator: std.mem.Allocator,
    new_paths: []const []const u8,
    current: []const u8,
) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    // Add new paths first, then existing paths (deduplicating)
    try appendPaths(allocator, &result, &seen, new_paths);
    try appendPaths(allocator, &result, &seen, &.{current});

    return result.toOwnedSlice(allocator);
}

/// Append paths to result list, skipping duplicates.
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

// =============================================================================
// Storage
// =============================================================================

/// Store an export in state, freeing any old entry.
fn storeExport(state: *builtins.State, name: []const u8, value: []const u8) !void {
    if (state.exports.fetchRemove(name)) |old| {
        state.freeStringEntry(old);
    }

    const key = try state.allocator.dupe(u8, name);
    errdefer state.allocator.free(key);

    // Note: value is already allocated by buildPathList, don't dupe
    try state.exports.put(key, value);
}
