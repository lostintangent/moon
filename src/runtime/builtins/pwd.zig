const std = @import("std");
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "pwd",
    .help = "pwd [-t] - Print current working directory (-t: replace $HOME with ~)",
    .run = run,
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    var use_tilde = false;

    // argv[0] is "pwd", so skip it
    for (cmd.argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tilde")) {
            use_tilde = true;
        } else {
            builtins.io.printError("pwd: unknown option: {s}\n", .{arg});
            return 1;
        }
    }

    const cwd = state.getCwd() catch |err| {
        builtins.io.printError("pwd: {}\n", .{err});
        return 1;
    };

    if (use_tilde) {
        if (std.posix.getenv("HOME")) |home| {
            if (std.mem.startsWith(u8, cwd, home)) {
                builtins.io.writeStdout("~");
                builtins.io.writeStdout(cwd[home.len..]);
                builtins.io.writeStdout("\n");
                return 0;
            }
        }
    }

    builtins.io.writeStdout(cwd);
    builtins.io.writeStdout("\n");
    return 0;
}
