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
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Lexer {
        return .{
            .input = input,
            .pos = 0,
            .allocator = allocator,
        };
    }

    // =========================================================================
    // Input navigation helpers
    // =========================================================================

    /// Checks if the position plus offset is within bounds of the input.
    inline fn isInBounds(self: *const Lexer, offset: usize) bool {
        return self.pos + offset < self.input.len;
    }

    /// Returns the character at the current position, or null if at end of input.
    inline fn peek(self: *const Lexer) ?u8 {
        return self.peekAt(0);
    }

    /// Returns the character at `offset` positions ahead, or null if out of bounds.
    inline fn peekAt(self: *const Lexer, offset: usize) ?u8 {
        return if (self.isInBounds(offset)) self.input[self.pos + offset] else null;
    }

    /// Returns a slice of `len` characters starting at current position, or null if not enough input.
    inline fn peekSlice(self: *const Lexer, len: usize) ?[]const u8 {
        return if (len == 0 or !self.isInBounds(len - 1))
            null
        else
            self.input[self.pos .. self.pos + len];
    }

    /// Advances position by one character.
    inline fn advance(self: *Lexer) void {
        self.advanceBy(1);
    }

    /// Advances position by `n` characters.
    inline fn advanceBy(self: *Lexer, n: usize) void {
        self.pos = @min(self.pos + n, self.input.len);
    }

    /// Creates a TokenSpan from `start` to current position.
    inline fn makeSpan(self: *const Lexer, start: usize) TokenSpan {
        return .{ .start = start, .end = self.pos };
    }

    // =========================================================================
    // Whitespace and comment handling
    // =========================================================================

    /// Skips spaces and tabs (not newlines - those are separators).
    fn skipWhitespace(self: *Lexer) void {
        while (self.peek()) |c| {
            if (!token_types.isWhitespace(c)) break;
            self.advance();
        }
    }

    /// Skips a comment if present (from `#` to end of line). Returns true if skipped.
    fn trySkipComment(self: *Lexer) bool {
        if (self.peek() != '#') return false;
        while (self.peek()) |c| {
            if (c == '\n') break;
            self.advance();
        }
        return true;
    }

    // =========================================================================
    // Operator handling
    // =========================================================================

    /// Checks if an operator starts at the current position. Returns the operator or null.
    fn peekOperator(self: *const Lexer) ?[]const u8 {
        for (token_types.operators) |op| {
            if (self.peekSlice(op.len)) |s| {
                if (std.mem.eql(u8, s, op)) return op;
            }
        }
        return null;
    }

    /// Reads an operator token if present. Returns true if an operator was read.
    fn tryReadOperator(self: *Lexer, tokens: *std.ArrayListUnmanaged(Token)) error{OutOfMemory}!bool {
        const op = self.peekOperator() orelse return false;
        const start = self.pos;
        self.advanceBy(op.len);
        try tokens.append(self.allocator, Token.initOp(op, self.makeSpan(start)));
        return true;
    }

    /// Reads a separator token (newline or semicolon) if present. Returns true if read.
    fn tryReadSeparator(self: *Lexer, tokens: *std.ArrayListUnmanaged(Token)) error{OutOfMemory}!bool {
        const c = self.peek() orelse return false;
        if (!token_types.isSeparator(c)) return false;
        const sep: []const u8 = if (c == '\n') "\n" else ";";
        const start = self.pos;
        self.advance();
        try tokens.append(self.allocator, Token.initSep(sep, self.makeSpan(start)));
        return true;
    }

    // =========================================================================
    // Escape sequence handling
    // =========================================================================

    /// Handles escape sequences in double-quoted strings.
    /// Processes the character after a backslash and appends the result to buf.
    fn handleDoubleQuotedEscape(self: *Lexer, buf: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
        const next = self.peek() orelse {
            try buf.append(self.allocator, '\\');
            return;
        };

        switch (next) {
            '"', '\\' => {
                try buf.append(self.allocator, next);
                self.advance();
            },
            'n' => {
                try buf.append(self.allocator, '\n');
                self.advance();
            },
            't' => {
                try buf.append(self.allocator, '\t');
                self.advance();
            },
            '$' => {
                // Preserve escape so expansion treats `$` literally
                try buf.appendSlice(self.allocator, "\\$");
                self.advance();
            },
            else => {
                // Unknown escape: preserve both characters
                try buf.appendSlice(self.allocator, &.{ '\\', next });
                self.advance();
            },
        }
    }

    /// Handles escape sequences in bare words.
    /// Simpler than double-quoted: only `\$` is special (preserved for expander).
    fn handleBareWordEscape(self: *Lexer, buf: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
        const next = self.peek() orelse {
            try buf.append(self.allocator, '\\');
            return;
        };

        if (next == '$') {
            // Preserve escape so expansion treats `$` literally
            try buf.appendSlice(self.allocator, "\\$");
        } else {
            // Other escapes: just append the escaped character
            try buf.append(self.allocator, next);
        }
        self.advance();
    }

    // =========================================================================
    // Command substitution handling
    // =========================================================================

    /// Reads a command substitution `$(...)` with nested parenthesis matching.
    /// Assumes we're positioned at the `$` of `$(`.
    fn readCommandSubstitution(self: *Lexer, buf: *std.ArrayListUnmanaged(u8)) (error{OutOfMemory} || LexError)!void {
        std.debug.assert(self.peek() == '$');
        std.debug.assert(self.peekAt(1) == '(');

        try buf.appendSlice(self.allocator, "$(");
        self.advanceBy(2); // skip `$(`

        try self.readParenContent(buf);
    }

    /// Reads a bare command substitution `(...)` and normalizes to `$(...)`.
    /// Assumes we're positioned at the opening `(`.
    fn readBareCommandSubstitution(self: *Lexer, buf: *std.ArrayListUnmanaged(u8)) (error{OutOfMemory} || LexError)!void {
        std.debug.assert(self.peek() == '(');

        // Normalize to $(...) so expander can use the same logic
        try buf.appendSlice(self.allocator, "$(");
        self.advance(); // skip `(`

        try self.readParenContent(buf);
    }

    /// Reads the content inside parentheses with nested paren matching.
    /// Assumes we're positioned after the opening `(` and `$(` has been written.
    fn readParenContent(self: *Lexer, buf: *std.ArrayListUnmanaged(u8)) (error{OutOfMemory} || LexError)!void {
        var depth: usize = 1;
        while (self.peek()) |ch| {
            switch (ch) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) {
                        try buf.append(self.allocator, ')');
                        self.advance();
                        return;
                    }
                },
                // TODO: Handle escaped parens and quoted strings containing parens
                else => {},
            }
            try buf.append(self.allocator, ch);
            self.advance();
        }
        return LexError.UnterminatedCmdSub;
    }

    // =========================================================================
    // Word reading (quoted and bare)
    // =========================================================================

    /// Reads a single-quoted string (no escape processing, literal content).
    fn readSingleQuoted(self: *Lexer, parts: *std.ArrayListUnmanaged(WordPart)) (error{OutOfMemory} || LexError)!void {
        self.advance(); // skip opening quote
        const start = self.pos;

        while (self.peek()) |c| {
            if (c == '\'') {
                const content = self.input[start..self.pos];
                self.advance(); // skip closing quote
                try parts.append(self.allocator, .{ .quotes = .single, .text = content });
                return;
            }
            self.advance();
        }
        return LexError.UnterminatedString;
    }

    /// Reads a double-quoted string (with escape processing).
    fn readDoubleQuoted(self: *Lexer, parts: *std.ArrayListUnmanaged(WordPart), buf: *std.ArrayListUnmanaged(u8)) (error{OutOfMemory} || LexError)!void {
        self.advance(); // skip opening quote
        buf.clearRetainingCapacity();

        while (self.peek()) |c| {
            switch (c) {
                '"' => {
                    self.advance(); // skip closing quote
                    const content = try self.allocator.dupe(u8, buf.items);
                    try parts.append(self.allocator, .{ .quotes = .double, .text = content });
                    return;
                },
                '\\' => {
                    self.advance();
                    try self.handleDoubleQuotedEscape(buf);
                },
                else => {
                    try buf.append(self.allocator, c);
                    self.advance();
                },
            }
        }
        return LexError.UnterminatedString;
    }

    /// Reads an unquoted (bare) word segment.
    /// Returns true if any content was read.
    fn readBareWord(self: *Lexer, parts: *std.ArrayListUnmanaged(WordPart), buf: *std.ArrayListUnmanaged(u8)) (error{OutOfMemory} || LexError)!bool {
        buf.clearRetainingCapacity();

        while (self.peek()) |c| {
            // Stop at word breaks and operators
            if (token_types.isWordBreak(c)) break;
            if (self.peekOperator() != null) break;

            switch (c) {
                '\\' => {
                    self.advance();
                    try self.handleBareWordEscape(buf);
                },
                '"', '\'' => break, // Quote starts new segment
                '$' => {
                    if (self.peekAt(1) == '(') {
                        try self.readCommandSubstitution(buf);
                    } else {
                        try buf.append(self.allocator, c);
                        self.advance();
                    }
                },
                '(' => {
                    // Bare paren command substitution: (cmd) → normalized to $(cmd)
                    try self.readBareCommandSubstitution(buf);
                },
                else => {
                    try buf.append(self.allocator, c);
                    self.advance();
                },
            }
        }

        if (buf.items.len > 0) {
            const content = try self.allocator.dupe(u8, buf.items);
            try parts.append(self.allocator, .{ .quotes = .none, .text = content });
            return true;
        }
        return false;
    }

    /// Reads a complete word token (may contain multiple quoted/unquoted segments).
    fn readWord(self: *Lexer, tokens: *std.ArrayListUnmanaged(Token)) (error{OutOfMemory} || LexError)!void {
        var parts: std.ArrayListUnmanaged(WordPart) = .empty;
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer buffer.deinit(self.allocator);

        const start = self.pos;

        while (self.peek()) |c| {
            switch (c) {
                '"' => try self.readDoubleQuoted(&parts, &buffer),
                '\'' => try self.readSingleQuoted(&parts),
                else => {
                    if (token_types.isWordBreak(c)) break;
                    if (self.peekOperator() != null) break;
                    if (!try self.readBareWord(&parts, &buffer)) break;
                },
            }
        }

        if (parts.items.len > 0) {
            const parts_slice = try parts.toOwnedSlice(self.allocator);
            try tokens.append(self.allocator, Token.initWord(parts_slice, self.makeSpan(start)));
        }
    }

    // =========================================================================
    // Main tokenization entry point
    // =========================================================================

    pub fn tokenize(self: *Lexer) (error{OutOfMemory} || LexError)![]Token {
        var tokens: std.ArrayListUnmanaged(Token) = .empty;

        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.peek() == null) break;
            if (self.trySkipComment()) continue;

            if (try self.tryReadSeparator(&tokens)) continue;
            if (try self.tryReadOperator(&tokens)) continue;

            try self.readWord(&tokens);
        }

        return try tokens.toOwnedSlice(self.allocator);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Asserts that a token has the expected kind.
fn expectTokenKind(tok: Token, expected: std.meta.Tag(token_types.TokenKind)) !void {
    try testing.expectEqual(expected, std.meta.activeTag(tok.kind));
}

/// Asserts that a word token has a single bare segment with the expected text.
fn expectBareWord(segs: []const WordPart, expected: []const u8) !void {
    if (segs.len == 1 and segs[0].quotes == .none) {
        try testing.expectEqualStrings(expected, segs[0].text);
        return;
    }
    return error.TestExpectedEqual;
}

/// Tokenizes input and returns tokens (using arena allocator for cleanup).
fn tokenizeTest(arena: *std.heap.ArenaAllocator, input: []const u8) ![]Token {
    var lex = Lexer.init(arena.allocator(), input);
    return try lex.tokenize();
}

test "Words: simple bare words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo hello world");

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try expectTokenKind(tokens[0], .word);
    try expectTokenKind(tokens[1], .word);
    try expectTokenKind(tokens[2], .word);
    try expectBareWord(tokens[0].kind.word, "echo");
    try expectBareWord(tokens[1].kind.word, "hello");
    try expectBareWord(tokens[2].kind.word, "world");
}

test "Words: single quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo 'hello world'");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    const segs = tokens[1].kind.word;
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqual(QuoteKind.single, segs[0].quotes);
    try testing.expectEqualStrings("hello world", segs[0].text);
}

test "Words: double quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo \"hello world\"");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    const segs = tokens[1].kind.word;
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqual(QuoteKind.double, segs[0].quotes);
    try testing.expectEqualStrings("hello world", segs[0].text);
}

test "Words: mixed quote segments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo hello\"world\"'!'");

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

    const tokens = try tokenizeTest(&arena, "echo \"hello\\nworld\\t!\"");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    const segs = tokens[1].kind.word;
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqualStrings("hello\nworld\t!", segs[0].text);
}

test "Escapes: quote in double quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo \"say \\\"hi\\\"\"");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    const segs = tokens[1].kind.word;
    try testing.expectEqualStrings("say \"hi\"", segs[0].text);
}

test "Escapes: dollar in bare word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo \\$HOME");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    // The lexer preserves \$ for the expander to handle
    try testing.expectEqualStrings("\\$HOME", tokens[1].kind.word[0].text);
}

test "Command substitution: basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo $(whoami)");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try expectBareWord(tokens[1].kind.word, "$(whoami)");
}

test "Command substitution: nested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo $(dirname $(pwd))");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try expectBareWord(tokens[1].kind.word, "$(dirname $(pwd))");
}

test "Bare paren command substitution: basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo (whoami)");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    // Bare parens get normalized to $(...)
    try expectBareWord(tokens[1].kind.word, "$(whoami)");
}

test "Bare paren command substitution: nested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo (dirname (pwd))");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try expectBareWord(tokens[1].kind.word, "$(dirname (pwd))");
}

test "Bare paren command substitution: with pipe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo (ls | head)");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    // Pipe should be captured inside the parens, not as separate operator
    try expectBareWord(tokens[1].kind.word, "$(ls | head)");
}

test "Bare paren command substitution: concatenation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "file_(date).txt");

    try testing.expectEqual(@as(usize, 1), tokens.len);
    try expectBareWord(tokens[0].kind.word, "file_$(date).txt");
}

test "Operators: pipe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "cat file | grep foo");

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2], .operator);
    try testing.expectEqualStrings("|", tokens[2].kind.operator);
}

test "Operators: pipe arrow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "cat file |> grep foo");

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2], .operator);
    try testing.expectEqualStrings("|>", tokens[2].kind.operator);
}

test "Operators: logical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "true && echo ok || echo fail");

    try testing.expectEqualStrings("&&", tokens[1].kind.operator);
    try testing.expectEqualStrings("||", tokens[4].kind.operator);
}

test "Operators: text logical as words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "true and echo ok or echo fail");

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

    const tokens = try tokenizeTest(&arena, "sleep 1 & echo done");

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2], .operator);
    try testing.expectEqualStrings("&", tokens[2].kind.operator);
}

test "Operators: capture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo hi => out");

    try testing.expectEqual(@as(usize, 4), tokens.len);
    try expectTokenKind(tokens[2], .operator);
    try testing.expectEqualStrings("=>", tokens[2].kind.operator);
}

test "Operators: capture lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "ls =>@ files");

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try expectTokenKind(tokens[1], .operator);
    try testing.expectEqualStrings("=>@", tokens[1].kind.operator);
}

test "Operators: redirections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "cmd < in > out >> append 2> err 2>&1");

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

    const tokens = try tokenizeTest(&arena, "echo|cat");

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try expectBareWord(tokens[0].kind.word, "echo");
    try testing.expectEqualStrings("|", tokens[1].kind.operator);
    try expectBareWord(tokens[2].kind.word, "cat");
}

test "Separators: semicolon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo a; echo b");

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2], .separator);
}

test "Separators: newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo a\necho b");

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try expectTokenKind(tokens[2], .separator);
    try testing.expectEqualStrings("\n", tokens[2].kind.separator);
}

test "Comments: trailing comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo hello # this is a comment");

    try testing.expectEqual(@as(usize, 2), tokens.len);
}

test "Comments: hash inside bare word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "echo foo#bar");

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try expectTokenKind(tokens[1], .word);
    try expectBareWord(tokens[1].kind.word, "foo#bar");
}

test "Edge cases: empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "");
    try testing.expectEqual(@as(usize, 0), tokens.len);
}

test "Edge cases: whitespace only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try tokenizeTest(&arena, "   \t  ");

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
