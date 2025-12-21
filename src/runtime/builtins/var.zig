//! var/set builtin - get or set shell variables
const std = @import("std");
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "var",
    .run = run,
    .help = "var [name [values...]] - Get or set shell variables",
};

pub const set_builtin = builtins.Builtin{
    .name = "set",
    .run = run,
    .help = "set [name [values...]] - Get or set shell variables (alias for var)",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const argv = cmd.argv;

    // set with no args: list all variables
    if (argv.len == 1) {
        var iter = state.vars.iterator();
        while (iter.next()) |entry| {
            builtins.io.printStdout("{s} = ", .{entry.key_ptr.*});
            const values = entry.value_ptr.*;
            for (values, 0..) |v, i| {
                if (i > 0) builtins.io.writeStdout(" ");
                builtins.io.printStdout("{s}", .{v});
            }
            builtins.io.writeStdout("\n");
        }
        return 0;
    }

    // set NAME: show single variable
    if (argv.len == 2) {
        if (state.vars.get(argv[1])) |values| {
            for (values, 0..) |v, i| {
                if (i > 0) builtins.io.writeStdout(" ");
                builtins.io.printStdout("{s}", .{v});
            }
            builtins.io.writeStdout("\n");
            return 0;
        } else if (builtins.env.get(argv[1])) |env_val| {
            builtins.io.printStdout("{s}\n", .{env_val});
            return 0;
        }
        return 1; // Variable not found
    }

    // set NAME VALUE...: set variable
    const name = argv[1];
    const values = argv[2..];

    state.setVarList(name, values) catch |err| {
        builtins.io.printError("set: {}\n", .{err});
        return 1;
    };

    return 0;
}
