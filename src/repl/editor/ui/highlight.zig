//! AST-aware syntax highlighting for the line editor
//!
//! Tokenizes and parses input to provide semantic highlighting:
//! - Valid commands (builtins, aliases, or PATH executables) are bold
//! - Invalid commands are red
//! - Strings are green, operators are cyan/yellow/magenta

const std = @import("std");
const Lexer = @import("../../../language/lexer.zig").Lexer;
const Parser = @import("../../../language/parser.zig").Parser;
const tokens = @import("../../../language/tokens.zig");
const resolve = @import("../../../runtime/resolve.zig");
const State = @import("../../../runtime/state.zig").State;
const ansi = @import("../../../terminal/ansi.zig");

/// Cache for command existence checks (avoids repeated PATH searches)
const CommandCache = struct {
    map: std.StringHashMap(bool),
    allocator: std.mem.Allocator,
    state: ?*State,

    fn init(allocator: std.mem.Allocator, state: ?*State) CommandCache {
        return .{ .map = std.StringHashMap(bool).init(allocator), .allocator = allocator, .state = state };
    }

    fn deinit(self: *CommandCache) void {
        self.map.deinit();
    }

    fn isValid(self: *CommandCache, cmd: []const u8) bool {
        // Check cache first
        if (self.map.get(cmd)) |valid| {
            return valid;
        }

        const valid = resolve.isValid(self.state, cmd);
        self.map.put(cmd, valid) catch {};
        return valid;
    }
};

/// Render highlighted input to a writer
pub fn render(allocator: std.mem.Allocator, input: []const u8, writer: anytype, state: ?*State) !void {
    if (input.len == 0) return;

    // Use an arena for all temporary allocations (lexer, parser, AST)
    // This ensures everything is freed when the function returns
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var lexer = Lexer.init(arena_alloc, input);
    const toks = lexer.tokenize() catch {
        try writer.writeAll(input);
        return;
    };

    // Try to parse to get command positions
    var parser = Parser.init(arena_alloc, toks);
    const ast = parser.parse() catch null;

    // Build set of command positions (byte offsets of first word in each command)
    var cmd_positions = std.AutoHashMap(usize, bool).init(arena_alloc);

    if (ast) |program| {
        for (program.statements) |stmt| {
            switch (stmt.kind) {
                .cmd => |cmd_stmt| {
                    for (cmd_stmt.chains) |chain| {
                        for (chain.pipeline.cmds) |cmd| {
                            if (cmd.words.len == 0) continue;
                            const first_word = cmd.words[0];
                            if (first_word.len == 0) continue;

                            // Find the token whose word slice matches (by pointer identity)
                            for (toks) |tok| {
                                if (tok.data == .word and tok.data.word.ptr == first_word.ptr) {
                                    cmd_positions.put(tok.span.start_col - 1, true) catch {};
                                    break;
                                }
                            }
                        }
                    }
                },
                .fun_def => {}, // Function definitions don't need command highlighting
                .if_stmt => {}, // If statements don't need command highlighting
                .for_stmt => {}, // For statements don't need command highlighting
                .while_stmt => {}, // While statements don't need command highlighting
                .break_stmt => {}, // Break doesn't need command highlighting
                .continue_stmt => {}, // Continue doesn't need command highlighting
            }
        }
    }

    // Command validity cache
    var cache = CommandCache.init(arena_alloc, state);

    var pos: usize = 0;

    for (toks) |token| {
        const start = token.span.start_col - 1;
        const end = token.span.end_col - 1;

        // Write whitespace gap
        if (start > pos) {
            try writer.writeAll(input[pos..start]);
        }

        if (start >= input.len or end > input.len or end <= start) {
            pos = end;
            continue;
        }

        const text = input[start..end];

        switch (token.data) {
            .word => |segs| {
                // Get the bare text for lookups
                const bare_text = if (segs.len > 0 and segs[0].q == .bare) segs[0].t else text;

                // Check if this is a keyword first
                if (segs.len == 1 and segs[0].q == .bare and tokens.isKeyword(bare_text)) {
                    try writer.writeAll(ansi.blue);
                    try writer.writeAll(text);
                    try writer.writeAll(ansi.reset);
                } else if (cmd_positions.get(start) != null) {
                    // Word is in command position
                    if (cache.isValid(bare_text)) {
                        try writer.writeAll(ansi.bold);
                        try writer.writeAll(text);
                        try writer.writeAll(ansi.reset);
                    } else {
                        try writer.writeAll(ansi.red);
                        try writer.writeAll(text);
                        try writer.writeAll(ansi.reset);
                    }
                } else {
                    // Color quoted strings green, bare words default
                    const has_quotes = for (segs) |seg| {
                        if (seg.q != .bare) break true;
                    } else false;

                    if (has_quotes) {
                        try writer.writeAll(ansi.green);
                        try writer.writeAll(text);
                        try writer.writeAll(ansi.reset);
                    } else {
                        try writer.writeAll(text);
                    }
                }
            },
            .op => |op| {
                try writer.writeAll(colorForOp(op));
                try writer.writeAll(text);
                try writer.writeAll(ansi.reset);
            },
            .sep => {
                try writer.writeAll(ansi.yellow);
                try writer.writeAll(text);
                try writer.writeAll(ansi.reset);
            },
        }

        pos = end;
    }

    // Trailing content
    if (pos < input.len) {
        try writer.writeAll(input[pos..]);
    }
}

/// Get color for an operator
fn colorForOp(op: []const u8) []const u8 {
    if (op[0] == '|' or op[0] == '>' or op[0] == '<' or
        (op.len >= 2 and op[0] == '2' and op[1] == '>') or
        (op.len >= 2 and op[0] == '&' and op[1] == '>'))
    {
        return ansi.cyan;
    }
    if (std.mem.eql(u8, op, "&&") or std.mem.eql(u8, op, "||") or
        std.mem.eql(u8, op, "and") or std.mem.eql(u8, op, "or"))
    {
        return ansi.yellow;
    }
    if (op[0] == '&' or std.mem.startsWith(u8, op, "=>")) {
        return ansi.magenta;
    }
    return "";
}

// =============================================================================
// Tests
// =============================================================================

test "empty input" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try render(std.testing.allocator, "", buf.writer(), null);
    try std.testing.expectEqualStrings("", buf.items);
}

test "builtin command gets bold" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try render(std.testing.allocator, "cd foo", buf.writer(), null);
    // cd should be bold (valid builtin)
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ansi.bold) != null);
}

test "unknown command gets red" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try render(std.testing.allocator, "xyznonexistent123 foo", buf.writer(), null);
    // Unknown command should be red
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ansi.red) != null);
}

test "pipe gets colored" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try render(std.testing.allocator, "a | b", buf.writer(), null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ansi.cyan) != null);
}

test "string gets colored green" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try render(std.testing.allocator, "echo \"hello\"", buf.writer(), null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ansi.green) != null);
}
