//! math builtin - evaluate arithmetic expressions
//!
//! Supports: + - * / % with proper precedence, parentheses for grouping.
//!
//! Examples:
//!   math 2 + 3           → 5
//!   math 2 + 3 * 4       → 14 (precedence)
//!   math "(2 + 3) * 4"   → 20 (parens)
//!   math $x + 1          → variable + 1

const std = @import("std");
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "math",
    .run = run,
    .help = "math <expression> - Evaluate arithmetic expression (+ - * / %)",
};

fn run(_: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const args = cmd.argv[1..];
    if (args.len == 0) {
        builtins.io.writeStderr("math: missing expression\n");
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
        builtins.io.writeStderr("math: ");
        builtins.io.writeStderr(errorMessage(err));
        builtins.io.writeStderr("\n");
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
//   term   → factor (('*' | '/' | '%') factor)*
//   factor → NUMBER | '(' expr ')' | '-' factor

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
            if (op != '*' and op != '/' and op != '%') break;
            self.advance();
            const right = try self.factor();
            left = switch (op) {
                '*' => std.math.mul(i64, left, right) catch return error.Overflow,
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

test "basic operations" {
    try testing.expectEqual(@as(i64, 5), try eval("2 + 3"));
    try testing.expectEqual(@as(i64, 7), try eval("10 - 3"));
    try testing.expectEqual(@as(i64, 20), try eval("4 * 5"));
    try testing.expectEqual(@as(i64, 5), try eval("20 / 4"));
    try testing.expectEqual(@as(i64, 2), try eval("17 % 5"));
}

test "operator precedence" {
    try testing.expectEqual(@as(i64, 14), try eval("2 + 3 * 4"));
    try testing.expectEqual(@as(i64, 4), try eval("10 - 2 * 3"));
}

test "parentheses" {
    try testing.expectEqual(@as(i64, 20), try eval("(2 + 3) * 4"));
    try testing.expectEqual(@as(i64, 5), try eval("((2 + 3))"));
}

test "unary minus" {
    try testing.expectEqual(@as(i64, -5), try eval("-5"));
    try testing.expectEqual(@as(i64, 5), try eval("--5"));
    try testing.expectEqual(@as(i64, 1), try eval("3 + -2"));
}

test "division by zero" {
    try testing.expectError(error.DivisionByZero, eval("5 / 0"));
    try testing.expectError(error.DivisionByZero, eval("5 % 0"));
}

test "invalid input" {
    try testing.expectError(error.InvalidNumber, eval("+ 5"));
    try testing.expectError(error.UnmatchedParen, eval("(2 + 3"));
}
