const std = @import("std");
const builtins = @import("../builtins.zig");
const tui = @import("../../terminal/tui.zig");

pub const builtin = builtins.Builtin{
    .name = "cd",
    .help = "cd [dir] - Change current directory (defaults to $HOME)",
    .run = run,
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const target = if (cmd.argv.len > 1)
        cmd.argv[1]
    else
        state.home orelse {
            builtins.io.writeStderr("cd: HOME not set\n");
            return 1;
        };

    state.chdir(target) catch |err| {
        builtins.io.printError("cd: {s}: {}\n", .{ target, err });
        return 1;
    };

    // Emit OSC 7 to notify terminal of new working directory
    if (state.getCwd()) |cwd| {
        tui.emitOsc7(cwd);
    } else |_| {}

    return 0;
}
