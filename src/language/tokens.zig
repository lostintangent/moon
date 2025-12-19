//! Token types and related definitions for the Oshen shell lexer.
//!
//! Type hierarchy:
//! - `Token`: A lexical unit produced by the lexer, containing:
//!   - `TokenKind`: A union of either a word, operator, or separator
//!   - `TokenSpan`: The source position of the token  (line/column and byte indices) in the script/command
//! - `WordPart`: A segment of a word token with its quoting context
//!       (e.g., `hello"world"` produces two WordParts: one unquoted, one double-quoted)
//!
//! Note: Unlike most programming languages, keywords (if, for, while, etc.) are
//! not a distinct token type. This is because shell keywords are context-sensitive:
//! `if` in command position starts a conditional, but `echo if` just prints "if".
//! Additionally, quoting escapes keyword interpretation: `"if"` is always a word.
//! The parser determines keyword semantics based on position; the lexer just
//! produces generic word tokens.
//!
//! Also provides operator/keyword tables for O(1) lookups.

const std = @import("std");

/// Indicates how a word segment was quoted in the source.
/// Used by the expander to determine which expansions apply:
/// - `none`: bare word, all expansions apply
/// - `double`: double-quoted, variable/command expansion only
/// - `single`: single-quoted, no expansion (literal)
pub const QuoteKind = enum {
    none,
    double,
    single,
};

pub const WordPart = struct {
    quotes: QuoteKind,
    text: []const u8,

    pub fn eql(self: WordPart, other: WordPart) bool {
        return self.quotes == other.quotes and std.mem.eql(u8, self.text, other.text);
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
};

pub const TokenKind = union(enum) {
    word: []const WordPart,
    operator: []const u8,
    separator: []const u8,
};

pub const Token = struct {
    kind: TokenKind,
    span: TokenSpan,

    pub fn initWord(word_parts: []const WordPart, tok_span: TokenSpan) Token {
        return .{ .kind = .{ .word = word_parts }, .span = tok_span };
    }

    pub fn initOp(op_text: []const u8, tok_span: TokenSpan) Token {
        return .{ .kind = .{ .operator = op_text }, .span = tok_span };
    }

    pub fn initSep(sep_text: []const u8, tok_span: TokenSpan) Token {
        return .{ .kind = .{ .separator = sep_text }, .span = tok_span };
    }
};

/// Operators recognized by the lexer.
/// IMPORTANT: Ordered by descending length so longer operators match first.
/// (e.g., "2>&1" must precede "2>" to avoid premature matching)
pub const operators = [_][]const u8{
    "2>&1", "=>@", "2>>", "&>", "|>", "&&", "||", "=>", "2>", ">>", "|", "&", "<", ">",
};

/// Helper to create a compile-time string set from a simple list of strings.
/// Avoids the verbose `.{ "str", {} }` syntax required by StaticStringMap.
fn stringSet(comptime strings: []const []const u8) std.StaticStringMap(void) {
    comptime {
        var kvs: [strings.len]struct { []const u8, void } = undefined;
        for (strings, 0..) |s, i| {
            kvs[i] = .{ s, {} };
        }
        return std.StaticStringMap(void).initComptime(&kvs);
    }
}

const keywords = stringSet(&.{ "and", "or", "fun", "end", "if", "else", "for", "in", "while", "break", "continue", "return" });
pub fn isKeyword(word: []const u8) bool {
    return keywords.has(word);
}

const redirect_operators = stringSet(&.{ "<", ">", ">>", "2>", "2>>", "&>", "2>&1" });
pub fn isRedirectOperator(text: []const u8) bool {
    return redirect_operators.has(text);
}

const pipe_operators = stringSet(&.{ "|", "|>" });
pub fn isPipeOperator(text: []const u8) bool {
    return pipe_operators.has(text);
}

const logical_operators = stringSet(&.{ "and", "or", "&&", "||" });
pub fn isLogicalOperator(text: []const u8) bool {
    return logical_operators.has(text);
}

pub fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
