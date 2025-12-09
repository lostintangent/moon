//! alias builtin - define command aliases
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "alias",
    .run = run,
    .help = "alias [name [expansion]] - Define or list aliases",
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

    // alias NAME EXPANSION: define alias
    // Join all remaining args as the expansion (allows: alias ll ls -la)
    const name = argv[1];
    const expansion_parts = argv[2..];

    // Join arguments with spaces
    const expansion = @import("std").mem.join(state.allocator, " ", expansion_parts) catch {
        builtins.io.printError("alias: allocation failed\n", .{});
        return 1;
    };
    defer state.allocator.free(expansion);

    state.setAlias(name, expansion) catch |err| {
        builtins.io.printError("alias: {}\n", .{err});
        return 1;
    };

    return 0;
}
