const std = @import("std");
const builtins = @import("../builtins.zig");
const tui = @import("../../terminal/tui.zig");

pub const builtin = builtins.Builtin{
    .name = "cd",
    .help = "cd [dir] - Change current directory (defaults to $HOME)",
    .run = run,
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    // Determine target directory
    const target = if (cmd.argv.len < 2) state.home orelse {
        builtins.io.writeStderr("cd: HOME not set\n");
        return 1;
    } else if (std.mem.eql(u8, cmd.argv[1], "-")) state.prev_cwd orelse {
        builtins.io.writeStderr("cd: OLDPWD not set\n");
        return 1;
    } else cmd.argv[1];

    state.chdir(target) catch |err| {
        builtins.io.printError("cd: {s}: {}\n", .{ target, err });
        return 1;
    };

    // Emit OSC 7 to notify terminal of new working directory (only in interactive mode)
    if (state.interactive) {
        if (state.getCwd() catch null) |cwd| {
            tui.emitOsc7(cwd);
        }
    }

    return 0;
}
