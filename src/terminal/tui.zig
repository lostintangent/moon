//! TUI primitives: raw mode, input handling, and terminal interaction.
const std = @import("std");
const posix = std.posix;
const io = @import("io.zig");

/// Key codes for special keys
pub const Key = union(enum) {
    char: u8,
    ctrl: u8, // ctrl+letter
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    backspace,
    enter,
    tab,
    eof, // ctrl+d on empty line
    // Word movement (ctrl+arrow or alt+arrow)
    word_left,
    word_right,
    // Line operations
    kill_line, // ctrl+k
    kill_word, // ctrl+w
    clear_screen, // ctrl+l
    interrupt, // ctrl+c
    search, // ctrl+r
    focus_in, // terminal gained focus
    focus_out, // terminal lost focus
    escape,
    ctrl_space,
    mouse: MouseEvent,
    unknown,
};

pub const MouseEvent = struct {
    x: u16,
    y: u16,
    // We can add buttons later if needed
};

/// Enable raw mode for the terminal
pub fn enableRawMode(fd: posix.fd_t) !posix.termios {
    const orig = try posix.tcgetattr(fd);
    var raw = orig;

    // Input modes: no break, no CR to NL, no parity check, no strip, no flow control
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;

    // Output modes: disable post processing
    raw.oflag.OPOST = false;

    // Control modes: set 8 bit chars
    raw.cflag.CSIZE = .CS8;

    // Local modes: no echo, no canonical, no extended functions, no signal chars
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;

    // Control chars: set read timeout
    raw.cc[@intFromEnum(posix.V.MIN)] = 1; // Read at least 1 char
    raw.cc[@intFromEnum(posix.V.TIME)] = 0; // No timeout

    try posix.tcsetattr(fd, .NOW, raw);
    return orig;
}

/// Restore terminal to original settings
pub fn restoreTerminal(fd: posix.fd_t, orig: posix.termios) void {
    // Disable ECHOCTL to prevent ^C or ^[[I from being displayed when restoring
    var cooked = orig;
    if (@hasField(@TypeOf(cooked.lflag), "ECHOCTL")) {
        cooked.lflag.ECHOCTL = false;
    }
    posix.tcsetattr(fd, .FLUSH, cooked) catch {};
}

/// Enable focus reporting
pub fn enableFocusReporting(fd: posix.fd_t) void {
    io.writeToFd(fd, "\x1b[?1004h");
}

/// Disable focus reporting
pub fn disableFocusReporting(fd: posix.fd_t) void {
    io.writeToFd(fd, "\x1b[?1004l");
}

/// Enable mouse reporting (SGR 1006 mode + basic mouse tracking)
pub fn enableMouseReporting(fd: posix.fd_t) void {
    // 1000: Report mouse click
    // 1006: SGR extended mouse coordinates (avoids encoding issues for x/y > 223)
    io.writeToFd(fd, "\x1b[?1000;1006h");
}

/// Disable mouse reporting
pub fn disableMouseReporting(fd: posix.fd_t) void {
    io.writeToFd(fd, "\x1b[?1000;1006l");
}

/// Read a key from the terminal
pub fn readKey(fd: posix.fd_t) !Key {
    var buf: [1]u8 = undefined;
    const n = try posix.read(fd, &buf);
    if (n == 0) return .eof;

    const c = buf[0];

    // Ctrl+key
    if (c < 32) {
        return switch (c) {
            0 => .ctrl_space, // ctrl+space
            1 => .{ .ctrl = 'a' }, // ctrl+a
            2 => .{ .ctrl = 'b' }, // ctrl+b
            3 => .interrupt, // ctrl+c
            4 => .eof, // ctrl+d
            5 => .{ .ctrl = 'e' }, // ctrl+e
            6 => .{ .ctrl = 'f' }, // ctrl+f
            7 => .unknown, // ctrl+g
            8 => .backspace, // ctrl+h
            9 => .tab, // tab
            10, 13 => .enter, // enter (LF or CR)
            11 => .kill_line, // ctrl+k
            12 => .clear_screen, // ctrl+l
            14 => .{ .ctrl = 'n' }, // ctrl+n (down in some terminals)
            16 => .{ .ctrl = 'p' }, // ctrl+p (up in some terminals)
            18 => .search, // ctrl+r
            21 => .{ .ctrl = 'u' }, // ctrl+u
            23 => .kill_word, // ctrl+w
            27 => readEscapeSequence(fd), // escape
            else => .unknown,
        };
    }

    if (c == 127) return .backspace; // DEL key

    return .{ .char = c };
}

/// Parse escape sequences.
fn readEscapeSequence(fd: posix.fd_t) Key {
    var seq: [32]u8 = undefined;

    // Check if there are more bytes available (with a short timeout)
    var pfd = [1]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    // Wait up to 10ms for the next char
    const ready = posix.poll(&pfd, 10) catch return .unknown;
    if (ready == 0) return .escape; // Timeout, just ESC

    // Read the next character
    const n1 = posix.read(fd, seq[0..1]) catch return .unknown;
    if (n1 == 0) return .unknown;

    if (seq[0] == '[') {
        // CSI sequence
        const ready2 = posix.poll(&pfd, 10) catch return .unknown;
        if (ready2 == 0) return .unknown;

        const n2 = posix.read(fd, seq[1..2]) catch return .unknown;
        if (n2 == 0) return .unknown;

        if ((seq[1] >= '0' and seq[1] <= '9') or seq[1] == '<') {
            // Extended sequence like ESC[1;5C or ESC[<0;23;45M (mouse)

            // Read until we hit a letter or tilde, or buffer full
            var i: usize = 2;
            while (i < seq.len) {
                const ready_more = posix.poll(&pfd, 10) catch return .unknown;
                if (ready_more == 0) break;

                const n_more = posix.read(fd, seq[i .. i + 1]) catch return .unknown;
                if (n_more == 0) break;

                const c = seq[i];
                i += 1;

                if (c >= 64 and c <= 126) {
                    // End of sequence
                    break;
                }
            }

            // Handle mouse: <button>;<x>;<y>M or m
            if (seq[1] == '<') {
                // SGR mouse mode: \x1b[<0;10;20M (press) or m (release)
                // Format: <button>;<px>;<py>[Mm]
                const last_char = seq[i - 1];
                // For now, let's just handle "press" (M) on left button (0)
                if (last_char == 'M') {
                    // It's a press/move
                    // Parse contents
                    const content = seq[2 .. i - 1]; // Skip '<' and 'M'

                    var iter = std.mem.splitScalar(u8, content, ';');
                    const button_str = iter.next() orelse return .unknown;
                    const x_str = iter.next() orelse return .unknown;
                    const y_str = iter.next() orelse return .unknown;

                    const button = std.fmt.parseInt(u16, button_str, 10) catch return .unknown;
                    const x = std.fmt.parseInt(u16, x_str, 10) catch return .unknown;
                    const y = std.fmt.parseInt(u16, y_str, 10) catch return .unknown;

                    // Button 0 is left click
                    if (button == 0) {
                        return .{ .mouse = .{ .x = x, .y = y } };
                    }
                }
                return .unknown;
            }

            if (i > 2 and seq[2] == '~') {
                return switch (seq[1]) {
                    '1' => .home,
                    '3' => .delete,
                    '4' => .end,
                    '5' => .page_up,
                    '6' => .page_down,
                    '7' => .home,
                    '8' => .end,
                    else => .unknown,
                };
            }

            // Modifier sequences (e.g., ESC[1;5C for ctrl+right)
            const last_char = seq[i - 1];
            if (last_char == 'C' or last_char == 'D') {
                // Check if it contains ";5" or ";3"
                const slice = seq[0..i];
                if (std.mem.indexOf(u8, slice, ";5") != null or std.mem.indexOf(u8, slice, ";3") != null) {
                    return switch (last_char) {
                        'C' => .word_right,
                        'D' => .word_left,
                        else => .unknown,
                    };
                }
            }
        } else {
            return switch (seq[1]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                'I' => .focus_in, // Focus in: \x1b[I
                'O' => .focus_out, // Focus out: \x1b[O
                else => .unknown,
            };
        }
    } else if (seq[0] == 'O') {
        // SS3 sequence
        const ready2 = posix.poll(&pfd, 10) catch return .unknown;
        if (ready2 == 0) return .unknown;

        const n2 = posix.read(fd, seq[1..2]) catch return .unknown;
        if (n2 == 0) return .unknown;

        return switch (seq[1]) {
            'H' => .home,
            'F' => .end,
            else => .unknown,
        };
    } else if (seq[0] == 'b') {
        // Alt+b = word left
        return .word_left;
    } else if (seq[0] == 'f') {
        // Alt+f = word right
        return .word_right;
    }

    return .unknown;
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
