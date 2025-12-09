//! echo builtin - print arguments with escape sequence support
const std = @import("std");
const builtins = @import("../builtins.zig");

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
        writeEscaped(arg);
    }

    if (newline) builtins.io.writeStdout("\n");

    return 0;
}

/// Write a string, interpreting \e and octal escapes (other escapes handled by expansion)
fn writeEscaped(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'e' => {
                    builtins.io.writeStdout("\x1b");
                    i += 2;
                },
                '0' => {
                    // Octal escape: \0, \033, etc.
                    const octal = parseOctal(s[i + 1 ..]);
                    if (octal.len > 0) {
                        const byte = [1]u8{octal.value};
                        builtins.io.writeStdout(&byte);
                        i += 1 + octal.len;
                    } else {
                        builtins.io.writeStdout("\\");
                        i += 1;
                    }
                },
                else => {
                    // Pass through other escapes (already handled by expansion for double quotes,
                    // or intentionally literal for single quotes)
                    const byte = [1]u8{s[i]};
                    builtins.io.writeStdout(&byte);
                    i += 1;
                },
            }
        } else {
            const byte = [1]u8{s[i]};
            builtins.io.writeStdout(&byte);
            i += 1;
        }
    }
}

/// Parse an octal escape sequence, returns the value and number of chars consumed
fn parseOctal(s: []const u8) struct { value: u8, len: usize } {
    var value: u8 = 0;
    var len: usize = 0;

    // Read up to 3 octal digits (0-7)
    for (s[0..@min(s.len, 3)]) |c| {
        if (c >= '0' and c <= '7') {
            value = value *| 8 +| (c - '0');
            len += 1;
        } else {
            break;
        }
    }

    return .{ .value = value, .len = len };
}
