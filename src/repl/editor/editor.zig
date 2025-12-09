//! Line editor with raw mode terminal handling
const std = @import("std");
const history = @import("history.zig");
const highlight = @import("ui/highlight.zig");
const suggest = @import("ui/suggest.zig");
const complete = @import("ui/complete.zig");
const ansi = @import("../ansi.zig");
const State = @import("../../runtime/state.zig").State;

const History = history.History;
const posix = std.posix;
const Termios = std.posix.termios;
const system = std.posix.system;

// ============== Word Boundary Helpers ==============

/// Find the position of the previous word boundary (moving left).
/// Note: Only treats space as a word separator for simplicity.
fn findWordBoundaryLeft(buf: []const u8, cursor: usize) usize {
    var pos = cursor;
    while (pos > 0 and buf[pos - 1] == ' ') pos -= 1;
    while (pos > 0 and buf[pos - 1] != ' ') pos -= 1;
    return pos;
}

/// Find the position of the next word boundary (moving right).
/// Note: Only treats space as a word separator for simplicity.
fn findWordBoundaryRight(buf: []const u8, cursor: usize) usize {
    var pos = cursor;
    while (pos < buf.len and buf[pos] != ' ') pos += 1;
    while (pos < buf.len and buf[pos] == ' ') pos += 1;
    return pos;
}

// ============== Terminal I/O ==============

fn writeToTerminal(bytes: []const u8) !void {
    _ = try posix.write(posix.STDOUT_FILENO, bytes);
}

/// Get the current terminal width, or null if unavailable
fn getTerminalWidth() ?usize {
    var ws: system.winsize = undefined;
    const rc = system.ioctl(posix.STDOUT_FILENO, system.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.col > 0) {
        return ws.col;
    }
    return null;
}

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
    unknown,
};

/// Line editor state
pub const Editor = struct {
    allocator: std.mem.Allocator,
    /// The line buffer
    buf: std.ArrayListUnmanaged(u8),
    /// Cursor position in the buffer
    cursor: usize,
    /// Original terminal settings (to restore on exit)
    orig_termios: ?Termios,
    /// History manager
    hist: history.History,
    /// Current history navigation index (null = editing new line)
    hist_index: ?usize,
    /// Saved current line when navigating history
    saved_line: ?[]u8,
    /// Terminal file descriptor
    tty_fd: posix.fd_t,
    /// Current prompt (stored for refresh)
    prompt: []const u8,
    /// Enable syntax highlighting
    highlighting: bool,
    /// Enable autosuggestions
    suggestions: bool,
    /// Shell state (for alias checking in highlighting)
    state: ?*State,
    /// Search mode active
    search_mode: bool,
    /// Search query buffer
    search_query: std.ArrayListUnmanaged(u8),
    /// Index of current search match in history
    search_match_index: ?usize,
    /// Whether the terminal currently has focus (controls redraw and suggestions)
    has_focus: bool,
    /// Whether the display has been initialized (safe to render). Currently driven
    /// by focus events: first focus signals the terminal is visible and properly sized.
    display_initialized: bool,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{
            .allocator = allocator,
            .buf = .empty,
            .cursor = 0,
            .orig_termios = null,
            .hist = history.History.init(allocator),
            .hist_index = null,
            .saved_line = null,
            .tty_fd = posix.STDIN_FILENO,
            .prompt = "",
            .highlighting = true,
            .suggestions = true,
            .state = null,
            .search_mode = false,
            .search_query = .empty,
            .search_match_index = null,
            .has_focus = false,
            .display_initialized = false,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.restoreTerminal();
        self.buf.deinit(self.allocator);
        self.hist.deinit();
        self.search_query.deinit(self.allocator);
        if (self.saved_line) |line| {
            self.allocator.free(line);
        }
    }

    /// Load history from file
    pub fn loadHistory(self: *Editor, path: []const u8) void {
        self.hist.load(path);
    }

    /// Save history to file
    pub fn saveHistory(self: *Editor, path: []const u8) void {
        self.hist.save(path);
    }

    /// Enable raw mode for the terminal
    pub fn enableRawMode(self: *Editor) !void {
        if (self.orig_termios != null) return; // Already in raw mode

        var raw = try posix.tcgetattr(self.tty_fd);
        self.orig_termios = raw;

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

        try posix.tcsetattr(self.tty_fd, .NOW, raw);

        // Enable focus reporting so we can suppress suggestions when unfocused
        try writeToTerminal("\x1b[?1004h");
    }

    /// Restore terminal to original settings
    pub fn restoreTerminal(self: *Editor) void {
        if (self.tty_fd < 0) return; // Skip for test instances
        if (self.orig_termios) |orig| {
            // Disable focus reporting before restoring cooked mode to avoid stray focus escapes
            writeToTerminal("\x1b[?1004l") catch {};

            // Disable ECHOCTL to prevent ^C or ^[[I from being displayed when restoring
            var cooked = orig;
            if (@hasField(@TypeOf(cooked.lflag), "ECHOCTL")) {
                cooked.lflag.ECHOCTL = false;
            }

            posix.tcsetattr(self.tty_fd, .FLUSH, cooked) catch {};
            self.orig_termios = null;
        }
    }

    /// Read a line from the user. Returns null on EOF (ctrl+d on empty line).
    /// Assumes raw mode is already enabled (call enableRawMode before first use).
    pub fn readLine(self: *Editor, prompt_text: []const u8) !?[]const u8 {
        self.prompt = prompt_text;
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_index = null;
        if (self.saved_line) |line| {
            self.allocator.free(line);
            self.saved_line = null;
        }

        try writeToTerminal(prompt_text);

        while (true) {
            const key = try self.readKey();

            // Handle search mode - returns true if key was consumed
            if (self.search_mode and try self.handleSearchKey(key)) {
                continue;
            }

            switch (key) {
                .search => {
                    self.search_mode = true;
                    self.search_query.clearRetainingCapacity();
                    self.search_match_index = null;
                    try self.refreshSearch();
                },
                .enter => {
                    // Clear suggestion text before newline by rewriting line without suggestion
                    try writeToTerminal("\r\x1b[K");
                    try writeToTerminal(self.prompt);
                    try writeToTerminal(self.buf.items);
                    try writeToTerminal("\r\n");
                    const line = try self.allocator.dupe(u8, self.buf.items);
                    if (line.len > 0) {
                        _ = self.hist.add(line);
                    }
                    return line;
                },
                .eof => {
                    if (self.buf.items.len == 0) {
                        try writeToTerminal("\r\n");
                        return null;
                    }
                },
                .char => |c| try self.insertChar(c),
                .backspace => try self.deleteBackward(),
                .delete => try self.deleteForward(),
                .left => try self.moveCursorLeft(),
                .right => try self.acceptSuggestionOrMoveRight(),
                .home => try self.moveCursorHome(),
                .end => try self.acceptSuggestionOrMoveEnd(),
                .word_left => try self.moveCursorWordLeft(),
                .word_right => try self.moveCursorWordRight(),
                .up => try self.historyPrev(),
                .down => try self.historyNext(),
                .kill_line => try self.killLine(),
                .kill_word => try self.killWord(),
                .clear_screen => try self.clearScreen(),
                .interrupt => {
                    try writeToTerminal("^C\r\n");
                    self.buf.clearRetainingCapacity();
                    self.cursor = 0;
                    try writeToTerminal(self.prompt);
                },
                .ctrl => |c| switch (c) {
                    'a' => try self.moveCursorHome(),
                    'e' => try self.acceptSuggestionOrMoveEnd(),
                    'b' => try self.moveCursorLeft(),
                    'f' => try self.acceptSuggestionOrMoveRight(),
                    'h' => try self.deleteBackward(),
                    'u' => try self.killToStart(),
                    else => {},
                },
                .tab => try self.handleTab(),
                .focus_in => {
                    self.has_focus = true;
                    self.display_initialized = true;
                    try self.refreshLine();
                },
                .focus_out => {
                    self.has_focus = false;
                },
                .unknown => {},
            }
        }
    }

    /// Handle key input while in search mode.
    /// Returns true if the key was consumed (caller should continue to next key).
    /// Returns false if the key should be processed by normal key handling.
    fn handleSearchKey(self: *Editor, key: Key) !bool {
        switch (key) {
            .search => {
                // Ctrl+R again = find next match
                self.performSearch(true);
                try self.refreshSearch();
                return true;
            },
            .backspace => {
                if (self.search_query.items.len > 0) {
                    _ = self.search_query.pop();
                    self.performSearch(false);
                    try self.refreshSearch();
                }
                return true;
            },
            .char => |c| {
                try self.search_query.append(self.allocator, c);
                self.performSearch(false);
                try self.refreshSearch();
                return true;
            },
            else => {
                // Exit search mode, accept match, then let caller process the key
                self.search_mode = false;
                if (self.search_match_index) |idx| {
                    try self.setLineContent(self.hist.entries.items[idx]);
                }
                try self.refreshLine();
                return false;
            },
        }
    }

    /// Read a key from the terminal
    fn readKey(self: *Editor) !Key {
        var buf: [1]u8 = undefined;
        const n = try posix.read(self.tty_fd, &buf);
        if (n == 0) return .eof;

        const c = buf[0];

        // Ctrl+key
        if (c < 32) {
            return switch (c) {
                0 => .unknown, // ctrl+space
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
                27 => self.readEscapeSequence(), // escape
                else => .unknown,
            };
        }

        if (c == 127) return .backspace; // DEL key

        return .{ .char = c };
    }

    /// Parse escape sequences. Returns `.unknown` for unrecognized or malformed
    /// sequences rather than propagating errors, since they are harmless.
    fn readEscapeSequence(self: *Editor) Key {
        var seq: [3]u8 = undefined;

        // Check if there are more bytes available (with a short timeout)
        // This prevents hanging if the user just presses ESC
        var pfd = [1]posix.pollfd{.{
            .fd = self.tty_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        // Wait up to 10ms for the next char
        const ready = posix.poll(&pfd, 10) catch return .unknown;
        if (ready == 0) return .unknown; // Timeout, just ESC

        // Read the next character
        const n1 = posix.read(self.tty_fd, seq[0..1]) catch return .unknown;
        if (n1 == 0) return .unknown;

        if (seq[0] == '[') {
            // CSI sequence
            // We need to read more, so poll again
            const ready2 = posix.poll(&pfd, 10) catch return .unknown;
            if (ready2 == 0) return .unknown;

            const n2 = posix.read(self.tty_fd, seq[1..2]) catch return .unknown;
            if (n2 == 0) return .unknown;

            if (seq[1] >= '0' and seq[1] <= '9') {
                // Extended sequence like ESC[1;5C
                const ready3 = posix.poll(&pfd, 10) catch return .unknown;
                if (ready3 == 0) return .unknown;

                const n3 = posix.read(self.tty_fd, seq[2..3]) catch return .unknown;
                if (n3 == 0) return .unknown;

                if (seq[2] == '~') {
                    return switch (seq[1]) {
                        '1' => .home,
                        '3' => .delete,
                        '4' => .end,
                        '7' => .home,
                        '8' => .end,
                        else => .unknown,
                    };
                }
                // Check for modifier sequences (e.g., ESC[1;5C for ctrl+right)
                if (seq[2] == ';') {
                    var mod_seq: [2]u8 = undefined;
                    // Poll for modifiers
                    const ready4 = posix.poll(&pfd, 10) catch return .unknown;
                    if (ready4 == 0) return .unknown;

                    const n4 = posix.read(self.tty_fd, &mod_seq) catch return .unknown;
                    if (n4 < 2) return .unknown;

                    // mod_seq[0] is modifier: 5 = ctrl, 3 = alt
                    const direction = mod_seq[1];
                    if (mod_seq[0] == '5' or mod_seq[0] == '3') {
                        return switch (direction) {
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

            const n2 = posix.read(self.tty_fd, seq[1..2]) catch return .unknown;
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

    /// Insert a character at the cursor position
    fn insertChar(self: *Editor, c: u8) !void {
        try self.buf.insert(self.allocator, self.cursor, c);
        self.cursor += 1;
        try self.refreshLine();
    }

    /// Delete the character before the cursor
    fn deleteBackward(self: *Editor) !void {
        if (self.cursor > 0 and self.buf.items.len > 0) {
            _ = self.buf.orderedRemove(self.cursor - 1);
            self.cursor -= 1;
            try self.refreshLine();
        }
    }

    /// Delete the character at the cursor
    fn deleteForward(self: *Editor) !void {
        if (self.cursor < self.buf.items.len) {
            _ = self.buf.orderedRemove(self.cursor);
            try self.refreshLine();
        }
    }

    /// Move cursor left
    fn moveCursorLeft(self: *Editor) !void {
        if (self.cursor > 0) {
            self.cursor -= 1;
            try writeToTerminal("\x1b[D");
        }
    }

    /// Move cursor right
    fn moveCursorRight(self: *Editor) !void {
        if (self.cursor < self.buf.items.len) {
            self.cursor += 1;
            try writeToTerminal("\x1b[C");
        }
    }

    /// Move cursor to start of line
    fn moveCursorHome(self: *Editor) !void {
        self.cursor = 0;
        try self.refreshLine();
    }

    /// Move cursor to end of line
    fn moveCursorEnd(self: *Editor) !void {
        self.cursor = self.buf.items.len;
        try self.refreshLine();
    }

    /// Move cursor to previous word boundary
    fn moveCursorWordLeft(self: *Editor) !void {
        self.cursor = findWordBoundaryLeft(self.buf.items, self.cursor);
        try self.refreshLine();
    }

    /// Move cursor to next word boundary
    fn moveCursorWordRight(self: *Editor) !void {
        self.cursor = findWordBoundaryRight(self.buf.items, self.cursor);
        try self.refreshLine();
    }

    /// Delete from cursor to end of line
    fn killLine(self: *Editor) !void {
        self.buf.shrinkRetainingCapacity(self.cursor);
        try self.refreshLine();
    }

    /// Delete from start to cursor
    fn killToStart(self: *Editor) !void {
        if (self.cursor > 0) {
            std.mem.copyForwards(u8, self.buf.items[0..], self.buf.items[self.cursor..]);
            self.buf.shrinkRetainingCapacity(self.buf.items.len - self.cursor);
            self.cursor = 0;
            try self.refreshLine();
        }
    }

    /// Delete the word before cursor
    fn killWord(self: *Editor) !void {
        if (self.cursor == 0) return;

        const end = self.cursor;
        self.cursor = findWordBoundaryLeft(self.buf.items, self.cursor);

        // Shift remaining content left and shrink (O(n) instead of O(n²))
        const remaining = self.buf.items.len - end;
        std.mem.copyForwards(u8, self.buf.items[self.cursor..], self.buf.items[end..][0..remaining]);
        self.buf.shrinkRetainingCapacity(self.cursor + remaining);
        try self.refreshLine();
    }

    /// Clear screen and redraw
    fn clearScreen(self: *Editor) !void {
        try writeToTerminal("\x1b[H\x1b[2J");
        try writeToTerminal(self.prompt);
        try self.refreshLine();
    }

    /// Navigate to previous history entry
    fn historyPrev(self: *Editor) !void {
        if (self.hist.entries.items.len == 0) return;

        if (self.hist_index == null) {
            if (self.saved_line) |old| self.allocator.free(old);
            self.saved_line = try self.allocator.dupe(u8, self.buf.items);
            self.hist_index = self.hist.entries.items.len;
        }

        if (self.hist_index.? > 0) {
            self.hist_index.? -= 1;
            try self.setLineContent(self.hist.entries.items[self.hist_index.?]);
            try self.refreshLine();
        }
    }

    /// Navigate to next history entry
    fn historyNext(self: *Editor) !void {
        if (self.hist_index == null) return;

        if (self.hist_index.? < self.hist.entries.items.len - 1) {
            self.hist_index.? += 1;
            try self.setLineContent(self.hist.entries.items[self.hist_index.?]);
        } else {
            self.hist_index = null;
            if (self.saved_line) |saved| {
                try self.setLineContent(saved);
                self.allocator.free(saved);
                self.saved_line = null;
            } else {
                self.buf.clearRetainingCapacity();
                self.cursor = 0;
            }
        }
        try self.refreshLine();
    }

    /// Perform history search
    fn performSearch(self: *Editor, next: bool) void {
        const start = if (next) self.search_match_index else null;
        self.search_match_index = self.hist.search(self.search_query.items, start);
    }

    /// Refresh search UI
    fn refreshSearch(self: *Editor) !void {
        var out_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&out_buf);
        const writer = stream.writer();

        try writer.writeAll("\r\x1b[K");
        try writer.print(ansi.magenta ++ "Search history: " ++ ansi.reset ++ "{s} ", .{self.search_query.items});

        if (self.search_match_index) |idx| {
            const total = self.hist.countMatches(self.search_query.items);
            const pos = self.hist.getMatchPosition(self.search_query.items, idx);
            try writer.print(ansi.dim ++ "({d} of {d}) " ++ ansi.reset, .{ pos, total });
            const match = self.hist.entries.items[idx];
            try writer.writeAll(match);
        } else if (self.search_query.items.len > 0) {
            try writer.writeAll(ansi.dim ++ "No results found" ++ ansi.reset);
        }

        try writeToTerminal(stream.getWritten());
    }

    /// Set line content from history
    fn setLineContent(self: *Editor, content: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, content);
        self.cursor = self.buf.items.len;
    }

    /// Refresh the display of the current line
    fn refreshLine(self: *Editor) !void {
        // Skip redraws until display is initialized (terminal visible and sized).
        // Once initialized, refresh even when unfocused to support programmatic PTY input.
        if (!self.has_focus and !self.display_initialized) return;

        if (self.search_mode) {
            try self.refreshSearch();
            return;
        }

        var out_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&out_buf);
        const writer = stream.writer();

        // Clear line and write prompt
        try writer.writeAll("\r\x1b[K");
        try writer.writeAll(self.prompt);

        // Write input (with optional highlighting; skip highlighting when unfocused for perf)
        if (self.highlighting and self.has_focus and self.buf.items.len > 0) {
            highlight.render(self.allocator, self.buf.items, writer, self.state) catch {
                // Fallback to plain text on error
                try writer.writeAll(self.buf.items);
            };
        } else {
            try writer.writeAll(self.buf.items);
        }

        // Write suggestion suffix (dimmed) if cursor is at end and focused
        if (self.suggestions and self.has_focus and self.cursor == self.buf.items.len) {
            if (suggest.fromHistory(self.buf.items, &self.hist)) |suffix| {
                // Truncate suggestion to fit terminal width
                const display_suffix = if (getTerminalWidth()) |term_width| blk: {
                    const used = ansi.displayLength(self.prompt) + self.buf.items.len;
                    if (used >= term_width) break :blk suffix[0..0];
                    const available = term_width - used - 1; // -1 to prevent cursor at edge
                    if (suffix.len <= available) {
                        break :blk suffix;
                    } else if (available > 3) {
                        break :blk suffix[0 .. available - 3]; // Leave room for "..."
                    } else {
                        break :blk suffix[0..0];
                    }
                } else suffix;

                if (display_suffix.len > 0) {
                    const truncated = display_suffix.len < suffix.len;
                    try writer.writeAll(ansi.dim);
                    try writer.writeAll(display_suffix);
                    if (truncated) try writer.writeAll("...");
                    try writer.writeAll(ansi.reset);
                    // Move cursor back to end of actual input
                    const move_back = display_suffix.len + if (truncated) @as(usize, 3) else 0;
                    try writer.print("\x1b[{d}D", .{move_back});
                }
            }
        }

        // Position cursor
        if (self.cursor < self.buf.items.len) {
            const back = self.buf.items.len - self.cursor;
            try writer.print("\x1b[{d}D", .{back});
        }

        try writeToTerminal(stream.getWritten());
    }

    /// Try to accept the current suggestion. Returns true if accepted.
    fn tryAcceptSuggestion(self: *Editor) !bool {
        if (!self.suggestions or self.cursor != self.buf.items.len) return false;
        if (suggest.fromHistory(self.buf.items, &self.hist)) |suffix| {
            try self.buf.appendSlice(self.allocator, suffix);
            self.cursor = self.buf.items.len;
            try self.refreshLine();
            return true;
        }
        return false;
    }

    /// Accept suggestion if at end of line, otherwise move cursor right
    fn acceptSuggestionOrMoveRight(self: *Editor) !void {
        if (try self.tryAcceptSuggestion()) return;
        if (self.cursor < self.buf.items.len) {
            self.cursor += 1;
            try writeToTerminal("\x1b[C");
        }
    }

    /// Accept suggestion if at end of line, otherwise move to end
    fn acceptSuggestionOrMoveEnd(self: *Editor) !void {
        if (try self.tryAcceptSuggestion()) return;
        if (self.cursor < self.buf.items.len) {
            self.cursor = self.buf.items.len;
            try self.refreshLine();
        }
    }

    /// Handle tab key for completion
    fn handleTab(self: *Editor) !void {
        var result = complete.complete(self.allocator, self.buf.items, self.cursor) catch return;
        if (result == null) return;
        defer result.?.deinit(self.allocator);

        const completions = result.?.completions;
        if (completions.len == 0) return;

        // Get the common prefix
        const prefix = result.?.commonPrefix();
        const word_start = result.?.word_start;
        const word_end = result.?.word_end;
        const current_word = self.buf.items[word_start..word_end];

        // If common prefix is longer than current word, insert it
        if (prefix.len > current_word.len) {
            // Replace current word with common prefix
            try self.replaceWord(word_start, word_end, prefix);
        } else if (completions.len == 1) {
            // Single completion - insert it with trailing space
            const comp_with_space = try std.fmt.allocPrint(self.allocator, "{s} ", .{completions[0]});
            defer self.allocator.free(comp_with_space);
            try self.replaceWord(word_start, word_end, comp_with_space);
        } else {
            // Multiple completions - show them
            try self.showCompletions(completions);
        }
    }

    /// Replace a word in the buffer
    fn replaceWord(self: *Editor, start: usize, end: usize, replacement: []const u8) !void {
        // Calculate new buffer size
        const old_len = end - start;
        const new_len = replacement.len;
        const buf_len = self.buf.items.len;

        if (new_len > old_len) {
            // Need to grow - insert extra space
            const extra = new_len - old_len;
            for (0..extra) |_| {
                try self.buf.insert(self.allocator, end, ' ');
            }
        } else if (new_len < old_len) {
            // Need to shrink - remove extra
            const remove = old_len - new_len;
            for (0..remove) |_| {
                _ = self.buf.orderedRemove(start);
            }
        }

        // Copy replacement into position
        @memcpy(self.buf.items[start .. start + new_len], replacement);

        // Update cursor
        self.cursor = start + new_len;

        // Recalculate buffer length
        _ = buf_len;

        try self.refreshLine();
    }

    /// Display multiple completions below the prompt
    fn showCompletions(self: *Editor, completions: []const []const u8) !void {
        // Move to new line and show completions
        try writeToTerminal("\r\n");

        // Display completions in columns
        for (completions) |c| {
            try writeToTerminal(c);
            try writeToTerminal("  ");
        }
        try writeToTerminal("\r\n");

        // Redraw prompt and line
        try writeToTerminal(self.prompt);
        try self.refreshLine();
    }

    // ============== Testing ==============

    fn initForTest(allocator: std.mem.Allocator) Editor {
        return .{
            .allocator = allocator,
            .buf = .{},
            .cursor = 0,
            .prompt = "$ ",
            .hist = History.init(allocator),
            .hist_index = null,
            .saved_line = null,
            .orig_termios = null,
            .tty_fd = -1,
            .highlighting = false,
            .suggestions = false,
            .state = null,
            .search_mode = false,
            .search_query = .{},
            .search_match_index = null,
            .has_focus = true,
            .display_initialized = true,
        };
    }

    fn setBuffer(self: *Editor, content: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, content);
        self.cursor = content.len;
    }

    fn getBuffer(self: *const Editor) []const u8 {
        return self.buf.items;
    }
};

// ============== Unit Tests ==============

test "buffer: insert at end" {
    const allocator = std.testing.allocator;
    var editor = Editor.initForTest(allocator);
    defer editor.deinit();

    try editor.buf.insert(allocator, 0, 'h');
    editor.cursor = 1;
    try editor.buf.insert(allocator, 1, 'i');
    editor.cursor = 2;

    try std.testing.expectEqualStrings("hi", editor.getBuffer());
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
}

test "buffer: insert in middle" {
    const allocator = std.testing.allocator;
    var editor = Editor.initForTest(allocator);
    defer editor.deinit();

    try editor.setBuffer("hllo");
    editor.cursor = 1;
    try editor.buf.insert(allocator, 1, 'e');
    editor.cursor = 2;

    try std.testing.expectEqualStrings("hello", editor.getBuffer());
}

test "buffer: delete backward" {
    const allocator = std.testing.allocator;
    var editor = Editor.initForTest(allocator);
    defer editor.deinit();

    try editor.setBuffer("hello");
    _ = editor.buf.orderedRemove(editor.cursor - 1);
    editor.cursor -= 1;

    try std.testing.expectEqualStrings("hell", editor.getBuffer());
    try std.testing.expectEqual(@as(usize, 4), editor.cursor);
}

test "buffer: delete forward" {
    const allocator = std.testing.allocator;
    var editor = Editor.initForTest(allocator);
    defer editor.deinit();

    try editor.setBuffer("hello");
    editor.cursor = 0;
    _ = editor.buf.orderedRemove(0);

    try std.testing.expectEqualStrings("ello", editor.getBuffer());
}

test "cursor: basic movement" {
    const allocator = std.testing.allocator;
    var editor = Editor.initForTest(allocator);
    defer editor.deinit();

    try editor.setBuffer("hello world");
    editor.cursor = 5;

    // Home
    editor.cursor = 0;
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);

    // End
    editor.cursor = editor.buf.items.len;
    try std.testing.expectEqual(@as(usize, 11), editor.cursor);

    // Left/Right
    editor.cursor = 5;
    editor.cursor -= 1;
    try std.testing.expectEqual(@as(usize, 4), editor.cursor);
    editor.cursor += 1;
    try std.testing.expectEqual(@as(usize, 5), editor.cursor);
}

test "word boundary: left" {
    try std.testing.expectEqual(@as(usize, 6), findWordBoundaryLeft("hello world", 11));
    try std.testing.expectEqual(@as(usize, 0), findWordBoundaryLeft("hello world", 6));
    try std.testing.expectEqual(@as(usize, 0), findWordBoundaryLeft("hello", 5));
}

test "word boundary: right" {
    try std.testing.expectEqual(@as(usize, 6), findWordBoundaryRight("hello world", 0));
    try std.testing.expectEqual(@as(usize, 11), findWordBoundaryRight("hello world", 6));
}

test "kill: to end of line" {
    const allocator = std.testing.allocator;
    var editor = Editor.initForTest(allocator);
    defer editor.deinit();

    try editor.setBuffer("hello world");
    editor.cursor = 5;
    editor.buf.shrinkRetainingCapacity(editor.cursor);

    try std.testing.expectEqualStrings("hello", editor.getBuffer());
}

test "kill: to start of line" {
    const allocator = std.testing.allocator;
    var editor = Editor.initForTest(allocator);
    defer editor.deinit();

    try editor.setBuffer("hello world");
    editor.cursor = 6;

    std.mem.copyForwards(u8, editor.buf.items[0..], editor.buf.items[editor.cursor..]);
    editor.buf.shrinkRetainingCapacity(editor.buf.items.len - editor.cursor);
    editor.cursor = 0;

    try std.testing.expectEqualStrings("world", editor.getBuffer());
}

test "kill: previous word" {
    const allocator = std.testing.allocator;
    var editor = Editor.initForTest(allocator);
    defer editor.deinit();

    try editor.setBuffer("hello world");
    editor.cursor = 11;

    const end = editor.cursor;
    editor.cursor = findWordBoundaryLeft(editor.buf.items, editor.cursor);
    for (0..(end - editor.cursor)) |_| {
        _ = editor.buf.orderedRemove(editor.cursor);
    }

    try std.testing.expectEqualStrings("hello ", editor.getBuffer());
    try std.testing.expectEqual(@as(usize, 6), editor.cursor);
}
