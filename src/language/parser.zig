//! Parser: transforms a token stream into an abstract syntax tree (AST).
//!
//! The parser recognizes Oshen's grammar:
//! - Commands with arguments, redirections, and environment prefixes
//! - Pipelines (`cmd1 | cmd2`) and logical chains (`&&`, `||`, `and`, `or`)
//! - Control flow: `if`/`else`, `for`/`in`, `while`, `break`, `continue`
//! - Function definitions (`fun name ... end`)
//! - Output capture (`=> var`, `=>@ var`)
//! - Background execution (`&`)
//!
//! Control flow bodies are stored as source slices (not recursively parsed)
//! and parsed on-demand during execution, enabling loop body caching.

const std = @import("std");
const token_types = @import("tokens.zig");
const ast = @import("ast.zig");
const Token = token_types.Token;
const TokenSpan = token_types.TokenSpan;
const WordPart = token_types.WordPart;
const QuoteKind = token_types.QuoteKind;
const Program = ast.Program;
const Statement = ast.Statement;
const StatementKind = ast.StatementKind;
const CommandStatement = ast.CommandStatement;
const FunctionDefinition = ast.FunctionDefinition;
const IfStatement = ast.IfStatement;
const IfBranch = ast.IfBranch;
const ForStatement = ast.ForStatement;
const WhileStatement = ast.WhileStatement;
const ChainItem = ast.ChainItem;
const Pipeline = ast.Pipeline;
const Command = ast.Command;
const RedirectKind = ast.RedirectKind;
const ChainOperator = ast.ChainOperator;
const Assignment = ast.Assignment;
const Redirect = ast.Redirect;
const Capture = ast.Capture;
const CaptureMode = ast.CaptureMode;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEOF,
    InvalidCapture,
    CaptureWithBackground,
    InvalidFunctionName,
    UnterminatedFunction,
    UnterminatedIf,
    InvalidForLoop,
    UnterminatedFor,
    UnterminatedWhile,
    OutOfMemory,
};

pub const Parser = struct {
    tokens: []const Token,
    pos: usize,
    allocator: std.mem.Allocator,
    /// Original input source (needed for capturing function bodies)
    input: []const u8,

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) Parser {
        return initWithInput(allocator, tokens, "");
    }

    pub fn initWithInput(allocator: std.mem.Allocator, tokens: []const Token, input: []const u8) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .allocator = allocator,
            .input = input,
        };
    }

    fn peek(self: *Parser) ?Token {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) ?Token {
        if (self.pos >= self.tokens.len) return null;
        const tok = self.tokens[self.pos];
        self.pos += 1;
        return tok;
    }

    fn isOp(self: *Parser, op: []const u8) bool {
        const tok = self.peek() orelse return false;
        switch (tok.kind) {
            .operator => |t| return std.mem.eql(u8, t, op),
            .word => |segs| {
                // Check for keyword words (like 'if', 'else', 'end', 'fun', 'and', 'or')
                // These are lexed as words but should be treated as keywords in command position
                if (segs.len == 1 and segs[0].quotes == .none and token_types.isKeyword(segs[0].text)) {
                    return std.mem.eql(u8, segs[0].text, op);
                }
                return false;
            },
            .separator => return false,
        }
    }

    fn isSep(self: *Parser) bool {
        if (self.peek()) |tok| {
            return tok.kind == .separator;
        }
        return false;
    }

    fn isWord(self: *Parser) bool {
        if (self.peek()) |tok| {
            return tok.kind == .word;
        }
        return false;
    }

    fn skipSeps(self: *Parser) void {
        while (self.isSep()) {
            _ = self.advance();
        }
    }

    fn parseEnvPrefix(word_parts: []const WordPart) ?struct { key: []const u8, value: []const u8 } {
        if (word_parts.len != 1) return null;
        if (word_parts[0].quotes != .none) return null;

        const text = word_parts[0].text;
        const eq_pos = std.mem.indexOf(u8, text, "=") orelse return null;

        if (eq_pos == 0) return null;
        const key = text[0..eq_pos];

        if (!token_types.isIdentStart(key[0])) return null;
        for (key[1..]) |c| {
            if (!token_types.isIdentChar(c)) return null;
        }

        return .{ .key = key, .value = text[eq_pos + 1 ..] };
    }

    fn parseRedirect(self: *Parser) ParseError!?Redirect {
        const tok = self.peek() orelse return null;
        if (tok.kind != .operator) return null;

        const op_text = tok.kind.operator;
        if (!token_types.isRedirectOperator(op_text)) return null;

        _ = self.advance();

        const fd: u8 = if (op_text.len > 0 and op_text[0] == '2')
            2
        else if (op_text.len > 0 and op_text[0] == '<')
            0
        else
            1;

        if (std.mem.eql(u8, op_text, "2>&1")) {
            return Redirect{ .from_fd = fd, .kind = .{ .dup = 1 } };
        }

        if (!self.isWord()) return ParseError.UnexpectedEOF;

        const word_tok = self.advance().?;
        const parts = word_tok.kind.word;

        const kind = if (op_text.len > 0 and op_text[0] == '<')
            RedirectKind{ .read = parts }
        else if (std.mem.endsWith(u8, op_text, ">>"))
            RedirectKind{ .write_append = parts }
        else
            RedirectKind{ .write_truncate = parts };

        return Redirect{ .from_fd = fd, .kind = kind };
    }

    /// Check if the current word token is a logical operator keyword (and, or)
    fn isLogicalKeyword(self: *Parser) bool {
        const tok = self.peek() orelse return false;
        if (tok.kind != .word) return false;

        const parts = tok.kind.word;
        return parts.len == 1 and parts[0].quotes == .none and token_types.isLogicalOperator(parts[0].text);
    }

    fn parseCommand(self: *Parser) ParseError!?Command {
        var assignments: std.ArrayListUnmanaged(Assignment) = .empty;
        var words: std.ArrayListUnmanaged([]const WordPart) = .empty;
        var redirects: std.ArrayListUnmanaged(Redirect) = .empty;

        while (self.isWord() and !self.isLogicalKeyword()) {
            const tok = self.peek().?;
            const segs = tok.kind.word;
            if (parseEnvPrefix(segs)) |parsed| {
                _ = self.advance();
                const value_seg = self.allocator.alloc(WordPart, 1) catch return ParseError.OutOfMemory;
                value_seg[0] = .{ .quotes = .none, .text = parsed.value };
                assignments.append(self.allocator, .{ .key = parsed.key, .value = value_seg }) catch return ParseError.OutOfMemory;
            } else {
                break;
            }
        }

        while (true) {
            if (try self.parseRedirect()) |redirect| {
                redirects.append(self.allocator, redirect) catch return ParseError.OutOfMemory;
                continue;
            }

            // Stop at logical keywords (and, or) - they belong to parseLogical
            if (self.isWord() and !self.isLogicalKeyword()) {
                const tok = self.advance().?;
                words.append(self.allocator, tok.kind.word) catch return ParseError.OutOfMemory;
                continue;
            }

            break;
        }

        if (words.items.len == 0 and assignments.items.len == 0) {
            return null;
        }

        return Command{
            .assignments = assignments.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .words = words.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .redirects = redirects.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        };
    }

    fn parsePipeline(self: *Parser) ParseError!?Pipeline {
        var commands: std.ArrayListUnmanaged(Command) = .empty;

        const first_cmd = try self.parseCommand() orelse return null;
        commands.append(self.allocator, first_cmd) catch return ParseError.OutOfMemory;

        while (true) {
            const tok = self.peek() orelse break;
            if (tok.kind != .operator) break;
            if (!token_types.isPipeOperator(tok.kind.operator)) break;

            _ = self.advance();
            self.skipSeps();
            const cmd = try self.parseCommand() orelse return ParseError.UnexpectedEOF;
            commands.append(self.allocator, cmd) catch return ParseError.OutOfMemory;
        }

        return Pipeline{
            .commands = commands.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        };
    }

    fn parseLogical(self: *Parser) ParseError!?[]ChainItem {
        var chains: std.ArrayListUnmanaged(ChainItem) = .empty;

        const first_pipeline = try self.parsePipeline() orelse return null;
        chains.append(self.allocator, .{ .op = .none, .pipeline = first_pipeline }) catch return ParseError.OutOfMemory;

        while (true) {
            // Check for logical operators: &&, ||, and, or
            // These can be either op tokens (&&, ||) or word tokens (and, or)
            var op_value: ChainOperator = .none;
            var has_op = false;

            if (self.peek()) |tok| {
                switch (tok.kind) {
                    .operator => |t| {
                        if (token_types.isLogicalOperator(t)) {
                            op_value = if (std.mem.eql(u8, t, "&&")) .@"and" else .@"or";
                            has_op = true;
                        }
                    },
                    .word => |segs| {
                        // Check if it's a text operator keyword (and, or)
                        if (segs.len == 1 and segs[0].quotes == .none) {
                            if (token_types.isLogicalOperator(segs[0].text)) {
                                op_value = if (std.mem.eql(u8, segs[0].text, "and")) .@"and" else .@"or";
                                has_op = true;
                            }
                        }
                    },
                    .separator => {},
                }
            }

            if (has_op) {
                _ = self.advance();
                self.skipSeps();
                const pipeline = try self.parsePipeline() orelse return ParseError.UnexpectedEOF;
                chains.append(self.allocator, .{ .op = op_value, .pipeline = pipeline }) catch return ParseError.OutOfMemory;
            } else {
                break;
            }
        }

        return chains.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
    }

    fn parseStmt(self: *Parser) ParseError!?Statement {
        // Check for function definition: fun name ... end
        if (self.isOp("fun")) {
            return try self.parseFunctionDefinition();
        }

        // Check for if statement: if condition ... end
        if (self.isOp("if")) {
            return try self.parseIfStatement();
        }

        // Check for for loop: for var in items... end
        if (self.isOp("for")) {
            return try self.parseForStatement();
        }

        // Check for while loop: while condition ... end
        if (self.isOp("while")) {
            return try self.parseWhileStatement();
        }

        // Check for break statement
        if (self.isOp("break")) {
            _ = self.advance();
            return Statement{ .kind = .@"break" };
        }

        // Check for continue statement
        if (self.isOp("continue")) {
            _ = self.advance();
            return Statement{ .kind = .@"continue" };
        }

        // Check for return statement: return [value]
        if (self.isOp("return")) {
            _ = self.advance();
            // Check for optional status argument (can be variable, literal, etc.)
            var status_parts: ?[]const WordPart = null;
            if (self.isWord()) {
                const tok = self.peek().?;
                status_parts = tok.kind.word;
                _ = self.advance();
            }
            return Statement{ .kind = .{ .@"return" = status_parts } };
        }

        const chains = try self.parseLogical() orelse return null;

        var background = false;
        var capture: ?Capture = null;

        if (self.isOp("&")) {
            background = true;
            _ = self.advance();
        }

        if (self.isOp("=>") or self.isOp("=>@")) {
            if (background) return ParseError.CaptureWithBackground;

            const cap_tok = self.advance().?;
            const mode: CaptureMode = if (std.mem.eql(u8, cap_tok.kind.operator, "=>@")) .lines else .string;

            if (!self.isWord()) return ParseError.InvalidCapture;

            const var_tok = self.advance().?;
            const segs = var_tok.kind.word;
            if (segs.len == 1 and segs[0].quotes == .none) {
                capture = .{ .mode = mode, .variable = segs[0].text };
            } else {
                return ParseError.InvalidCapture;
            }
        }

        return Statement{ .kind = .{ .command = CommandStatement{ .background = background, .capture = capture, .chains = chains } } };
    }

    /// Parse a function definition: fun name ... end
    fn parseFunctionDefinition(self: *Parser) ParseError!Statement {
        _ = self.advance(); // consume 'fun'
        self.skipSeps();

        // Expect function name (a word)
        if (!self.isWord()) return ParseError.InvalidFunctionName;

        const name_tok = self.advance().?;
        const name = blk: {
            const segs = name_tok.kind.word;
            if (segs.len == 1 and segs[0].quotes == .none) {
                break :blk segs[0].text;
            }
            return ParseError.InvalidFunctionName;
        };

        self.skipSeps();

        // Capture the body: everything until we see 'end'
        const body_start_pos = self.pos;
        const scan = self.scanToBlockEnd(&.{}) orelse return ParseError.UnterminatedFunction;
        const body = std.mem.trim(u8, self.extractSourceRange(body_start_pos, scan.end_pos), " \t\n");
        _ = self.advance(); // consume 'end'

        return Statement{ .kind = .{ .function = FunctionDefinition{ .name = name, .body = body } } };
    }

    /// Parse an if statement with optional else-if chains:
    ///   if cond1; body1; else if cond2; body2; else; body3; end
    /// Condition is everything until first separator (newline or semicolon)
    fn parseIfStatement(self: *Parser) ParseError!Statement {
        var branches: std.ArrayListUnmanaged(IfBranch) = .empty;

        // Parse the initial "if" branch
        _ = self.advance(); // consume 'if'
        const first_branch = try self.parseIfBranch();
        branches.append(self.allocator, first_branch) catch return ParseError.OutOfMemory;

        // Parse else-if chains and final else
        var else_body: ?[]const u8 = null;

        while (self.pos < self.tokens.len) {
            if (self.isOp("else")) {
                _ = self.advance(); // consume 'else'
                self.skipSeps();

                if (self.isOp("if")) {
                    // else if - parse another branch
                    _ = self.advance(); // consume 'if'
                    const branch = try self.parseIfBranch();
                    branches.append(self.allocator, branch) catch return ParseError.OutOfMemory;
                } else {
                    // Final else - capture body until end
                    const else_start = self.pos;
                    const scan = self.scanToBlockEnd(&.{}) orelse return ParseError.UnterminatedIf;
                    else_body = std.mem.trim(u8, self.extractSourceRange(else_start, scan.end_pos), " \t\n");
                    _ = self.advance(); // consume 'end'
                    break;
                }
            } else if (self.isOp("end")) {
                _ = self.advance(); // consume 'end'
                break;
            } else {
                return ParseError.UnterminatedIf;
            }
        }

        return Statement{ .kind = .{ .@"if" = IfStatement{
            .branches = branches.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .else_body = else_body,
        } } };
    }

    /// Parse a single if/else-if branch (condition + body)
    /// Expects parser to be positioned after 'if' keyword
    fn parseIfBranch(self: *Parser) ParseError!IfBranch {
        self.skipSeps();

        // Condition: parse until separator
        const cond_start_pos = self.pos;
        while (self.pos < self.tokens.len and !self.isSep()) {
            if (self.isOp("end") or self.isOp("else")) break;
            _ = self.advance();
        }
        const cond_end_pos = self.pos;
        self.skipSeps();

        // Body: parse until else/end at our depth
        const body_start_pos = self.pos;
        const scan = self.scanToBlockEnd(&.{"else"}) orelse return ParseError.UnterminatedIf;

        const condition = std.mem.trim(u8, self.extractSourceRange(cond_start_pos, cond_end_pos), " \t\n");
        const body = std.mem.trim(u8, self.extractSourceRange(body_start_pos, scan.end_pos), " \t\n");

        return IfBranch{ .condition = condition, .body = body };
    }

    /// Parse a for loop: for var in items... end
    /// Syntax: for x in a b c; echo $x; end
    fn parseForStatement(self: *Parser) ParseError!Statement {
        _ = self.advance(); // consume 'for'
        self.skipSeps();

        // Parse variable name
        if (!self.isWord()) return ParseError.InvalidForLoop;
        const var_tok = self.advance().?;
        const variable = blk: {
            const segs = var_tok.kind.word;
            if (segs.len == 1 and segs[0].quotes == .none) {
                break :blk segs[0].text;
            }
            return ParseError.InvalidForLoop;
        };

        self.skipSeps();

        // Expect 'in' keyword
        if (!self.isOp("in")) return ParseError.InvalidForLoop;
        _ = self.advance(); // consume 'in'
        self.skipSeps();

        // Items: everything until separator (newline or semicolon)
        const items_start_pos = self.pos;
        while (self.pos < self.tokens.len and !self.isSep()) {
            if (self.isOp("end")) break;
            _ = self.advance();
        }
        const items_end_pos = self.pos;

        self.skipSeps();

        // Body: find 'end', tracking depth for nested for/if statements
        const body_start_pos = self.pos;
        const scan = self.scanToBlockEnd(&.{}) orelse return ParseError.UnterminatedFor;
        const items_source = std.mem.trim(u8, self.extractSourceRange(items_start_pos, items_end_pos), " \t\n");
        const body = std.mem.trim(u8, self.extractSourceRange(body_start_pos, scan.end_pos), " \t\n");
        _ = self.advance(); // consume 'end'

        return Statement{ .kind = .{ .@"for" = ForStatement{
            .variable = variable,
            .items_source = items_source,
            .body = body,
        } } };
    }

    /// Parse a while loop: while condition ... end
    /// Syntax: while test -f file; echo waiting; sleep 1; end
    fn parseWhileStatement(self: *Parser) ParseError!Statement {
        _ = self.advance(); // consume 'while'
        self.skipSeps();

        // Condition: parse until separator (newline or semicolon)
        const cond_start_pos = self.pos;
        while (self.pos < self.tokens.len and !self.isSep()) {
            if (self.isOp("end")) break;
            _ = self.advance();
        }
        const cond_end_pos = self.pos;

        self.skipSeps();

        // Body: find 'end', tracking depth for nested blocks
        const body_start_pos = self.pos;
        const scan = self.scanToBlockEnd(&.{}) orelse return ParseError.UnterminatedWhile;
        const condition = std.mem.trim(u8, self.extractSourceRange(cond_start_pos, cond_end_pos), " \t\n");
        const body = std.mem.trim(u8, self.extractSourceRange(body_start_pos, scan.end_pos), " \t\n");
        _ = self.advance(); // consume 'end'

        return Statement{ .kind = .{ .@"while" = WhileStatement{
            .condition = condition,
            .body = body,
        } } };
    }

    // =========================================================================
    // Block Scanning Helpers
    // =========================================================================

    /// Check if current token starts a block (if, for, while, fun)
    fn isBlockStart(self: *Parser) bool {
        return self.isOp("if") or self.isOp("for") or self.isOp("while") or self.isOp("fun");
    }

    /// Result of scanning to a block terminator
    const ScanResult = struct {
        /// Position of the terminating token (end, else, etc.)
        end_pos: usize,
        /// Which terminator was found
        terminator: []const u8,
    };

    /// Scan forward to find a block terminator, handling nested blocks.
    /// Returns the position of the terminator and which one was found.
    /// The parser position is left AT the terminator (not past it).
    ///
    /// `terminators` specifies which keywords (besides "end" at depth 0) can end the scan.
    /// For example, parseIfBranch passes &.{"else"} to stop at "else" at depth 1.
    fn scanToBlockEnd(self: *Parser, terminators: []const []const u8) ?ScanResult {
        var depth: usize = 1;

        while (self.pos < self.tokens.len) {
            if (self.isBlockStart()) {
                depth += 1;
                _ = self.advance();
            } else if (self.isOp("end")) {
                depth -= 1;
                if (depth == 0) {
                    return .{ .end_pos = self.pos, .terminator = "end" };
                }
                _ = self.advance();
            } else {
                // Check custom terminators at depth 1
                if (depth == 1) {
                    for (terminators) |term| {
                        if (self.isOp(term)) {
                            return .{ .end_pos = self.pos, .terminator = term };
                        }
                    }
                }
                _ = self.advance();
            }
        }
        return null;
    }

    /// Extract source text between two token positions
    fn extractSourceRange(self: *Parser, start_pos: usize, end_pos: usize) []const u8 {
        if (self.input.len == 0 or start_pos >= end_pos or start_pos >= self.tokens.len) {
            return "";
        }

        const start_span = self.tokens[start_pos].span;
        const end_span = if (end_pos < self.tokens.len)
            self.tokens[end_pos].span
        else
            TokenSpan{
                .start_line = 1,
                .start_col = 1,
                .end_line = 1,
                .end_col = 1,
                .start_index = self.input.len,
                .end_index = self.input.len,
            };

        const start_byte = start_span.start_index;
        const end_byte = end_span.start_index;

        if (start_byte >= end_byte or end_byte > self.input.len) {
            return "";
        }

        return self.input[start_byte..end_byte];
    }

    pub fn parse(self: *Parser) ParseError!Program {
        var stmts: std.ArrayListUnmanaged(Statement) = .empty;

        self.skipSeps();

        while (self.pos < self.tokens.len) {
            self.skipSeps();
            if (self.pos >= self.tokens.len) break;

            if (try self.parseStmt()) |stmt| {
                stmts.append(self.allocator, stmt) catch return ParseError.OutOfMemory;
            } else {
                break;
            }

            if (self.pos < self.tokens.len) {
                if (self.isSep()) {
                    self.skipSeps();
                } else if (self.isOp("&")) {
                    continue;
                } else {
                    break;
                }
            }
        }

        return Program{ .statements = stmts.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const lexer = @import("lexer.zig");

test "simple command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lex = lexer.Lexer.init(allocator, "echo hello");
    const tokens = try lex.tokenize();

    var p = Parser.init(allocator, tokens);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const cmd_stmt = prog.statements[0].kind.command;
    try testing.expectEqual(false, cmd_stmt.background);
    try testing.expectEqual(@as(?Capture, null), cmd_stmt.capture);
    try testing.expectEqual(@as(usize, 1), cmd_stmt.chains.len);
    try testing.expectEqual(ast.ChainOperator.none, cmd_stmt.chains[0].op);
    try testing.expectEqual(@as(usize, 1), cmd_stmt.chains[0].pipeline.commands.len);
    try testing.expectEqual(@as(usize, 2), cmd_stmt.chains[0].pipeline.commands[0].words.len);
}

test "pipeline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lex = lexer.Lexer.init(allocator, "cat file | grep foo | wc -l");
    const tokens = try lex.tokenize();

    var p = Parser.init(allocator, tokens);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const pipeline = prog.statements[0].kind.command.chains[0].pipeline;
    try testing.expectEqual(@as(usize, 3), pipeline.commands.len);
}

test "background" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lex = lexer.Lexer.init(allocator, "sleep 10 &");
    const tokens = try lex.tokenize();

    var p = Parser.init(allocator, tokens);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expectEqual(true, prog.statements[0].kind.command.background);
}

test "capture string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lex = lexer.Lexer.init(allocator, "whoami => user");
    const tokens = try lex.tokenize();

    var p = Parser.init(allocator, tokens);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    if (prog.statements[0].kind.command.capture) |cap| {
        try testing.expectEqual(CaptureMode.string, cap.mode);
        try testing.expectEqualStrings("user", cap.variable);
    } else {
        return error.TestExpectedEqual;
    }
}

test "capture lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lex = lexer.Lexer.init(allocator, "ls =>@ files");
    const tokens = try lex.tokenize();

    var p = Parser.init(allocator, tokens);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    if (prog.statements[0].kind.command.capture) |cap| {
        try testing.expectEqual(CaptureMode.lines, cap.mode);
        try testing.expectEqualStrings("files", cap.variable);
    } else {
        return error.TestExpectedEqual;
    }
}

test "logical operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lex = lexer.Lexer.init(allocator, "true && echo ok || echo fail");
    const tokens = try lex.tokenize();

    var p = Parser.init(allocator, tokens);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const cmd_stmt = prog.statements[0].kind.command;
    try testing.expectEqual(@as(usize, 3), cmd_stmt.chains.len);
    try testing.expectEqual(ast.ChainOperator.none, cmd_stmt.chains[0].op);
    try testing.expectEqual(ast.ChainOperator.@"and", cmd_stmt.chains[1].op);
    try testing.expectEqual(ast.ChainOperator.@"or", cmd_stmt.chains[2].op);
}

test "redirections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lex = lexer.Lexer.init(allocator, "cat < in.txt > out.txt");
    const tokens = try lex.tokenize();

    var p = Parser.init(allocator, tokens);
    const prog = try p.parse();

    const cmd = prog.statements[0].kind.command.chains[0].pipeline.commands[0];
    try testing.expectEqual(@as(usize, 2), cmd.redirects.len);
    const r1 = cmd.redirects[0];
    try testing.expectEqual(@as(u8, 0), r1.from_fd);
    switch (r1.kind) {
        .read => |parts| {
            try testing.expectEqual(@as(usize, 1), parts.len);
            try testing.expectEqualStrings("in.txt", parts[0].text);
        },
        else => return error.TestExpectedEqual,
    }
    const r2 = cmd.redirects[1];
    try testing.expectEqual(@as(u8, 1), r2.from_fd);
    switch (r2.kind) {
        .write_truncate => |parts| {
            try testing.expectEqual(@as(usize, 1), parts.len);
            try testing.expectEqualStrings("out.txt", parts[0].text);
        },
        else => return error.TestExpectedEqual,
    }
}

test "env prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lex = lexer.Lexer.init(allocator, "FOO=bar env");
    const tokens = try lex.tokenize();

    var p = Parser.init(allocator, tokens);
    const prog = try p.parse();

    const cmd = prog.statements[0].kind.command.chains[0].pipeline.commands[0];
    try testing.expectEqual(@as(usize, 1), cmd.assignments.len);
    try testing.expectEqualStrings("FOO", cmd.assignments[0].key);
}

test "function definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "fun greet\n  echo hello\nend";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const fun_def = prog.statements[0].kind.function;
    try testing.expectEqualStrings("greet", fun_def.name);
    try testing.expect(std.mem.indexOf(u8, fun_def.body, "echo hello") != null);
}

test "function definition inline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "fun greet echo hello end";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const fun_def = prog.statements[0].kind.function;
    try testing.expectEqualStrings("greet", fun_def.name);
    try testing.expect(std.mem.indexOf(u8, fun_def.body, "echo hello") != null);
}

test "nested function definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "fun outer\n  fun inner\n    echo inner\n  end\n  inner\nend";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const fun_def = prog.statements[0].kind.function;
    try testing.expectEqualStrings("outer", fun_def.name);
    // Body should contain the nested fun...end
    try testing.expect(std.mem.indexOf(u8, fun_def.body, "fun inner") != null);
    try testing.expect(std.mem.indexOf(u8, fun_def.body, "end") != null);
}

test "unterminated function error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "fun greet\n  echo hello";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const result = p.parse();

    try testing.expectError(ParseError.UnterminatedFunction, result);
}

test "invalid function name error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // fun with a quoted name (invalid)
    const input = "fun \"quoted\" body end";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const result = p.parse();

    try testing.expectError(ParseError.InvalidFunctionName, result);
}

test "if statement simple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "if true\n  echo yes\nend";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 1), @"if".branches.len);
    try testing.expectEqualStrings("true", @"if".branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "echo yes") != null);
    try testing.expectEqual(@as(?[]const u8, null), @"if".else_body);
}

test "if statement with else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "if false\n  echo no\nelse\n  echo yes\nend";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 1), @"if".branches.len);
    try testing.expectEqualStrings("false", @"if".branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "echo no") != null);
    try testing.expect(@"if".else_body != null);
    try testing.expect(std.mem.indexOf(u8, @"if".else_body.?, "echo yes") != null);
}

test "if statement inline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "if true; echo yes; end";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 1), @"if".branches.len);
    try testing.expectEqualStrings("true", @"if".branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "echo yes") != null);
}

test "nested if statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "if true\n  if false\n    echo inner\n  end\nend";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 1), @"if".branches.len);
    try testing.expectEqualStrings("true", @"if".branches[0].condition);
    // Body should contain the nested if...end
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "if false") != null);
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "end") != null);
}

test "if else if else chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "if test $x -eq 1\n  echo one\nelse if test $x -eq 2\n  echo two\nelse\n  echo other\nend";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 2), @"if".branches.len);
    try testing.expectEqualStrings("test $x -eq 1", @"if".branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "echo one") != null);
    try testing.expectEqualStrings("test $x -eq 2", @"if".branches[1].condition);
    try testing.expect(std.mem.indexOf(u8, @"if".branches[1].body, "echo two") != null);
    try testing.expect(@"if".else_body != null);
    try testing.expect(std.mem.indexOf(u8, @"if".else_body.?, "echo other") != null);
}

test "if else if without final else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "if false; echo a; else if true; echo b; end";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 2), @"if".branches.len);
    try testing.expectEqual(@as(?[]const u8, null), @"if".else_body);
}

test "unterminated if error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "if true\n  echo yes";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const result = p.parse();

    try testing.expectError(ParseError.UnterminatedIf, result);
}

test "while statement simple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "while test -f file\n  sleep 1\nend";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const while_stmt = prog.statements[0].kind.@"while";
    try testing.expectEqualStrings("test -f file", while_stmt.condition);
    try testing.expect(std.mem.indexOf(u8, while_stmt.body, "sleep 1") != null);
}

test "while statement inline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "while true; echo loop; end";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const while_stmt = prog.statements[0].kind.@"while";
    try testing.expectEqualStrings("true", while_stmt.condition);
    try testing.expect(std.mem.indexOf(u8, while_stmt.body, "echo loop") != null);
}

test "nested while in if" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "if true\n  while false\n    echo inner\n  end\nend";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 1), @"if".branches.len);
    // Body should contain the nested while...end
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "while false") != null);
}

test "unterminated while error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "while true\n  echo loop";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const result = p.parse();

    try testing.expectError(ParseError.UnterminatedWhile, result);
}

test "break statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "break";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"break");
}

test "continue statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "continue";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"continue");
}

test "return statement without argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "return";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"return");
    try testing.expectEqual(@as(?[]const WordPart, null), prog.statements[0].kind.@"return");
}

test "return statement with status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "return 1";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"return");
    const parts = prog.statements[0].kind.@"return".?;
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqualStrings("1", parts[0].text);
}

test "return statement with zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "return 0";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"return");
    const parts = prog.statements[0].kind.@"return".?;
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqualStrings("0", parts[0].text);
}

test "return statement with variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "return $status";
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();

    var p = Parser.initWithInput(allocator, tokens, input);
    const prog = try p.parse();

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"return");
    try testing.expect(prog.statements[0].kind.@"return" != null);
}
