//! eval builtin - execute a string as shell code
const std = @import("std");
const builtins = @import("../builtins.zig");
const interpreter = @import("../../interpreter/interpreter.zig");

pub const builtin = builtins.Builtin{
    .name = "eval",
    .run = run,
    .help = "Execute arguments as shell code: eval CODE...",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    if (cmd.argv.len < 2) {
        // eval with no args succeeds (like bash)
        return 0;
    }

    // Join all arguments into a single string
    var total_len: usize = 0;
    for (cmd.argv[1..]) |arg| {
        total_len += arg.len + 1; // +1 for space
    }

    const code = state.allocator.alloc(u8, total_len) catch {
        builtins.io.writeStderr("eval: out of memory\n");
        return 1;
    };
    defer state.allocator.free(code);

    var pos: usize = 0;
    for (cmd.argv[1..], 0..) |arg, i| {
        @memcpy(code[pos..][0..arg.len], arg);
        pos += arg.len;
        if (i < cmd.argv.len - 2) {
            code[pos] = ' ';
            pos += 1;
        }
    }

    return interpreter.execute(state.allocator, state, code[0..pos]) catch |err| {
        builtins.io.printError("eval: {}\n", .{err});
        return 1;
    };
}
