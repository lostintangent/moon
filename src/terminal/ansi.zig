//! ANSI escape sequences and terminal color utilities
//!
//! Provides color codes, styles, and escape sequence handling for terminal output.

const std = @import("std");
const io = @import("io.zig");

/// ANSI escape codes for terminal colors and styles
pub const reset = "\x1b[0m";
pub const dim = "\x1b[2m";
pub const bold = "\x1b[1m";
pub const inverse = "\x1b[7m";

// Standard foreground colors
pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const cyan = "\x1b[36m";
pub const bright_magenta = "\x1b[95m"; // light purple, used for variables
pub const gray = "\x1b[90m"; // bright black

// Background colors
pub const bg_dark_gray = "\x1b[100m";

// Cursor and Screen Control
pub const clear_screen = "\x1b[2J";
pub const clear_line = "\x1b[2K";
pub const clear_line_end = "\x1b[K";
pub const cursor_home = "\x1b[H";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";
pub const enter_alt_screen = "\x1b[?1049h";
pub const exit_alt_screen = "\x1b[?1049l";

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

/// Write a string to stdout, interpreting \e and octal escape sequences
pub fn writeEscaped(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'e' => {
                    io.writeStdout("\x1b");
                    i += 2;
                },
                '0' => {
                    // Octal escape: \0, \033, etc.
                    const octal = parseOctal(s[i + 1 ..]);
                    if (octal.len > 0) {
                        io.writeStdout(&[1]u8{octal.value});
                        i += 1 + octal.len;
                    } else {
                        io.writeStdout("\\");
                        i += 1;
                    }
                },
                else => {
                    io.writeStdout(&[1]u8{s[i]});
                    i += 1;
                },
            }
        } else {
            io.writeStdout(&[1]u8{s[i]});
            i += 1;
        }
    }
}

/// Parse an octal escape sequence, returns the value and number of chars consumed
fn parseOctal(s: []const u8) struct { value: u8, len: usize } {
    var value: u8 = 0;
    var len: usize = 0;

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
