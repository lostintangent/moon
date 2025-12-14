//! unalias builtin - remove command aliases
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "unalias",
    .run = run,
    .help = "unalias name... - Remove aliases",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const argv = cmd.argv;

    if (argv.len < 2) {
        builtins.io.printError("unalias: usage: unalias name...\n", .{});
        return 1;
    }

    // Unset each named alias (silently ignore missing, like unset)
    for (argv[1..]) |name| {
        state.unsetAlias(name);
    }

    return 0;
}
