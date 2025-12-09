//! unset builtin - remove shell variables
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "unset",
    .run = run,
    .help = "unset <name>... - Remove shell variables",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const argv = cmd.argv;

    if (argv.len < 2) {
        builtins.io.printError("unset: usage: unset NAME...\n", .{});
        return 1;
    }

    // Unset each named variable
    for (argv[1..]) |name| {
        state.unsetVar(name);
    }

    return 0;
}
