//! alias builtin - define command aliases
//!
//! Supports:
//!   alias             - List all aliases
//!   alias NAME        - Show specific alias
//!   alias NAME WORDS  - Define alias (words joined with spaces)

const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "alias",
    .run = run,
    .help = "alias [NAME [EXPANSION...]] - Define or list aliases",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const argv = cmd.argv;

    // alias with no args: list all aliases
    if (argv.len == 1) {
        var iter = state.aliases.iterator();
        while (iter.next()) |entry| {
            builtins.io.printStdout("alias {s} '{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }

    // alias NAME: show single alias
    if (argv.len == 2) {
        if (state.getAlias(argv[1])) |expansion| {
            builtins.io.printStdout("alias {s} '{s}'\n", .{ argv[1], expansion });
            return 0;
        }
        builtins.io.printError("alias: {s}: not found\n", .{argv[1]});
        return 1;
    }

    // alias NAME EXPANSION...: define alias
    const name = argv[1];
    const expansion = builtins.joinArgs(state.allocator, argv[2..]) catch {
        return builtins.reportOOM("alias");
    };
    defer state.allocator.free(expansion);

    state.setAlias(name, expansion) catch {
        return builtins.reportOOM("alias");
    };

    return 0;
}
