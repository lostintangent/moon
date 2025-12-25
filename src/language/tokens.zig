//! Token types and related definitions for the Oshen shell lexer.
//!
//! Type hierarchy:
//! - `Token`: A lexical unit produced by the lexer, containing:
//!   - `TokenKind`: A union of either a word, operator, or separator
//!   - `TokenSpan`: The source position of the token (byte indices) in the script/command
//! - `WordPart`: A segment of a word token with its quoting context
//!       (e.g., `hello"world"` produces two WordParts: one unquoted, one double-quoted)
//!
//! ## Multi-Part Words
//!
//! Words can contain multiple parts when quote boundaries are crossed. This enables
//! Cartesian product expansion with variables and globs:
//!
//! - `$items"_suffix"` → expands to `item1_suffix item2_suffix item3_suffix`
//! - `*.txt"_backup"` → expands to `file1.txt_backup file2.txt_backup`
//!
//! Each part tracks its quoting context (`QuoteKind`) so the expander can apply
//! the correct expansion rules:
//! - Bare parts: full expansion (variables, globs, escapes)
//! - Double-quoted: variables and escapes only (globs suppressed)
//! - Single-quoted: no expansion (literal text)
//!
//! Note: Brace expansion syntax (`{pattern}_suffix`) is also supported as an
//! alternative, more explicit way to achieve Cartesian products. See expand.zig.
//!
//! ## Keywords
//!
//! Unlike most programming languages, keywords (if, for, while, etc.) are
//! not a distinct token type. This is because shell keywords are context-sensitive:
//! `if` in command position starts a conditional, but `echo if` just prints "if".
//! Additionally, quoting escapes keyword interpretation: `"if"` is always a word.
//! The parser determines keyword semantics based on position; the lexer just
//! produces generic word tokens.
//!
//! Also provides operator/keyword tables for O(1) lookups.

const std = @import("std");
const ast = @import("ast.zig");

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

/// A segment of a word with its quoting context.
///
/// Words are composed of one or more parts when quote boundaries are present.
/// This enables Cartesian product expansion where each part can have different
/// expansion behavior based on its quote type.
///
/// Examples:
/// - `hello` → single part: { .quotes = .none, .text = "hello" }
/// - `"hello"` → single part: { .quotes = .double, .text = "hello" }
/// - `hello"world"` → two parts:
///   - { .quotes = .none, .text = "hello" }
///   - { .quotes = .double, .text = "world" }
/// - `$var"_suffix"` → two parts enabling Cartesian product:
///   - { .quotes = .none, .text = "$var" } (expands to list)
///   - { .quotes = .double, .text = "_suffix" } (literal)
///   Result: if $var = [a, b] then expansion produces [a_suffix, b_suffix]
pub const WordPart = struct {
    quotes: QuoteKind,
    text: []const u8,

    /// Compares two word parts for semantic equality.
    /// Note: Compares text content (not pointer identity) and quote kind.
    /// Two word parts are equal if they have the same quote type and text content.
    pub fn eql(self: WordPart, other: WordPart) bool {
        return self.quotes == other.quotes and std.mem.eql(u8, self.text, other.text);
    }
};

/// Source location for a token as byte indices for O(1) source slicing.
/// Line/column positions can be computed on-demand from byte indices when needed
/// for error reporting (see `getLineCol`).
pub const TokenSpan = struct {
    start: usize,
    end: usize,

    /// Computes line and column numbers from a byte position.
    /// Useful for error messages - only computed when actually needed.
    pub fn getLineCol(input: []const u8, byte_pos: usize) struct { line: usize, col: usize } {
        var line: usize = 1;
        var col: usize = 1;
        for (input[0..@min(byte_pos, input.len)]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .col = col };
    }
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

/// Operators recognized by the lexer, ordered by descending length so longer
/// operators match first (e.g., "2>&1" must precede "2>" to avoid premature matching).
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

const keywords = stringSet(&.{ "and", "or", "fun", "end", "if", "else", "for", "each", "in", "while", "break", "continue", "return", "defer" });
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

/// Parses a logical operator string and returns its ChainOperator type.
/// Returns null if the text is not a logical operator.
pub fn parseLogicalOperator(text: []const u8) ?ast.ChainOperator {
    if (!logical_operators.has(text)) return null;
    return if (std.mem.eql(u8, text, "and") or std.mem.eql(u8, text, "&&"))
        .@"and"
    else
        .@"or";
}

/// Returns true if `c` is a valid identifier character (alphanumeric or underscore).
pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Returns true if `c` is a valid identifier start character (alphabetic or underscore).
pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// Validates that a string is a valid identifier.
/// Must start with alphabetic or underscore, and contain only alphanumeric or underscores.
pub fn isValidIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!isIdentStart(text[0])) return false;
    for (text[1..]) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

/// Returns true if text is a variable reference ($identifier or $N).
pub fn isVariable(text: []const u8) bool {
    if (text.len < 2 or text[0] != '$') return false;
    const name = text[1..];

    // Named variable ($foo, $HOME)
    if (isValidIdentifier(name)) return true;

    // Positional ($1, $2, etc.)
    for (name) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Returns true if `c` is a word boundary (whitespace or command separator).
pub fn isWordBreak(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', ';' => true,
        else => false,
    };
}
