//! eval builtin - execute a string as shell code

const builtins = @import("../builtins.zig");
const interpreter = @import("../../interpreter/interpreter.zig");

pub const builtin = builtins.Builtin{
    .name = "eval",
    .run = run,
    .help = "eval CODE... - Execute arguments as shell code",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    if (cmd.argv.len < 2) {
        // eval with no args succeeds (like bash)
        return 0;
    }

    const code = builtins.joinArgs(state.allocator, cmd.argv[1..]) catch {
        return builtins.reportOOM("eval");
    };
    defer state.allocator.free(code);

    return interpreter.execute(state.allocator, state, code) catch |err| {
        builtins.io.printError("eval: {}\n", .{err});
        return 1;
    };
}
