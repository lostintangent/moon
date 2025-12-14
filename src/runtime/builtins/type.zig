//! type builtin - show how a command would be interpreted
const std = @import("std");
const builtins = @import("../builtins.zig");
const resolve = @import("../resolve.zig");

pub const builtin = builtins.Builtin{
    .name = "type",
    .run = run,
    .help = "type <name>... - Show how a command would be interpreted",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    if (cmd.argv.len < 2) {
        builtins.io.writeStderr("type: usage: type NAME...\n");
        return 1;
    }

    var status: u8 = 0;
    for (cmd.argv[1..]) |name| {
        if (!showType(state, name)) {
            status = 1;
        }
    }
    return status;
}

fn showType(state: *builtins.State, name: []const u8) bool {
    switch (resolve.resolve(state, name)) {
        .alias => |expansion| {
            builtins.io.printStdout("{s} is aliased to '{s}'\n", .{ name, expansion });
            return true;
        },
        .builtin => {
            builtins.io.printStdout("{s} is a builtin\n", .{name});
            return true;
        },
        .function => {
            builtins.io.printStdout("{s} is a function\n", .{name});
            return true;
        },
        .external => |path| {
            builtins.io.printStdout("{s} is {s}\n", .{ name, path });
            return true;
        },
        .not_found => {
            builtins.io.printError("type: {s}: not found\n", .{name});
            return false;
        },
    }
}
