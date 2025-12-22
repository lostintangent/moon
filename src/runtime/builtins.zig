//! Builtin command dispatcher
//!
//! Central registry for all shell builtin commands, with compile-time
//! optimized lookup and shared utilities for builtin implementations.

const std = @import("std");

// Re-export types commonly needed by builtin implementations
pub const State = @import("state.zig").State;
pub const ExpandedCmd = @import("../interpreter/expansion/expanded.zig").ExpandedCmd;
pub const io = @import("../terminal/io.zig");
pub const env = @import("env.zig");

/// Standard signature for all builtin commands
pub const BuiltinFn = *const fn (*State, ExpandedCmd) u8;

/// Builtin command definition
pub const Builtin = struct {
    name: []const u8,
    run: BuiltinFn,
    help: []const u8,
};

// Import individual builtin modules
const exit_builtin = @import("builtins/exit.zig");
const cd_builtin = @import("builtins/cd.zig");
const pwd_builtin = @import("builtins/pwd.zig");
const jobs_builtin = @import("builtins/jobs.zig");
const fg_builtin = @import("builtins/fg.zig");
const bg_builtin = @import("builtins/bg.zig");
const var_builtin = @import("builtins/var.zig");
const unset_builtin = @import("builtins/unset.zig");
const export_builtin = @import("builtins/export.zig");
pub const source_builtin = @import("builtins/source.zig");
const eval_builtin = @import("builtins/eval.zig");
const true_builtin = @import("builtins/true.zig");
const false_builtin = @import("builtins/false.zig");
const type_builtin = @import("builtins/type.zig");
const echo_builtin = @import("builtins/echo.zig");
const print_builtin = @import("builtins/print.zig");
const alias_builtin = @import("builtins/alias.zig");
const unalias_builtin = @import("builtins/unalias.zig");
const test_builtin = @import("builtins/test.zig");
const path_prepend_builtin = @import("builtins/path_prepend.zig");

/// All registered builtins - single source of truth
const all_builtins = [_]Builtin{
    exit_builtin.builtin,
    cd_builtin.builtin,
    pwd_builtin.builtin,
    jobs_builtin.builtin,
    fg_builtin.builtin,
    bg_builtin.builtin,
    var_builtin.builtin,
    var_builtin.set_builtin,
    unset_builtin.builtin,
    export_builtin.builtin,
    source_builtin.builtin,
    eval_builtin.builtin,
    true_builtin.builtin,
    false_builtin.builtin,
    type_builtin.builtin,
    echo_builtin.builtin,
    print_builtin.builtin,
    alias_builtin.builtin,
    unalias_builtin.builtin,
    test_builtin.builtin,
    test_builtin.bracket_builtin,
    path_prepend_builtin.builtin,
};

/// Compile-time map for O(1) builtin lookup (built from all_builtins)
const builtin_map = blk: {
    var entries: [all_builtins.len]struct { []const u8, Builtin } = undefined;
    for (all_builtins, 0..) |b, i| {
        entries[i] = .{ b.name, b };
    }
    break :blk std.StaticStringMap(Builtin).initComptime(entries);
};

/// Compile-time array of builtin names (for tab completion)
const builtin_names = blk: {
    var names: [all_builtins.len][]const u8 = undefined;
    for (all_builtins, 0..) |b, i| {
        names[i] = b.name;
    }
    break :blk names;
};

/// Get all builtin names (for tab completion)
pub fn getNames() []const []const u8 {
    return &builtin_names;
}

/// Try to run a builtin command. Returns null if not a builtin.
pub fn tryRun(st: *State, cmd: ExpandedCmd) ?u8 {
    if (cmd.argv.len == 0) return null;

    const name = cmd.argv[0];

    if (builtin_map.get(name)) |builtin| {
        // Check for -h or --help as first argument
        if (cmd.argv.len > 1) {
            const arg = cmd.argv[1];
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                io.writeStdout(builtin.help);
                io.writeStdout("\n");
                return 0;
            }
        }
        return builtin.run(st, cmd);
    }

    return null; // Not a builtin
}

/// Check if a command name is a builtin
pub fn isBuiltin(name: []const u8) bool {
    return builtin_map.has(name);
}

// =============================================================================
// Shared Utilities for Builtins
// =============================================================================

/// Join arguments with spaces into a single allocated string.
pub fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return "";
    if (args.len == 1) return allocator.dupe(u8, args[0]);

    // Calculate total size needed
    var total: usize = 0;
    for (args) |arg| total += arg.len;
    total += args.len - 1; // spaces between args

    const result = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        @memcpy(result[pos..][0..arg.len], arg);
        pos += arg.len;
        if (i < args.len - 1) {
            result[pos] = ' ';
            pos += 1;
        }
    }
    return result;
}

/// Report an out-of-memory error for a builtin command.
pub fn reportOOM(comptime cmd_name: []const u8) u8 {
    io.writeStderr(cmd_name ++ ": out of memory\n");
    return 1;
}
