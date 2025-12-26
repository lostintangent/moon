//! terminal builtin - Terminal control for TUI scripting
//!
//! Provides cursor control, screen clearing, and terminal mode management.
//! All commands are no-ops when stdout is not a TTY, making scripts safe to pipe.
//!
//! Commands:
//!   terminal save                     Save cursor position
//!   terminal restore                  Restore cursor position
//!   terminal move [--up N] [--down N] [--left N] [--right N] [--home]
//!   terminal clear [--lines N] [--screen] [--below] [--all]
//!   terminal enable [--cursor] [--mouse] [--focus] [--alternate]
//!   terminal disable [--cursor] [--mouse] [--focus] [--alternate]
//!   terminal title "text"             Set window title

const std = @import("std");
const builtins = @import("../builtins.zig");
const ansi = @import("../../terminal/ansi.zig");
const io = @import("../../terminal/io.zig");

pub const builtin = builtins.Builtin{
    .name = "terminal",
    .run = run,
    .help = "terminal <cmd> [flags] - Terminal control (save, restore, move, clear, enable, disable, title)",
};

// =============================================================================
// Command Dispatch
// =============================================================================

const Command = *const fn (args: []const []const u8) void;

const commands = std.StaticStringMap(Command).initComptime(.{
    .{ "save", cmdSave },
    .{ "restore", cmdRestore },
    .{ "move", cmdMove },
    .{ "clear", cmdClear },
    .{ "enable", cmdEnable },
    .{ "disable", cmdDisable },
    .{ "title", cmdTitle },
});

fn run(_: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const args = cmd.argv[1..];

    // Validate arguments first (even when not a TTY)
    if (args.len == 0) {
        builtins.io.writeStderr("terminal: missing command\n");
        return 1;
    }

    const handler = commands.get(args[0]) orelse {
        builtins.io.printError("terminal: unknown command '{s}'\n", .{args[0]});
        return 1;
    };

    // No-op when not a TTY, but still return success
    if (!io.isStdoutTty()) return 0;

    handler(args[1..]);
    return 0;
}

// =============================================================================
// Command Implementations
// =============================================================================

fn cmdSave(_: []const []const u8) void {
    io.writeStdout(ansi.cursor_save);
}

fn cmdRestore(_: []const []const u8) void {
    io.writeStdout(ansi.cursor_restore);
}

const move_flags = std.StaticStringMap(u8).initComptime(.{
    .{ "--up", 'A' },
    .{ "--down", 'B' },
    .{ "--right", 'C' },
    .{ "--left", 'D' },
});

fn cmdMove(args: []const []const u8) void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--home")) {
            io.writeStdout(ansi.cursor_home);
        } else if (move_flags.get(flag)) |code| {
            writeMove(code, parseNextArg(args, &i));
        }
    }
}

const clear_flags = std.StaticStringMap([]const u8).initComptime(.{
    .{ "--screen", ansi.clear_screen },
    .{ "--below", ansi.clear_below },
    .{ "--all", ansi.clear_all },
});

fn cmdClear(args: []const []const u8) void {
    if (args.len == 0) {
        io.writeStdout(ansi.clear_line);
        return;
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (clear_flags.get(flag)) |seq| {
            io.writeStdout(seq);
        } else if (std.mem.eql(u8, flag, "--lines")) {
            const n = parseNextArg(args, &i);
            if (n > 1) writeMove('A', n - 1);
            io.writeStdout("\r");
            io.writeStdout(ansi.clear_below);
        }
    }
}

const enable_flags = std.StaticStringMap([]const u8).initComptime(.{
    .{ "--cursor", ansi.cursor_show },
    .{ "--mouse", ansi.mouse_on },
    .{ "--focus", ansi.focus_on },
    .{ "--alternate", ansi.alt_screen_enter },
});

const disable_flags = std.StaticStringMap([]const u8).initComptime(.{
    .{ "--cursor", ansi.cursor_hide },
    .{ "--mouse", ansi.mouse_off },
    .{ "--focus", ansi.focus_off },
    .{ "--alternate", ansi.alt_screen_exit },
});

fn cmdEnable(args: []const []const u8) void {
    for (args) |flag| {
        if (enable_flags.get(flag)) |seq| io.writeStdout(seq);
    }
}

fn cmdDisable(args: []const []const u8) void {
    for (args) |flag| {
        if (disable_flags.get(flag)) |seq| io.writeStdout(seq);
    }
}

fn cmdTitle(args: []const []const u8) void {
    if (args.len == 0) return;
    io.writeStdout(ansi.osc_title_start);
    io.writeStdout(args[0]);
    io.writeStdout(ansi.osc_end);
}

// =============================================================================
// Helpers
// =============================================================================

/// Write a parameterized cursor movement sequence: CSI {n} {code}
fn writeMove(code: u8, n: u16) void {
    if (n == 0) return;
    var buf: [16]u8 = undefined;
    const len = std.fmt.bufPrint(&buf, "\x1b[{d}{c}", .{ n, code }) catch return;
    io.writeStdout(len);
}

/// Parse the next argument as a u16, defaulting to 1 if missing or invalid
fn parseNextArg(args: []const []const u8, i: *usize) u16 {
    if (i.* + 1 < args.len) {
        const next = args[i.* + 1];
        if (next.len > 0 and next[0] != '-') {
            i.* += 1;
            return std.fmt.parseInt(u16, next, 10) catch 1;
        }
    }
    return 1;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "parseNextArg: valid number" {
    const args = [_][]const u8{ "--up", "5" };
    var i: usize = 0;
    try testing.expectEqual(@as(u16, 5), parseNextArg(&args, &i));
    try testing.expectEqual(@as(usize, 1), i); // index advanced
}

test "parseNextArg: missing arg defaults to 1" {
    const args = [_][]const u8{"--up"};
    var i: usize = 0;
    try testing.expectEqual(@as(u16, 1), parseNextArg(&args, &i));
    try testing.expectEqual(@as(usize, 0), i); // index not advanced
}

test "parseNextArg: next arg is flag, defaults to 1" {
    const args = [_][]const u8{ "--up", "--down" };
    var i: usize = 0;
    try testing.expectEqual(@as(u16, 1), parseNextArg(&args, &i));
    try testing.expectEqual(@as(usize, 0), i); // index not advanced
}

test "parseNextArg: invalid number defaults to 1" {
    const args = [_][]const u8{ "--up", "abc" };
    var i: usize = 0;
    try testing.expectEqual(@as(u16, 1), parseNextArg(&args, &i));
    try testing.expectEqual(@as(usize, 1), i); // index advanced (consumed the arg)
}
