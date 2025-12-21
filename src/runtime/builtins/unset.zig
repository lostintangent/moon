//! unset builtin - remove shell variables and environment variables
const builtins = @import("../builtins.zig");
const env = @import("../env.zig");

pub const builtin = builtins.Builtin{
    .name = "unset",
    .run = run,
    .help = "unset <name>... - Remove shell variables and environment variables",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const argv = cmd.argv;

    if (argv.len < 2) {
        builtins.io.printError("unset: usage: unset NAME...\n", .{});
        return 1;
    }

    // Unset each named variable (both shell var and environment)
    for (argv[1..]) |name| {
        state.unsetVar(name);
        // Also remove from environment (ignore errors - variable may not exist in env)
        env.unset(state.allocator, name) catch {};
    }

    return 0;
}
