const std = @import("std");
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "exit",
    .help = "exit [code] - Exit the shell with optional status code",
    .run = run,
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    var code: u8 = 0;
    if (cmd.argv.len > 1) {
        code = std.fmt.parseInt(u8, cmd.argv[1], 10) catch 1;
    }
    // Signal the shell to exit gracefully (allows cleanup like saving history)
    state.should_exit = true;
    state.exit_code = code;
    return code;
}
