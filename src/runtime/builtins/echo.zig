//! echo builtin - print arguments with escape sequence support
const std = @import("std");
const builtins = @import("../builtins.zig");
const ansi = @import("../../terminal/ansi.zig");

pub const builtin = builtins.Builtin{
    .name = "echo",
    .run = run,
    .help = "echo [-n] [args...] - Print arguments (-n: no newline, supports \\e for ESC)",
};

fn run(_: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    var args = cmd.argv[1..];
    var newline = true;

    // Check for -n flag
    if (args.len > 0 and std.mem.eql(u8, args[0], "-n")) {
        newline = false;
        args = args[1..];
    }

    for (args, 0..) |arg, i| {
        if (i > 0) builtins.io.writeStdout(" ");
        ansi.writeEscaped(arg);
    }

    if (newline) builtins.io.writeStdout("\n");

    return 0;
}
