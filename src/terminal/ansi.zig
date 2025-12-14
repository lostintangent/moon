//! Shared ANSI color codes and terminal escape sequences
//!
//! Centralized definitions to avoid duplication across the codebase.

const std = @import("std");

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
