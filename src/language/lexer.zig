//! Lexer: transforms shell input into a stream of tokens.
//!
//! Tokenization proceeds left-to-right, at each position trying (in order):
//! 1. Skip whitespace (spaces, tabs)
//! 2. Skip comments (`#` to end of line)
//! 3. Read separator tokens (newline, semicolon)
//! 4. Read operator tokens (longest match first: `&&`, `|>`, `=>`, etc.)
//! 5. Read word tokens (bare words, quoted strings, command substitutions)
//!
//! Operators are checked before words so that `|>foo` tokenizes as `|>` + `foo`,
//! not as a single word. The operator list in tokens.zig is ordered by length
//! (descending) to ensure longest-match-first behavior.
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

    fn advance(self: *Lexer) void {
        if (self.pos >= self.input.len) return;
        const c = self.input[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\t' => self.advance(),
                else => break,
            }
        }
    }

    fn trySkipComment(self: *Lexer) bool {
        if (self.peek() != '#') return false;
        while (self.peek()) |c| {
            if (c == '\n') break;
            self.advance();
        }
        return true;
    }

    fn isWordBreak(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == ';';
    }

    fn tryReadOperator(self: *Lexer, tokens: ?*std.ArrayListUnmanaged(Token)) LexError!bool {
        for (token_types.operators) |op| {
            if (self.peekN(op.len)) |s| {
                if (std.mem.eql(u8, s, op)) {
                    if (tokens) |toks| {
                        const start_line = self.line;
                        const start_col = self.col;
                        const start_pos = self.pos;
                        for (0..op.len) |_| {
                            self.advance();
                        }
                        const span: TokenSpan = .{
                            .start_line = start_line,
                            .start_col = start_col,
                            .end_line = self.line,
                            .end_col = self.col,
                            .start_index = start_pos,
                            .end_index = self.pos,
                        };
                        try toks.append(self.allocator, Token.initOp(op, span));
                    }
                    return true;
                }
            }
        }
        return false;
    }

    fn tryReadSeparator(self: *Lexer, tokens: *std.ArrayListUnmanaged(Token)) LexError!bool {
        const c = self.peek() orelse return false;
        const sep: []const u8 = switch (c) {
            '\n' => "\n",
            ';' => ";",
            else => return false,
        };
        const span: TokenSpan = .{
            .start_line = self.line,
            .start_col = self.col,
            .end_line = self.line,
            .end_col = self.col + 1,
            .start_index = self.pos,
            .end_index = self.pos + 1,
        };
        self.advance();
        try tokens.append(self.allocator, Token.initSep(sep, span));
        return true;
    }

    /// Handle escape sequences inside double-quoted strings.
    /// Processes the character after a backslash and appends the result to buf.
    fn handleDoubleQuotedEscape(self: *Lexer, buf: *std.ArrayListUnmanaged(u8)) LexError!void {
        const next = self.peek() orelse {
            try buf.append(self.allocator, '\\');
            return;
        };
        const char: u8 = switch (next) {
            '"', '\\' => next,
            'n' => '\n',
            't' => '\t',
            '$' => {
                try buf.append(self.allocator, '\\');
                try buf.append(self.allocator, '$');
                self.advance();
                return;
            },
            else => {
                try buf.append(self.allocator, '\\');
                try buf.append(self.allocator, next);
                self.advance();
                return;
            },
        };
        try buf.append(self.allocator, char);
        self.advance();
    }

    fn readSingleQuoted(self: *Lexer, segs: *std.ArrayListUnmanaged(WordPart)) LexError!void {
        self.advance();
        const start = self.pos;

        while (self.peek()) |c| {
            if (c == '\'') {
                const content = self.input[start..self.pos];
                self.advance();
                try segs.append(self.allocator, .{ .quotes = .single, .text = content });
                return;
            }
            self.advance();
        }
        return LexError.UnterminatedString;
    }

    fn readDoubleQuoted(self: *Lexer, segs: *std.ArrayListUnmanaged(WordPart), buf: *std.ArrayListUnmanaged(u8)) LexError!void {
        self.advance();
        buf.clearRetainingCapacity();

        while (self.peek()) |c| {
            if (c == '"') {
                self.advance();
                const content = try self.allocator.dupe(u8, buf.items);
                try segs.append(self.allocator, .{ .quotes = .double, .text = content });
                return;
            } else if (c == '\\') {
                self.advance();
                try self.handleDoubleQuotedEscape(buf);
            } else {
                try buf.append(self.allocator, c);
                self.advance();
            }
        }
        return LexError.UnterminatedString;
    }

    fn readBareWord(self: *Lexer, segs: *std.ArrayListUnmanaged(WordPart), buf: *std.ArrayListUnmanaged(u8)) LexError!bool {
        buf.clearRetainingCapacity();

        while (self.peek()) |c| {
            if (try self.tryReadOperator(null)) break;

            if (c == '\\') {
                self.advance();
                if (self.peek()) |next| {
                    if (next == '$') {
                        // Preserve escape so expansion treats `$` literally.
                        try buf.append(self.allocator, '\\');
                        try buf.append(self.allocator, '$');
                    } else {
                        try buf.append(self.allocator, next);
                    }
                    self.advance();
                } else {
                    try buf.append(self.allocator, '\\');
                }
            } else if (c == '"' or c == '\'') {
                break;
            } else if (isWordBreak(c)) {
                break;
            } else if (c == '$' and self.peekAt(1) == '(') {
                // Command substitution: read $(...)  with paren matching
                try buf.append(self.allocator, '$');
                self.advance();
                try buf.append(self.allocator, '(');
                self.advance();

                var depth: usize = 1;
                while (self.peek()) |ch| {
                    if (ch == '(') {
                        depth += 1;
                    } else if (ch == ')') {
                        depth -= 1;
                        if (depth == 0) {
                            try buf.append(self.allocator, ')');
                            self.advance();
                            break;
                        }
                    }
                    try buf.append(self.allocator, ch);
                    self.advance();
                } else {
                    return LexError.UnterminatedCmdSub;
                }
            } else {
                try buf.append(self.allocator, c);
                self.advance();
            }
        }

        if (buf.items.len > 0) {
            const content = try self.allocator.dupe(u8, buf.items);
            try segs.append(self.allocator, .{ .quotes = .none, .text = content });
            return true;
        }
        return false;
    }

    fn readWord(self: *Lexer, tokens: *std.ArrayListUnmanaged(Token)) LexError!void {
        var parts: std.ArrayListUnmanaged(WordPart) = .empty;
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer buffer.deinit(self.allocator);

        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;

        while (self.peek()) |c| {
            if (c == '"') {
                try self.readDoubleQuoted(&parts, &buffer);
            } else if (c == '\'') {
                try self.readSingleQuoted(&parts);
            } else if (isWordBreak(c)) {
                break;
            } else if (try self.tryReadOperator(null)) {
                break;
            } else {
                const read_something = try self.readBareWord(&parts, &buffer);
                if (!read_something) break;
            }
        }

        if (parts.items.len > 0) {
            // Note: We no longer auto-promote text operators (like 'and', 'or', 'if', 'else', 'end', 'fun')
            // to op tokens here. The parser checks for keywords contextually using isKeyword().
            // This allows these words to appear as regular arguments: echo if and else
            const span: TokenSpan = .{
                .start_line = start_line,
                .start_col = start_col,
                .end_line = self.line,
                .end_col = self.col,
                .start_index = start_pos,
                .end_index = self.pos,
            };

            const parts_slice = try parts.toOwnedSlice(self.allocator);
            try tokens.append(self.allocator, Token.initWord(parts_slice, span));
        }
    }

    pub fn tokenize(self: *Lexer) LexError![]Token {
        var tokens: std.ArrayListUnmanaged(Token) = .empty;

        while (self.pos < self.input.len) {
            // Skip whitespace and comments
            self.skipWhitespace();
            if (self.peek() == null) break;
            if (self.trySkipComment()) continue;

            // Try reading operators and separators
            if (try self.tryReadSeparator(&tokens)) continue;
            if (try self.tryReadOperator(&tokens)) continue;

            // Read the next word
            try self.readWord(&tokens);
        }

        return try tokens.toOwnedSlice(self.allocator);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectTokenKind(tok: Token, expected: std.meta.Tag(token_types.TokenKind)) !void {
    try testing.expectEqual(expected, std.meta.activeTag(tok.kind));
}

fn expectBareSegText(segs: []const WordPart, expected: []const u8) !void {
    if (segs.len == 1 and segs[0].quotes == .none) {
        try testing.expectEqualStrings(expected, segs[0].text);
        return;
    }
    return error.TestExpectedEqual;
}

test "Words: simple bare words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo hello world");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try expectTokenKind(tokens[0], .word);
    try expectTokenKind(tokens[1], .word);
    try expectTokenKind(tokens[2], .word);
    try expectBareSegText(tokens[0].kind.word, "echo");
    try expectBareSegText(tokens[1].kind.word, "hello");
    try expectBareSegText(tokens[2].kind.word, "world");
}

test "Words: single quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo 'hello world'");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    const segs = tokens[1].kind.word;
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqual(QuoteKind.single, segs[0].quotes);
    try testing.expectEqualStrings("hello world", segs[0].text);
}

test "Words: double quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo \"hello world\"");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    const segs = tokens[1].kind.word;
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqual(QuoteKind.double, segs[0].quotes);
    try testing.expectEqualStrings("hello world", segs[0].text);
}

test "Words: mixed quote segments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo hello\"world\"'!'");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    const segs = tokens[1].kind.word;
    try testing.expectEqual(@as(usize, 3), segs.len);
    try testing.expectEqual(QuoteKind.none, segs[0].quotes);
    try testing.expectEqualStrings("hello", segs[0].text);
    try testing.expectEqual(QuoteKind.double, segs[1].quotes);
    try testing.expectEqualStrings("world", segs[1].text);
    try testing.expectEqual(QuoteKind.single, segs[2].quotes);
    try testing.expectEqualStrings("!", segs[2].text);
}

test "Escapes: sequences in double quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo \"hello\\nworld\\t!\"");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    const segs = tokens[1].kind.word;
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqualStrings("hello\nworld\t!", segs[0].text);
}

test "Escapes: quote in double quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo \"say \\\"hi\\\"\"");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    const segs = tokens[1].kind.word;
    try testing.expectEqualStrings("say \"hi\"", segs[0].text);
}

test "Escapes: dollar in bare word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo \\$HOME");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    // The lexer preserves \$ for the expander to handle
    try testing.expectEqualStrings("\\$HOME", tokens[1].kind.word[0].text);
}

test "Command substitution: basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo $(whoami)");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try expectBareSegText(tokens[1].kind.word, "$(whoami)");
}

test "Command substitution: nested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo $(dirname $(pwd))");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try expectBareSegText(tokens[1].kind.word, "$(dirname $(pwd))");
}

test "Operators: pipe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "cat file | grep foo");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2], .operator);
    try testing.expectEqualStrings("|", tokens[2].kind.operator);
}

test "Operators: pipe arrow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "cat file |> grep foo");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2], .operator);
    try testing.expectEqualStrings("|>", tokens[2].kind.operator);
}

test "Operators: logical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "true && echo ok || echo fail");
    const tokens = try lex.tokenize();

    try testing.expectEqualStrings("&&", tokens[1].kind.operator);
    try testing.expectEqualStrings("||", tokens[4].kind.operator);
}

test "Operators: text logical as words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "true and echo ok or echo fail");
    const tokens = try lex.tokenize();

    // Text operators are now lexed as words, not ops
    // The parser checks for them contextually
    try expectTokenKind(tokens[1], .word);
    try expectTokenKind(tokens[4], .word);
    try testing.expectEqualStrings("and", tokens[1].kind.word[0].text);
    try testing.expectEqualStrings("or", tokens[4].kind.word[0].text);
}

test "Operators: background" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "sleep 1 & echo done");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2], .operator);
    try testing.expectEqualStrings("&", tokens[2].kind.operator);
}

test "Operators: capture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo hi => out");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 4), tokens.len);
    try expectTokenKind(tokens[2], .operator);
    try testing.expectEqualStrings("=>", tokens[2].kind.operator);
}

test "Operators: capture lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "ls =>@ files");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try expectTokenKind(tokens[1], .operator);
    try testing.expectEqualStrings("=>@", tokens[1].kind.operator);
}

test "Operators: redirections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "cmd < in > out >> append 2> err 2>&1");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 10), tokens.len);
    try testing.expectEqualStrings("<", tokens[1].kind.operator);
    try testing.expectEqualStrings(">", tokens[3].kind.operator);
    try testing.expectEqualStrings(">>", tokens[5].kind.operator);
    try testing.expectEqualStrings("2>", tokens[7].kind.operator);
    try testing.expectEqualStrings("2>&1", tokens[9].kind.operator);
}

test "Operators: adjacent to word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo|cat");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try expectBareSegText(tokens[0].kind.word, "echo");
    try testing.expectEqualStrings("|", tokens[1].kind.operator);
    try expectBareSegText(tokens[2].kind.word, "cat");
}

test "Separators: semicolon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo a; echo b");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2], .separator);
}

test "Separators: newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo a\necho b");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2], .separator);
    try testing.expectEqualStrings("\n", tokens[2].kind.separator);
}

test "Comments: trailing comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo hello # this is a comment");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
}

test "Comments: hash inside bare word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo foo#bar");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try expectTokenKind(tokens[1], .word);
    try expectBareSegText(tokens[1].kind.word, "foo#bar");
}

test "Edge cases: empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "");
    const tokens = try lex.tokenize();
    try testing.expectEqual(@as(usize, 0), tokens.len);
}

test "Edge cases: whitespace only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "   \t  ");
    const tokens = try lex.tokenize();

    try testing.expectEqual(@as(usize, 0), tokens.len);
}

test "Errors: unterminated single quote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo 'hello");
    try testing.expectError(LexError.UnterminatedString, lex.tokenize());
}

test "Errors: unterminated double quote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo \"hello");
    try testing.expectError(LexError.UnterminatedString, lex.tokenize());
}

test "Errors: unterminated command substitution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lex = Lexer.init(arena.allocator(), "echo $(whoami");
    try testing.expectError(LexError.UnterminatedCmdSub, lex.tokenize());
}
