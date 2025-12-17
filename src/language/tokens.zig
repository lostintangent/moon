//! Token types and related definitions for the Oshen shell lexer.
//!
//! Type hierarchy:
//! - `Token`: a lexical unit produced by the lexer, containing:
//!   - `TokenSpan`: source position (line/column and byte indices)
//!   - `TokenData`: one of word, operator, or separator
//! - `WordPart`: a segment of a word token with its quoting context
//!   (e.g., `hello"world"` produces two WordParts: one bare, one double-quoted)
//!
//! Also provides operator/keyword tables for O(1) lookups.

const std = @import("std");

pub const QuoteKind = enum {
    bare,
    dq, // double quotes
    sq, // single quotes
};

pub const WordPart = struct {
    q: QuoteKind,
    t: []const u8,

    pub fn eql(self: WordPart, other: WordPart) bool {
        return self.q == other.q and std.mem.eql(u8, self.t, other.t);
    }
};

/// Source location for a token.
///
/// Contains both line/column positions (for human-readable error messages) and
/// byte indices (for O(1) source slicing). Currently only byte indices are used;
/// line/column will be used for error reporting and debugging in the future.
pub const TokenSpan = struct {
    start_line: usize,
    start_col: usize,
    end_line: usize,
    end_col: usize,
    start_index: usize,
    end_index: usize,

    pub fn init(start_line: usize, start_col: usize, end_line: usize, end_col: usize, start_index: usize, end_index: usize) TokenSpan {
        return .{
            .start_line = start_line,
            .start_col = start_col,
            .end_line = end_line,
            .end_col = end_col,
            .start_index = start_index,
            .end_index = end_index,
        };
    }
};

pub const TokenKind = enum {
    word,
    op,
    sep,
};

/// Token data - tagged union for type-safe access
pub const TokenData = union(TokenKind) {
    word: []const WordPart,
    op: []const u8,
    sep: []const u8,
};

pub const Token = struct {
    data: TokenData,
    span: TokenSpan,

    pub fn initWord(word_parts: []const WordPart, tok_span: TokenSpan) Token {
        return .{ .data = .{ .word = word_parts }, .span = tok_span };
    }

    pub fn initOp(op_text: []const u8, tok_span: TokenSpan) Token {
        return .{ .data = .{ .op = op_text }, .span = tok_span };
    }

    pub fn initSep(sep_text: []const u8, tok_span: TokenSpan) Token {
        return .{ .data = .{ .sep = sep_text }, .span = tok_span };
    }

    /// Get the token kind
    pub fn kind(self: Token) TokenKind {
        return self.data;
    }

    /// Get word parts (only valid for word tokens)
    pub fn parts(self: Token) ?[]const WordPart {
        return switch (self.data) {
            .word => |p| p,
            else => null,
        };
    }

    /// Get text (only valid for op/sep tokens)
    pub fn text(self: Token) ?[]const u8 {
        return switch (self.data) {
            .op => |t| t,
            .sep => |t| t,
            .word => null,
        };
    }
};

// Operators recognized by the lexer
pub const operators = [_][]const u8{
    "=>@", "2>&1", "2>>", "&>", "|>", "&&", "||", "=>", "2>", ">>", "|", "&", "<", ">",
};

pub const keywords = [_][]const u8{ "and", "or", "fun", "end", "if", "else", "for", "in", "while", "break", "continue", "return" };

/// Check if a word is a keyword
pub fn isKeyword(word: []const u8) bool {
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// Compile-time set for O(1) redirection operator lookup
pub const redir_ops = std.StaticStringMap(void).initComptime(.{
    .{ "<", {} },
    .{ ">", {} },
    .{ ">>", {} },
    .{ "2>", {} },
    .{ "2>>", {} },
    .{ "&>", {} },
    .{ "2>&1", {} },
});

/// Compile-time set for O(1) pipe operator lookup
pub const pipe_ops = std.StaticStringMap(void).initComptime(.{
    .{ "|", {} },
    .{ "|>", {} },
});

/// Compile-time set for O(1) logical operator lookup
pub const logical_ops = std.StaticStringMap(void).initComptime(.{
    .{ "and", {} },
    .{ "or", {} },
    .{ "&&", {} },
    .{ "||", {} },
});

/// Check if a character is valid in an identifier (variable names, etc.)
pub fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Check if a character can start an identifier
pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
