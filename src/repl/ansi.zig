//! Shared ANSI color codes and terminal escape sequences
//!
//! Centralized definitions to avoid duplication across the codebase.

const std = @import("std");
const io = @import("../interpreter/execution/io.zig");

/// ANSI escape codes for terminal colors and styles
pub const reset = "\x1b[0m";
pub const dim = "\x1b[2m";
pub const bold = "\x1b[1m";

// Standard foreground colors
pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const cyan = "\x1b[36m";

/// Calculate display length of a string, ignoring ANSI escape sequences
pub fn displayLength(s: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '\x1b' and s[i + 1] == '[') {
            // Skip CSI sequence: ESC [ params final_byte
            i += 2;
            while (i < s.len and s[i] >= 0x20 and s[i] < 0x40) : (i += 1) {}
            if (i < s.len) i += 1;
        } else {
            len += 1;
            i += 1;
        }
    }
    return len;
}

/// Emit OSC 7 escape sequence to notify terminal of current working directory.
/// Format: ESC ] 7 ; file://hostname/path BEL
pub fn emitOsc7(cwd: []const u8) void {
    // Get hostname
    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buf) catch "localhost";

    // Build and emit the OSC 7 sequence
    var buf: [2048]u8 = undefined;
    const osc = std.fmt.bufPrint(&buf, "\x1b]7;file://{s}{s}\x07", .{ hostname, cwd }) catch return;
    io.writeStdout(osc);
}
