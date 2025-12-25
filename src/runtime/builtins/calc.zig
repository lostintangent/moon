//! calc builtin - evaluate arithmetic expressions
//!
//! Supports: + - * / % with proper precedence, parentheses for grouping.
//! For multiplication, use either * (requires quoting) or x (no quoting needed).
//!
//! Examples:
//!   calc 2 + 3           → 5
//!   = 2 + 3 x 4          → 14 (precedence, x for multiplication)
//!   = "(2 + 3) * 4"      → 20 (parens, quoted *)
//!   = $x + 1             → variable + 1

const std = @import("std");
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "calc",
    .run = run,
    .help = "calc <expression> - Evaluate arithmetic expression (+ - x * / %)",
};

pub const equals_builtin = builtins.Builtin{
    .name = "=",
    .run = run,
    .help = "= <expression> - Evaluate arithmetic expression (+ - x * / %) (alias for calc)",
};

fn run(_: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const args = cmd.argv[1..];
    if (args.len == 0) {
        builtins.io.printError("{s}: missing expression\n", .{cmd.argv[0]});
        return 1;
    }

    // Join arguments with spaces: ["2", "+", "3"] → "2 + 3"
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    for (args, 0..) |arg, i| {
        if (i > 0) stream.writer().writeByte(' ') catch break;
        stream.writer().writeAll(arg) catch break;
    }
    const expr = stream.getWritten();

    // Parse and evaluate
    var parser = Parser.init(expr);
    const result = parser.parse() catch |err| {
        builtins.io.printError("{s}: {s}\n", .{ cmd.argv[0], errorMessage(err) });
        return 1;
    };

    // Print result
    var out: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&out, "{d}\n", .{result}) catch return 1;
    builtins.io.writeStdout(str);
    return 0;
}

fn errorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.DivisionByZero => "division by zero",
        error.InvalidNumber => "invalid number",
        error.UnexpectedEnd => "unexpected end of expression",
        error.UnmatchedParen => "unmatched parenthesis",
        error.Overflow => "integer overflow",
    };
}

// =============================================================================
// Recursive descent parser for arithmetic expressions
// =============================================================================
//
// Grammar:
//   expr   → term (('+' | '-') term)*
//   term   → factor (('*' | 'x' | '/' | '%') factor)*
//   factor → NUMBER | '(' expr ')' | '-' factor
//
// The 'x' operator is a shell-friendly alias for '*' (avoids glob expansion).

const ParseError = error{
    DivisionByZero,
    InvalidNumber,
    UnexpectedEnd,
    UnmatchedParen,
    Overflow,
};

const Parser = struct {
    input: []const u8,
    pos: usize = 0,

    fn init(input: []const u8) Parser {
        return .{ .input = input };
    }

    /// Parse and evaluate the full expression, ensuring no trailing content.
    fn parse(self: *Parser) ParseError!i64 {
        const result = try self.expr();
        self.skipWhitespace();
        if (self.pos < self.input.len) return error.InvalidNumber;
        return result;
    }

    fn expr(self: *Parser) ParseError!i64 {
        var left = try self.term();
        while (true) {
            self.skipWhitespace();
            const op = self.peek() orelse break;
            if (op != '+' and op != '-') break;
            self.advance();
            const right = try self.term();
            left = switch (op) {
                '+' => std.math.add(i64, left, right) catch return error.Overflow,
                '-' => std.math.sub(i64, left, right) catch return error.Overflow,
                else => unreachable,
            };
        }
        return left;
    }

    fn term(self: *Parser) ParseError!i64 {
        var left = try self.factor();
        while (true) {
            self.skipWhitespace();
            const op = self.peek() orelse break;

            // 'x' is multiplication only if followed by whitespace/digit/paren (not part of word)
            if (op == 'x') {
                const next = if (self.pos + 1 < self.input.len) self.input[self.pos + 1] else 0;
                if (next != ' ' and next != 0 and !std.ascii.isDigit(next) and next != '(' and next != '-') {
                    break; // Not a standalone 'x', treat as end of expression
                }
            }

            if (op != '*' and op != 'x' and op != '/' and op != '%') break;

            self.advance();
            const right = try self.factor();
            left = switch (op) {
                '*', 'x' => std.math.mul(i64, left, right) catch return error.Overflow,
                '/' => if (right == 0) return error.DivisionByZero else @divTrunc(left, right),
                '%' => if (right == 0) return error.DivisionByZero else @mod(left, right),
                else => unreachable,
            };
        }
        return left;
    }

    fn factor(self: *Parser) ParseError!i64 {
        self.skipWhitespace();
        const c = self.peek() orelse return error.UnexpectedEnd;

        if (c == '-') {
            self.advance();
            return std.math.negate(try self.factor()) catch return error.Overflow;
        }
        if (c == '(') {
            self.advance();
            const result = try self.expr();
            self.skipWhitespace();
            if (self.peek() != ')') return error.UnmatchedParen;
            self.advance();
            return result;
        }
        return self.number();
    }

    fn number(self: *Parser) ParseError!i64 {
        self.skipWhitespace();
        const start = self.pos;
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            self.advance();
        }
        if (self.pos == start) return error.InvalidNumber;
        return std.fmt.parseInt(i64, self.input[start..self.pos], 10) catch error.InvalidNumber;
    }

    inline fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else null;
    }

    inline fn advance(self: *Parser) void {
        self.pos += @intFromBool(self.pos < self.input.len);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and self.input[self.pos] == ' ') self.pos += 1;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn eval(input: []const u8) ParseError!i64 {
    var p = Parser.init(input);
    return p.parse();
}

test "ops: basic arithmetic" {
    try testing.expectEqual(@as(i64, 5), try eval("2 + 3"));
    try testing.expectEqual(@as(i64, 7), try eval("10 - 3"));
    try testing.expectEqual(@as(i64, 20), try eval("4 * 5"));
    try testing.expectEqual(@as(i64, 20), try eval("4 x 5")); // x as multiplication
    try testing.expectEqual(@as(i64, 5), try eval("20 / 4"));
    try testing.expectEqual(@as(i64, 2), try eval("17 % 5"));
}

test "ops: precedence" {
    try testing.expectEqual(@as(i64, 14), try eval("2 + 3 * 4"));
    try testing.expectEqual(@as(i64, 14), try eval("2 + 3 x 4")); // x has same precedence
    try testing.expectEqual(@as(i64, 4), try eval("10 - 2 * 3"));
    try testing.expectEqual(@as(i64, 4), try eval("10 - 2 x 3"));
}

test "ops: parentheses" {
    try testing.expectEqual(@as(i64, 20), try eval("(2 + 3) * 4"));
    try testing.expectEqual(@as(i64, 20), try eval("(2 + 3) x 4")); // x with parens
    try testing.expectEqual(@as(i64, 5), try eval("((2 + 3))"));
}

test "ops: x multiplication" {
    try testing.expectEqual(@as(i64, 6), try eval("2 x 3"));
    try testing.expectEqual(@as(i64, 24), try eval("2 x 3 x 4"));
    try testing.expectEqual(@as(i64, 50), try eval("10 x 5"));
    try testing.expectEqual(@as(i64, 0), try eval("0 x 100"));
    // x followed by digit (no space) should still work
    try testing.expectEqual(@as(i64, 6), try eval("2 x3"));
    try testing.expectEqual(@as(i64, 6), try eval("2x 3"));
    try testing.expectEqual(@as(i64, 6), try eval("2x3"));
}

test "ops: unary minus" {
    try testing.expectEqual(@as(i64, -5), try eval("-5"));
    try testing.expectEqual(@as(i64, 5), try eval("--5"));
    try testing.expectEqual(@as(i64, 1), try eval("3 + -2"));
    try testing.expectEqual(@as(i64, -6), try eval("-2 x 3"));
    try testing.expectEqual(@as(i64, -6), try eval("2 x -3"));
}

test "ops: whitespace handling" {
    try testing.expectEqual(@as(i64, 5), try eval("  2 + 3  "));
    try testing.expectEqual(@as(i64, 5), try eval("2+3"));
    try testing.expectEqual(@as(i64, 14), try eval("2+3*4"));
}

test "error: division by zero" {
    try testing.expectError(error.DivisionByZero, eval("5 / 0"));
    try testing.expectError(error.DivisionByZero, eval("5 % 0"));
}

test "error: invalid input" {
    try testing.expectError(error.InvalidNumber, eval("+ 5"));
    try testing.expectError(error.UnmatchedParen, eval("(2 + 3"));
    try testing.expectError(error.InvalidNumber, eval("2 + 3 abc")); // trailing garbage
    try testing.expectError(error.UnexpectedEnd, eval("")); // empty
    try testing.expectError(error.UnexpectedEnd, eval("   ")); // whitespace only
    try testing.expectError(error.UnmatchedParen, eval(")"));
}
