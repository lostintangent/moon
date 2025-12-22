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

    // =========================================================================
    // Token navigation
    // =========================================================================

    /// Returns the current token without advancing, or null if at end.
    inline fn peek(self: *const Parser) ?Token {
        return if (self.pos < self.tokens.len) self.tokens[self.pos] else null;
    }

    /// Advances position by one token and returns the consumed token.
    inline fn advance(self: *Parser) ?Token {
        if (self.pos >= self.tokens.len) return null;
        defer self.pos += 1;
        return self.tokens[self.pos];
    }

    fn skipSeperators(self: *Parser) void {
        while (self.isSeperator()) {
            _ = self.advance();
        }
    }

    // =========================================================================
    // Token type predicates
    // =========================================================================

    /// Returns true if current token is the specified operator.
    fn isOperator(self: *const Parser, op: []const u8) bool {
        const tok = self.peek() orelse return false;
        return tok.kind == .operator and std.mem.eql(u8, tok.kind.operator, op);
    }

    /// Returns true if current token is an unquoted bare word matching the given keyword.
    fn isKeyword(self: *const Parser, keyword: []const u8) bool {
        const tok = self.peek() orelse return false;
        if (tok.kind != .word) return false;
        const segs = tok.kind.word;
        return segs.len == 1 and segs[0].quotes == .none and std.mem.eql(u8, segs[0].text, keyword);
    }

    /// Returns true if current token matches the specified operator or keyword.
    /// Used for checking keywords that can appear in command position (if, for, while, etc.).
    fn isOp(self: *const Parser, op: []const u8) bool {
        return self.isOperator(op) or (token_types.isKeyword(op) and self.isKeyword(op));
    }

    /// Returns true if current token is a separator (newline or semicolon).
    fn isSeperator(self: *const Parser) bool {
        const tok = self.peek() orelse return false;
        return tok.kind == .separator;
    }

    /// Returns true if current token is a word.
    fn isWord(self: *const Parser) bool {
        const tok = self.peek() orelse return false;
        return tok.kind == .word;
    }

    /// Returns true if current word token is a logical operator keyword (and, or).
    fn isLogicalKeyword(self: *const Parser) bool {
        const tok = self.peek() orelse return false;
        if (tok.kind != .word) return false;
        const parts = tok.kind.word;
        return parts.len == 1 and parts[0].quotes == .none and token_types.isLogicalOperator(parts[0].text);
    }

    /// Returns true if current token starts a block (if, for, while, fun).
    fn isBlockStart(self: *const Parser) bool {
        return self.isOp("if") or self.isOp("for") or self.isOp("while") or self.isOp("fun");
    }

    // =========================================================================
    // Word analysis helpers
    // =========================================================================

    /// Result of parsing an environment variable assignment.
    const EnvAssignment = struct { key: []const u8, value: []const u8 };

    /// Attempts to parse a word as an environment variable assignment (KEY=value).
    /// Returns the key-value pair if valid, null otherwise.
    fn tryParseEnvAssignment(word_parts: []const WordPart) ?EnvAssignment {
        // Only unquoted single-segment words can be assignments
        if (word_parts.len != 1 or word_parts[0].quotes != .none) return null;

        const text = word_parts[0].text;
        const eq_pos = std.mem.indexOf(u8, text, "=") orelse return null;
        if (eq_pos == 0) return null; // Empty key

        const key = text[0..eq_pos];

        // Validate identifier: must start with alpha/underscore, continue with alphanumeric/underscore
        if (!token_types.isIdentStart(key[0])) return null;
        for (key[1..]) |c| {
            if (!token_types.isIdentChar(c)) return null;
        }

        return .{ .key = key, .value = text[eq_pos + 1 ..] };
    }

    /// Attempts to parse a logical operator (&&, ||, and, or) at current position.
    /// Returns the operator type if found, null otherwise.
    fn tryParseLogicalOp(self: *const Parser) ?ChainOperator {
        const tok = self.peek() orelse return null;

        switch (tok.kind) {
            .operator => |t| {
                if (!token_types.isLogicalOperator(t)) return null;
                return if (std.mem.eql(u8, t, "&&")) .@"and" else .@"or";
            },
            .word => |segs| {
                if (segs.len != 1 or segs[0].quotes != .none) return null;
                if (!token_types.isLogicalOperator(segs[0].text)) return null;
                return if (std.mem.eql(u8, segs[0].text, "and")) .@"and" else .@"or";
            },
            .separator => return null,
        }
    }

    // =========================================================================
    // Redirect parsing
    // =========================================================================

    /// Determines the source file descriptor from a redirect operator.
    /// - Operators starting with '2' redirect stderr (fd 2)
    /// - Input redirects '<' target stdin (fd 0)
    /// - All other redirects target stdout (fd 1)
    fn getRedirectFd(op_text: []const u8) u8 {
        if (op_text.len == 0) return 1;
        return switch (op_text[0]) {
            '2' => 2,
            '<' => 0,
            else => 1,
        };
    }

    /// Parses a redirect operator and its target. Returns null if no redirect present.
    fn parseRedirect(self: *Parser) ParseError!?Redirect {
        const tok = self.peek() orelse return null;
        if (tok.kind != .operator) return null;

        const op_text = tok.kind.operator;
        if (!token_types.isRedirectOperator(op_text)) return null;

        _ = self.advance();
        const fd = getRedirectFd(op_text);

        // Handle fd duplication (2>&1)
        if (std.mem.eql(u8, op_text, "2>&1")) {
            return Redirect{ .from_fd = fd, .kind = .{ .dup = 1 } };
        }

        // All other redirects need a target word
        if (!self.isWord()) return ParseError.UnexpectedEOF;
        const word_tok = self.advance().?;
        const parts = word_tok.kind.word;

        const kind: RedirectKind = if (op_text[0] == '<')
            .{ .read = parts }
        else if (std.mem.endsWith(u8, op_text, ">>"))
            .{ .write_append = parts }
        else
            .{ .write_truncate = parts };

        return Redirect{ .from_fd = fd, .kind = kind };
    }

    // =========================================================================
    // Command parsing
    // =========================================================================

    /// Parses leading environment variable assignments (KEY=value format).
    fn parseAssignments(self: *Parser, assignments: *std.ArrayListUnmanaged(Assignment)) ParseError!void {
        while (self.isWord() and !self.isLogicalKeyword()) {
            const tok = self.peek().?;
            const parsed = tryParseEnvAssignment(tok.kind.word) orelse break;

            _ = self.advance();
            const value_seg = self.allocator.alloc(WordPart, 1) catch return ParseError.OutOfMemory;
            value_seg[0] = .{ .quotes = .none, .text = parsed.value };
            try assignments.append(self.allocator, .{ .key = parsed.key, .value = value_seg });
        }
    }

    /// Parses command words and redirections.
    fn parseWordsAndRedirects(
        self: *Parser,
        words: *std.ArrayListUnmanaged([]const WordPart),
        redirects: *std.ArrayListUnmanaged(Redirect),
    ) ParseError!void {
        while (true) {
            if (try self.parseRedirect()) |redirect| {
                try redirects.append(self.allocator, redirect);
                continue;
            }

            // Stop at logical keywords (and, or) - they belong to parseLogical
            if (self.isWord() and !self.isLogicalKeyword()) {
                const tok = self.advance().?;
                try words.append(self.allocator, tok.kind.word);
                continue;
            }

            break;
        }
    }

    /// Parses a single command with optional assignments, words, and redirects.
    fn parseCommand(self: *Parser) ParseError!?Command {
        var assignments: std.ArrayListUnmanaged(Assignment) = .empty;
        var words: std.ArrayListUnmanaged([]const WordPart) = .empty;
        var redirects: std.ArrayListUnmanaged(Redirect) = .empty;

        try self.parseAssignments(&assignments);
        try self.parseWordsAndRedirects(&words, &redirects);

        if (words.items.len == 0 and assignments.items.len == 0) {
            return null;
        }

        return Command{
            .assignments = try assignments.toOwnedSlice(self.allocator),
            .words = try words.toOwnedSlice(self.allocator),
            .redirects = try redirects.toOwnedSlice(self.allocator),
        };
    }

    // =========================================================================
    // Pipeline and logical chain parsing
    // =========================================================================

    /// Parses a pipeline of commands connected by `|`.
    fn parsePipeline(self: *Parser) ParseError!?Pipeline {
        var commands: std.ArrayListUnmanaged(Command) = .empty;

        const first_cmd = try self.parseCommand() orelse return null;
        try commands.append(self.allocator, first_cmd);

        while (true) {
            const tok = self.peek() orelse break;
            if (tok.kind != .operator) break;
            if (!token_types.isPipeOperator(tok.kind.operator)) break;

            _ = self.advance();
            self.skipSeperators();
            const cmd = try self.parseCommand() orelse return ParseError.UnexpectedEOF;
            try commands.append(self.allocator, cmd);
        }

        return Pipeline{
            .commands = try commands.toOwnedSlice(self.allocator),
        };
    }

    /// Parses a logical chain of pipelines connected by `&&`, `||`, `and`, or `or`.
    fn parseLogical(self: *Parser) ParseError!?[]ChainItem {
        var chains: std.ArrayListUnmanaged(ChainItem) = .empty;

        const first_pipeline = try self.parsePipeline() orelse return null;
        try chains.append(self.allocator, .{ .op = .none, .pipeline = first_pipeline });

        while (self.tryParseLogicalOp()) |op| {
            _ = self.advance();
            self.skipSeperators();
            const pipeline = try self.parsePipeline() orelse return ParseError.UnexpectedEOF;
            try chains.append(self.allocator, .{ .op = op, .pipeline = pipeline });
        }

        return try chains.toOwnedSlice(self.allocator);
    }

    // =========================================================================
    // Block scanning helpers
    // =========================================================================

    /// Scans forward to find a block terminator, handling nested blocks.
    /// Returns the position of the terminator, leaving the parser AT the terminator (not past it).
    ///
    /// `terminators` specifies which keywords (besides "end" at depth 0) can end the scan.
    /// For example, parseIfBranch passes &.{"else"} to stop at "else" at depth 1.
    fn scanToBlockEnd(self: *Parser, terminators: []const []const u8) ?usize {
        var depth: usize = 1;

        while (self.pos < self.tokens.len) {
            if (self.isBlockStart()) {
                // Check if this is "else if" - don't increment depth since it's part of the same if statement
                const is_else_if = blk: {
                    if (!self.isOp("if") or self.pos == 0) break :blk false;
                    const prev_tok = self.tokens[self.pos - 1];
                    break :blk prev_tok.kind == .word and
                           prev_tok.kind.word.len == 1 and
                           prev_tok.kind.word[0].quotes == .none and
                           std.mem.eql(u8, prev_tok.kind.word[0].text, "else");
                };
                if (!is_else_if) {
                    depth += 1;
                }
                _ = self.advance();
            } else if (self.isOp("end")) {
                depth -= 1;
                if (depth == 0) return self.pos;
                _ = self.advance();
            } else {
                // Check custom terminators at depth 1
                if (depth == 1) {
                    for (terminators) |term| {
                        if (self.isOp(term)) return self.pos;
                    }
                }
                _ = self.advance();
            }
        }
        return null;
    }

    // =========================================================================
    // Source extraction utilities
    // =========================================================================

    /// Extracts source text between two token positions.
    /// Returns empty string if positions are invalid or input is unavailable.
    fn extractSourceRange(self: *const Parser, start_pos: usize, end_pos: usize) []const u8 {
        if (self.input.len == 0) return "";
        if (start_pos >= end_pos or start_pos >= self.tokens.len) return "";

        const start_byte = self.tokens[start_pos].span.start;
        const end_byte = if (end_pos < self.tokens.len)
            self.tokens[end_pos].span.start
        else
            self.input.len;

        if (start_byte >= end_byte) return "";

        return self.input[start_byte..@min(end_byte, self.input.len)];
    }

    /// Captures source text from current position until a block terminator.
    /// Returns the trimmed body text with parser positioned at the terminator.
    fn captureBlockBody(self: *Parser, terminators: []const []const u8, err: ParseError) ParseError![]const u8 {
        const body_start = self.pos;
        const end_pos = self.scanToBlockEnd(terminators) orelse return err;
        return std.mem.trim(u8, self.extractSourceRange(body_start, end_pos), " \t\n");
    }

    /// Captures condition source (tokens until separator or terminators).
    /// Advances past the condition and skips trailing separators.
    fn captureCondition(self: *Parser, terminators: []const []const u8) []const u8 {
        const start = self.pos;
        while (self.pos < self.tokens.len and !self.isSeperator()) {
            for (terminators) |term| {
                if (self.isOp(term)) {
                    const result = self.extractSourceRange(start, self.pos);
                    return std.mem.trim(u8, result, " \t\n");
                }
            }
            _ = self.advance();
        }
        const result = self.extractSourceRange(start, self.pos);
        self.skipSeperators();
        return std.mem.trim(u8, result, " \t\n");
    }

    // =========================================================================
    // Control flow statement parsing
    // =========================================================================

    /// Parses a function definition: `fun name ... end`
    fn parseFunctionDefinition(self: *Parser) ParseError!Statement {
        _ = self.advance(); // consume 'fun'
        self.skipSeperators();

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

        self.skipSeperators();

        const body = try self.captureBlockBody(&.{}, ParseError.UnterminatedFunction);
        _ = self.advance(); // consume 'end'

        return Statement{ .kind = .{ .function = FunctionDefinition{ .name = name, .body = body } } };
    }

    /// Parses an if statement with optional else-if chains:
    ///   `if cond1; body1; else if cond2; body2; else; body3; end`
    fn parseIfStatement(self: *Parser) ParseError!Statement {
        var branches: std.ArrayListUnmanaged(IfBranch) = .empty;

        _ = self.advance(); // consume 'if'
        const first_branch = try self.parseIfBranch();
        try branches.append(self.allocator, first_branch);

        // Parse else-if chains and final else
        var else_body: ?[]const u8 = null;

        while (self.pos < self.tokens.len) {
            if (self.isOp("else")) {
                _ = self.advance(); // consume 'else'
                self.skipSeperators();

                if (self.isOp("if")) {
                    // else if - parse another branch
                    _ = self.advance(); // consume 'if'
                    const branch = try self.parseIfBranch();
                    try branches.append(self.allocator, branch);
                } else {
                    // Final else - capture body until end
                    else_body = try self.captureBlockBody(&.{}, ParseError.UnterminatedIf);
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
            .branches = try branches.toOwnedSlice(self.allocator),
            .else_body = else_body,
        } } };
    }

    /// Parses a single if/else-if branch (condition + body).
    /// Expects parser to be positioned after 'if' keyword.
    fn parseIfBranch(self: *Parser) ParseError!IfBranch {
        self.skipSeperators();

        const condition = self.captureCondition(&.{ "end", "else" });
        const body = try self.captureBlockBody(&.{"else"}, ParseError.UnterminatedIf);

        return IfBranch{ .condition = condition, .body = body };
    }

    /// Parses a for loop: `for var in items... end`
    fn parseForStatement(self: *Parser) ParseError!Statement {
        _ = self.advance(); // consume 'for'
        self.skipSeperators();

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

        self.skipSeperators();

        // Expect 'in' keyword
        if (!self.isOp("in")) return ParseError.InvalidForLoop;
        _ = self.advance(); // consume 'in'
        self.skipSeperators();

        // Items: everything until separator (newline or semicolon)
        const items_source = self.captureCondition(&.{"end"});
        const body = try self.captureBlockBody(&.{}, ParseError.UnterminatedFor);
        _ = self.advance(); // consume 'end'

        return Statement{ .kind = .{ .@"for" = ForStatement{
            .variable = variable,
            .items_source = items_source,
            .body = body,
        } } };
    }

    /// Parses a while loop: `while condition ... end`
    fn parseWhileStatement(self: *Parser) ParseError!Statement {
        _ = self.advance(); // consume 'while'
        self.skipSeperators();

        const condition = self.captureCondition(&.{"end"});
        const body = try self.captureBlockBody(&.{}, ParseError.UnterminatedWhile);
        _ = self.advance(); // consume 'end'

        return Statement{ .kind = .{ .@"while" = WhileStatement{
            .condition = condition,
            .body = body,
        } } };
    }

    // =========================================================================
    // Statement parsing
    // =========================================================================

    /// Parses a single statement (command, control flow, or function definition).
    fn parseStatement(self: *Parser) ParseError!?Statement {
        // Control flow and function definitions
        if (self.isOp("fun")) return try self.parseFunctionDefinition();
        if (self.isOp("if")) return try self.parseIfStatement();
        if (self.isOp("for")) return try self.parseForStatement();
        if (self.isOp("while")) return try self.parseWhileStatement();

        // Simple statements
        if (self.isOp("break")) {
            _ = self.advance();
            return Statement{ .kind = .@"break" };
        }
        if (self.isOp("continue")) {
            _ = self.advance();
            return Statement{ .kind = .@"continue" };
        }
        if (self.isOp("return")) {
            _ = self.advance();
            // Check for optional status argument
            const status_parts: ?[]const WordPart = if (self.isWord()) blk: {
                const tok = self.peek().?;
                _ = self.advance();
                break :blk tok.kind.word;
            } else null;
            return Statement{ .kind = .{ .@"return" = status_parts } };
        }
        if (self.isOp("defer")) {
            _ = self.advance(); // consume 'defer'
            // Capture the rest of the line as the deferred command (until separator)
            const start = self.pos;
            while (self.pos < self.tokens.len and !self.isSeperator()) {
                _ = self.advance();
            }
            const cmd_source = std.mem.trim(u8, self.extractSourceRange(start, self.pos), " \t\n");
            // Note: do NOT skip separators here - let the main loop handle them
            return Statement{ .kind = .{ .@"defer" = cmd_source } };
        }

        // Command statement
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
            const parts = var_tok.kind.word;
            if (parts.len == 1 and parts[0].quotes == .none) {
                capture = .{ .mode = mode, .variable = parts[0].text };
            } else {
                return ParseError.InvalidCapture;
            }
        }

        return Statement{ .kind = .{ .command = CommandStatement{
            .background = background,
            .capture = capture,
            .chains = chains,
        } } };
    }

    // =========================================================================
    // Main parsing entry point
    // =========================================================================

    pub fn parse(self: *Parser) ParseError!Program {
        var statements: std.ArrayListUnmanaged(Statement) = .empty;

        self.skipSeperators();
        while (self.pos < self.tokens.len) {
            self.skipSeperators();
            if (self.pos >= self.tokens.len) break;

            if (try self.parseStatement()) |stmt| {
                try statements.append(self.allocator, stmt);
            } else {
                break;
            }

            if (self.pos < self.tokens.len) {
                if (self.isSeperator()) {
                    self.skipSeperators();
                } else if (self.isOp("&")) {
                    continue;
                } else {
                    break;
                }
            }
        }

        return Program{ .statements = try statements.toOwnedSlice(self.allocator) };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const lexer = @import("lexer.zig");

/// Tokenizes and parses input, returning the parsed program.
fn parseTest(arena: *std.heap.ArenaAllocator, input: []const u8) !Program {
    const allocator = arena.allocator();
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();
    var p = Parser.initWithInput(allocator, tokens, input);
    return try p.parse();
}

/// Tokenizes and parses input without source (for tests that don't need body extraction).
fn parseTestNoSource(arena: *std.heap.ArenaAllocator, input: []const u8) !Program {
    const allocator = arena.allocator();
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();
    var p = Parser.init(allocator, tokens);
    return try p.parse();
}

test "Commands: simple command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTestNoSource(&arena, "echo hello");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const cmd_stmt = prog.statements[0].kind.command;
    try testing.expectEqual(false, cmd_stmt.background);
    try testing.expectEqual(@as(?Capture, null), cmd_stmt.capture);
    try testing.expectEqual(@as(usize, 1), cmd_stmt.chains.len);
    try testing.expectEqual(ast.ChainOperator.none, cmd_stmt.chains[0].op);
    try testing.expectEqual(@as(usize, 1), cmd_stmt.chains[0].pipeline.commands.len);
    try testing.expectEqual(@as(usize, 2), cmd_stmt.chains[0].pipeline.commands[0].words.len);
}

test "Commands: pipeline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTestNoSource(&arena, "cat file | grep foo | wc -l");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const pipeline = prog.statements[0].kind.command.chains[0].pipeline;
    try testing.expectEqual(@as(usize, 3), pipeline.commands.len);
}

test "Commands: background execution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTestNoSource(&arena, "sleep 10 &");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expectEqual(true, prog.statements[0].kind.command.background);
}

test "Capture: string mode (=>)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTestNoSource(&arena, "whoami => user");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    if (prog.statements[0].kind.command.capture) |cap| {
        try testing.expectEqual(CaptureMode.string, cap.mode);
        try testing.expectEqualStrings("user", cap.variable);
    } else {
        return error.TestExpectedEqual;
    }
}

test "Capture: lines mode (=>@)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTestNoSource(&arena, "ls =>@ files");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    if (prog.statements[0].kind.command.capture) |cap| {
        try testing.expectEqual(CaptureMode.lines, cap.mode);
        try testing.expectEqualStrings("files", cap.variable);
    } else {
        return error.TestExpectedEqual;
    }
}

test "Logical: && and || operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTestNoSource(&arena, "true && echo ok || echo fail");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const cmd_stmt = prog.statements[0].kind.command;
    try testing.expectEqual(@as(usize, 3), cmd_stmt.chains.len);
    try testing.expectEqual(ast.ChainOperator.none, cmd_stmt.chains[0].op);
    try testing.expectEqual(ast.ChainOperator.@"and", cmd_stmt.chains[1].op);
    try testing.expectEqual(ast.ChainOperator.@"or", cmd_stmt.chains[2].op);
}

test "Redirections: input and output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTestNoSource(&arena, "cat < in.txt > out.txt");

    const cmd = prog.statements[0].kind.command.chains[0].pipeline.commands[0];
    try testing.expectEqual(@as(usize, 2), cmd.redirects.len);

    // Input redirect
    const r1 = cmd.redirects[0];
    try testing.expectEqual(@as(u8, 0), r1.from_fd);
    switch (r1.kind) {
        .read => |parts| {
            try testing.expectEqual(@as(usize, 1), parts.len);
            try testing.expectEqualStrings("in.txt", parts[0].text);
        },
        else => return error.TestExpectedEqual,
    }

    // Output redirect
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

test "Assignments: environment prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTestNoSource(&arena, "FOO=bar env");

    const cmd = prog.statements[0].kind.command.chains[0].pipeline.commands[0];
    try testing.expectEqual(@as(usize, 1), cmd.assignments.len);
    try testing.expectEqualStrings("FOO", cmd.assignments[0].key);
}

test "Functions: basic definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "fun greet\n  echo hello\nend";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const fun_def = prog.statements[0].kind.function;
    try testing.expectEqualStrings("greet", fun_def.name);
    try testing.expect(std.mem.indexOf(u8, fun_def.body, "echo hello") != null);
}

test "Functions: inline definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "fun greet echo hello end";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const fun_def = prog.statements[0].kind.function;
    try testing.expectEqualStrings("greet", fun_def.name);
    try testing.expect(std.mem.indexOf(u8, fun_def.body, "echo hello") != null);
}

test "Functions: nested definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "fun outer\n  fun inner\n    echo inner\n  end\n  inner\nend";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const fun_def = prog.statements[0].kind.function;
    try testing.expectEqualStrings("outer", fun_def.name);
    // Body should contain the nested fun...end
    try testing.expect(std.mem.indexOf(u8, fun_def.body, "fun inner") != null);
    try testing.expect(std.mem.indexOf(u8, fun_def.body, "end") != null);
}

test "Functions: unterminated error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "fun greet\n  echo hello";
    var lex = lexer.Lexer.init(arena.allocator(), input);
    const tokens = try lex.tokenize();
    var p = Parser.initWithInput(arena.allocator(), tokens, input);

    try testing.expectError(ParseError.UnterminatedFunction, p.parse());
}

test "Functions: invalid name error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "fun \"quoted\" body end";
    var lex = lexer.Lexer.init(arena.allocator(), input);
    const tokens = try lex.tokenize();
    var p = Parser.initWithInput(arena.allocator(), tokens, input);

    try testing.expectError(ParseError.InvalidFunctionName, p.parse());
}

test "If: simple statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "if true\n  echo yes\nend";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 1), @"if".branches.len);
    try testing.expectEqualStrings("true", @"if".branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "echo yes") != null);
    try testing.expectEqual(@as(?[]const u8, null), @"if".else_body);
}

test "If: with else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "if false\n  echo no\nelse\n  echo yes\nend";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 1), @"if".branches.len);
    try testing.expectEqualStrings("false", @"if".branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "echo no") != null);
    try testing.expect(@"if".else_body != null);
    try testing.expect(std.mem.indexOf(u8, @"if".else_body.?, "echo yes") != null);
}

test "If: inline statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "if true; echo yes; end";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 1), @"if".branches.len);
    try testing.expectEqualStrings("true", @"if".branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "echo yes") != null);
}

test "If: nested statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "if true\n  if false\n    echo inner\n  end\nend";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 1), @"if".branches.len);
    try testing.expectEqualStrings("true", @"if".branches[0].condition);
    // Body should contain the nested if...end
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "if false") != null);
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "end") != null);
}

test "If: else-if chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "if test $x -eq 1\n  echo one\nelse if test $x -eq 2\n  echo two\nelse\n  echo other\nend";
    const prog = try parseTest(&arena, input);

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

test "If: else-if without final else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "if false; echo a; else if true; echo b; end";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 2), @"if".branches.len);
    try testing.expectEqual(@as(?[]const u8, null), @"if".else_body);
}

test "If: unterminated error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "if true\n  echo yes";
    var lex = lexer.Lexer.init(arena.allocator(), input);
    const tokens = try lex.tokenize();
    var p = Parser.initWithInput(arena.allocator(), tokens, input);

    try testing.expectError(ParseError.UnterminatedIf, p.parse());
}

test "While: simple statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "while test -f file\n  sleep 1\nend";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const while_stmt = prog.statements[0].kind.@"while";
    try testing.expectEqualStrings("test -f file", while_stmt.condition);
    try testing.expect(std.mem.indexOf(u8, while_stmt.body, "sleep 1") != null);
}

test "While: inline statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "while true; echo loop; end";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const while_stmt = prog.statements[0].kind.@"while";
    try testing.expectEqualStrings("true", while_stmt.condition);
    try testing.expect(std.mem.indexOf(u8, while_stmt.body, "echo loop") != null);
}

test "While: nested in if" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "if true\n  while false\n    echo inner\n  end\nend";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const @"if" = prog.statements[0].kind.@"if";
    try testing.expectEqual(@as(usize, 1), @"if".branches.len);
    // Body should contain the nested while...end
    try testing.expect(std.mem.indexOf(u8, @"if".branches[0].body, "while false") != null);
}

test "While: unterminated error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "while true\n  echo loop";
    var lex = lexer.Lexer.init(arena.allocator(), input);
    const tokens = try lex.tokenize();
    var p = Parser.initWithInput(arena.allocator(), tokens, input);

    try testing.expectError(ParseError.UnterminatedWhile, p.parse());
}

test "Control: break statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTest(&arena, "break");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"break");
}

test "Control: continue statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTest(&arena, "continue");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"continue");
}

test "Return: without argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTest(&arena, "return");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"return");
    try testing.expectEqual(@as(?[]const WordPart, null), prog.statements[0].kind.@"return");
}

test "Return: with status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTest(&arena, "return 1");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"return");
    const parts = prog.statements[0].kind.@"return".?;
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqualStrings("1", parts[0].text);
}

test "Return: with zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTest(&arena, "return 0");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"return");
    const parts = prog.statements[0].kind.@"return".?;
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqualStrings("0", parts[0].text);
}

test "Return: with variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTest(&arena, "return $status");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"return");
    try testing.expect(prog.statements[0].kind.@"return" != null);
}

test "Defer: simple command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try parseTest(&arena, "defer rm -rf $tmpdir");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    try testing.expect(prog.statements[0].kind == .@"defer");
    try testing.expectEqualStrings("rm -rf $tmpdir", prog.statements[0].kind.@"defer");
}

test "Defer: in function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "fun cleanup\n  defer echo done\n  echo working\nend";
    const prog = try parseTest(&arena, input);

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    const fun_def = prog.statements[0].kind.function;
    try testing.expectEqualStrings("cleanup", fun_def.name);
    try testing.expect(std.mem.indexOf(u8, fun_def.body, "defer echo done") != null);
}
