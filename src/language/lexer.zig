//! Lexer: transforms shell input into a stream of tokens.
//!
//! The lexer handles:
//! - Word tokenization with quoting (bare, single-quoted, double-quoted)
//! - Operator recognition (pipes, redirections, logical operators, capture)
//! - Escape sequences in double-quoted and bare contexts
//! - Command substitution delimiters `$(...)`
//! - Comments (lines starting with `#`)
//!
//! Each token includes a `TokenSpan` with source location for error reporting.

const std = @import("std");
const token_types = @import("tokens.zig");
const Token = token_types.Token;
const WordPart = token_types.WordPart;
const QuoteKind = token_types.QuoteKind;
const TokenSpan = token_types.TokenSpan;

pub const LexError = error{
    UnterminatedString,
    UnterminatedCmdSub,
    InvalidEscape,
    OutOfMemory,
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    line: usize,
    col: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Lexer {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .col = 1,
            .allocator = allocator,
        };
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn peekAt(self: *Lexer, offset: usize) ?u8 {
        if (self.pos + offset >= self.input.len) return null;
        return self.input[self.pos + offset];
    }

    fn peekN(self: *Lexer, n: usize) ?[]const u8 {
        if (self.pos + n > self.input.len) return null;
        return self.input[self.pos .. self.pos + n];
    }

    fn advance(self: *Lexer) ?u8 {
        if (self.pos >= self.input.len) return null;
        const c = self.input[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t') {
                _ = self.advance();
            } else {
                break;
            }
        }
    }

    fn isCommentStart(self: *Lexer, at_token_start: bool) bool {
        if (self.peek() != '#') return false;
        return at_token_start;
    }

    fn skipComment(self: *Lexer) void {
        while (self.peek()) |c| {
            if (c == '\n') break;
            _ = self.advance();
        }
    }

    fn tryMatchOperator(self: *Lexer) ?[]const u8 {
        for (token_types.operators) |op| {
            if (self.peekN(op.len)) |s| {
                if (std.mem.eql(u8, s, op)) {
                    return op;
                }
            }
        }
        return null;
    }

    fn readSingleQuoted(self: *Lexer, segs: *std.ArrayListUnmanaged(WordPart)) LexError!void {
        _ = self.advance();
        const start = self.pos;

        while (self.peek()) |c| {
            if (c == '\'') {
                const content = self.input[start..self.pos];
                _ = self.advance();
                segs.append(self.allocator, .{ .q = .sq, .t = content }) catch return LexError.OutOfMemory;
                return;
            }
            _ = self.advance();
        }
        return LexError.UnterminatedString;
    }

    fn readDoubleQuoted(self: *Lexer, segs: *std.ArrayListUnmanaged(WordPart), buf: *std.ArrayListUnmanaged(u8)) LexError!void {
        _ = self.advance();
        buf.clearRetainingCapacity();

        while (self.peek()) |c| {
            if (c == '"') {
                _ = self.advance();
                const content = self.allocator.dupe(u8, buf.items) catch return LexError.OutOfMemory;
                segs.append(self.allocator, .{ .q = .dq, .t = content }) catch return LexError.OutOfMemory;
                return;
            } else if (c == '\\') {
                _ = self.advance();
                if (self.peek()) |next| {
                    switch (next) {
                        '"' => {
                            buf.append(self.allocator, '"') catch return LexError.OutOfMemory;
                            _ = self.advance();
                        },
                        '\\' => {
                            buf.append(self.allocator, '\\') catch return LexError.OutOfMemory;
                            _ = self.advance();
                        },
                        'n' => {
                            buf.append(self.allocator, '\n') catch return LexError.OutOfMemory;
                            _ = self.advance();
                        },
                        't' => {
                            buf.append(self.allocator, '\t') catch return LexError.OutOfMemory;
                            _ = self.advance();
                        },
                        '$' => {
                            buf.append(self.allocator, '\\') catch return LexError.OutOfMemory;
                            buf.append(self.allocator, '$') catch return LexError.OutOfMemory;
                            _ = self.advance();
                        },
                        else => {
                            buf.append(self.allocator, '\\') catch return LexError.OutOfMemory;
                            buf.append(self.allocator, next) catch return LexError.OutOfMemory;
                            _ = self.advance();
                        },
                    }
                } else {
                    buf.append(self.allocator, '\\') catch return LexError.OutOfMemory;
                }
            } else {
                buf.append(self.allocator, c) catch return LexError.OutOfMemory;
                _ = self.advance();
            }
        }
        return LexError.UnterminatedString;
    }

    fn readBareWord(self: *Lexer, segs: *std.ArrayListUnmanaged(WordPart), buf: *std.ArrayListUnmanaged(u8)) LexError!bool {
        buf.clearRetainingCapacity();

        while (self.peek()) |c| {
            if (self.tryMatchOperator()) |_| break;

            if (c == '\\') {
                _ = self.advance();
                if (self.peek()) |next| {
                    if (next == '$') {
                        // Preserve escape so expansion treats `$` literally.
                        buf.append(self.allocator, '\\') catch return LexError.OutOfMemory;
                        buf.append(self.allocator, '$') catch return LexError.OutOfMemory;
                    } else {
                        buf.append(self.allocator, next) catch return LexError.OutOfMemory;
                    }
                    _ = self.advance();
                } else {
                    buf.append(self.allocator, '\\') catch return LexError.OutOfMemory;
                }
            } else if (c == '"' or c == '\'') {
                break;
            } else if (c == ' ' or c == '\t' or c == '\n' or c == ';' or c == '#') {
                break;
            } else if (c == '$' and self.peekAt(1) == '(') {
                // Command substitution: read $(...)  with paren matching
                buf.append(self.allocator, '$') catch return LexError.OutOfMemory;
                _ = self.advance();
                buf.append(self.allocator, '(') catch return LexError.OutOfMemory;
                _ = self.advance();

                var depth: usize = 1;
                while (self.peek()) |ch| {
                    if (ch == '(') {
                        depth += 1;
                    } else if (ch == ')') {
                        depth -= 1;
                        if (depth == 0) {
                            buf.append(self.allocator, ')') catch return LexError.OutOfMemory;
                            _ = self.advance();
                            break;
                        }
                    }
                    buf.append(self.allocator, ch) catch return LexError.OutOfMemory;
                    _ = self.advance();
                } else {
                    return LexError.UnterminatedCmdSub;
                }
            } else {
                buf.append(self.allocator, c) catch return LexError.OutOfMemory;
                _ = self.advance();
            }
        }

        if (buf.items.len > 0) {
            const content = self.allocator.dupe(u8, buf.items) catch return LexError.OutOfMemory;
            segs.append(self.allocator, .{ .q = .bare, .t = content }) catch return LexError.OutOfMemory;
            return true;
        }
        return false;
    }

    fn readWord(self: *Lexer, tokens: *std.ArrayListUnmanaged(Token)) LexError!void {
        var segs: std.ArrayListUnmanaged(WordPart) = .empty;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;

        while (self.peek()) |c| {
            if (c == '"') {
                try self.readDoubleQuoted(&segs, &buf);
            } else if (c == '\'') {
                try self.readSingleQuoted(&segs);
            } else if (c == ' ' or c == '\t' or c == '\n' or c == ';' or c == '#') {
                break;
            } else if (self.tryMatchOperator()) |_| {
                break;
            } else {
                const read_something = try self.readBareWord(&segs, &buf);
                if (!read_something) break;
            }
        }

        if (segs.items.len > 0) {
            // Note: We no longer auto-promote text operators (like 'and', 'or', 'if', 'else', 'end', 'fun')
            // to op tokens here. The parser checks for keywords contextually using isKeyword().
            // This allows these words to appear as regular arguments: echo if and else
            const span = TokenSpan.init(start_line, start_col, self.line, self.col, start_pos, self.pos);
            const segs_slice = segs.toOwnedSlice(self.allocator) catch return LexError.OutOfMemory;
            tokens.append(self.allocator, Token.initWord(segs_slice, span)) catch return LexError.OutOfMemory;
        }
    }

    pub fn tokenize(self: *Lexer) LexError![]Token {
        var tokens: std.ArrayListUnmanaged(Token) = .empty;

        while (self.pos < self.input.len) {
            self.skipWhitespace();

            if (self.peek() == null) break;

            if (self.isCommentStart(true)) {
                self.skipComment();
                continue;
            }

            if (self.peek() == '\n') {
                const start_pos = self.pos;
                const span = TokenSpan.init(self.line, self.col, self.line, self.col + 1, start_pos, start_pos + 1);
                _ = self.advance();
                tokens.append(self.allocator, Token.initSep("\n", span)) catch return LexError.OutOfMemory;
                continue;
            }

            if (self.peek() == ';') {
                const start_pos = self.pos;
                const span = TokenSpan.init(self.line, self.col, self.line, self.col + 1, start_pos, start_pos + 1);
                _ = self.advance();
                tokens.append(self.allocator, Token.initSep(";", span)) catch return LexError.OutOfMemory;
                continue;
            }

            if (self.tryMatchOperator()) |op| {
                const start_line = self.line;
                const start_col = self.col;
                const start_pos = self.pos;
                for (0..op.len) |_| {
                    _ = self.advance();
                }
                const span = TokenSpan.init(start_line, start_col, self.line, self.col, start_pos, self.pos);
                tokens.append(self.allocator, Token.initOp(op, span)) catch return LexError.OutOfMemory;
                continue;
            }

            try self.readWord(&tokens);
        }

        return tokens.toOwnedSlice(self.allocator) catch return LexError.OutOfMemory;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectTokenKind(actual: token_types.TokenKind, expected: token_types.TokenKind) !void {
    try testing.expectEqual(expected, actual);
}

fn expectBareSegText(segs: ?[]const WordPart, expected: []const u8) !void {
    if (segs) |s| {
        if (s.len == 1 and s[0].q == .bare) {
            try testing.expectEqualStrings(expected, s[0].t);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "simple words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo hello world");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try expectTokenKind(tokens[0].kind(), .word);
    try expectTokenKind(tokens[1].kind(), .word);
    try expectTokenKind(tokens[2].kind(), .word);
    try expectBareSegText(tokens[0].parts(), "echo");
    try expectBareSegText(tokens[1].parts(), "hello");
    try expectBareSegText(tokens[2].parts(), "world");
}

test "single quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo 'hello world'");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    if (tokens[1].parts()) |segs| {
        try testing.expectEqual(@as(usize, 1), segs.len);
        try testing.expectEqual(QuoteKind.sq, segs[0].q);
        try testing.expectEqualStrings("hello world", segs[0].t);
    } else {
        return error.TestExpectedEqual;
    }
}

test "double quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo \"hello world\"");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    if (tokens[1].parts()) |segs| {
        try testing.expectEqual(@as(usize, 1), segs.len);
        try testing.expectEqual(QuoteKind.dq, segs[0].q);
        try testing.expectEqualStrings("hello world", segs[0].t);
    } else {
        return error.TestExpectedEqual;
    }
}

test "pipe operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "cat file | grep foo");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2].kind(), .op);
    try testing.expectEqualStrings("|", tokens[2].text().?);
}

test "pipe arrow operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "cat file |> grep foo");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2].kind(), .op);
    try testing.expectEqualStrings("|>", tokens[2].text().?);
}

test "capture operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo hi => out");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 4), tokens.len);
    try expectTokenKind(tokens[2].kind(), .op);
    try testing.expectEqualStrings("=>", tokens[2].text().?);
}

test "capture lines operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "ls =>@ files");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try expectTokenKind(tokens[1].kind(), .op);
    try testing.expectEqualStrings("=>@", tokens[1].text().?);
}

test "redirection operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "cmd < in > out >> append 2> err 2>&1");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 10), tokens.len);
    try testing.expectEqualStrings("<", tokens[1].text().?);
    try testing.expectEqualStrings(">", tokens[3].text().?);
    try testing.expectEqualStrings(">>", tokens[5].text().?);
    try testing.expectEqualStrings("2>", tokens[7].text().?);
    try testing.expectEqualStrings("2>&1", tokens[9].text().?);
}

test "logical operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "true && echo ok || echo fail");
    const tokens = try lex.tokenize();

    try testing.expectEqualStrings("&&", tokens[1].text().?);
    try testing.expectEqualStrings("||", tokens[4].text().?);
}

test "text logical operators as words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "true and echo ok or echo fail");
    const tokens = try lex.tokenize();

    // Text operators are now lexed as words, not ops
    // The parser checks for them contextually
    try expectTokenKind(tokens[1].kind(), .word);
    try expectTokenKind(tokens[4].kind(), .word);
    // But we can still extract the text
    if (tokens[1].parts()) |segs| {
        try testing.expectEqualStrings("and", segs[0].t);
    }
    if (tokens[4].parts()) |segs| {
        try testing.expectEqualStrings("or", segs[0].t);
    }
}

test "semicolon separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo a; echo b");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2].kind(), .sep);
}

test "background operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "sleep 1 & echo done");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2].kind(), .op);
    try testing.expectEqualStrings("&", tokens[2].text().?);
}

test "comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo hello # this is a comment");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
}
