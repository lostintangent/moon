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
const TokenKind = token_types.TokenKind;
const WordPart = token_types.WordPart;
const QuoteKind = token_types.QuoteKind;
const Program = ast.Program;
const Statement = ast.Statement;
const StatementKind = ast.StatementKind;
const CommandStatement = ast.CommandStatement;
const FunDef = ast.FunDef;
const IfStmt = ast.IfStmt;
const IfBranch = ast.IfBranch;
const ForStmt = ast.ForStmt;
const WhileStmt = ast.WhileStmt;
const ChainItem = ast.ChainItem;
const Pipeline = ast.Pipeline;
const Command = ast.Command;
const Assign = ast.Assign;
const RedirAst = ast.RedirAst;
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
        if (self.peek()) |tok| {
            // Check for actual operator tokens
            if (tok.kind() == .op) {
                if (tok.text()) |t| {
                    return std.mem.eql(u8, t, op);
                }
            }
            // Also check for keyword words (like 'if', 'else', 'end', 'fun', 'and', 'or')
            // These are lexed as words but should be treated as keywords in command position
            if (tok.kind() == .word) {
                if (tok.parts()) |segs| {
                    if (segs.len == 1 and segs[0].q == .bare) {
                        if (token_types.isKeyword(segs[0].t)) {
                            return std.mem.eql(u8, segs[0].t, op);
                        }
                    }
                }
            }
        }
        return false;
    }

    fn isSep(self: *Parser) bool {
        if (self.peek()) |tok| {
            return tok.kind() == .sep;
        }
        return false;
    }

    fn isWord(self: *Parser) bool {
        if (self.peek()) |tok| {
            return tok.kind() == .word;
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
        if (word_parts[0].q != .bare) return null;

        const text = word_parts[0].t;
        const eq_pos = std.mem.indexOf(u8, text, "=") orelse return null;

        if (eq_pos == 0) return null;
        const key = text[0..eq_pos];

        if (!token_types.isIdentStart(key[0])) return null;
        for (key[1..]) |c| {
            if (!token_types.isIdentChar(c)) return null;
        }

        return .{ .key = key, .value = text[eq_pos + 1 ..] };
    }

    fn isRedirOp(text: []const u8) bool {
        return token_types.redir_ops.has(text);
    }

    fn isPipeOp(text: []const u8) bool {
        return token_types.pipe_ops.has(text);
    }

    fn isLogicalOp(text: []const u8) bool {
        return token_types.logical_ops.has(text);
    }

    fn parseRedir(self: *Parser) ParseError!?RedirAst {
        if (self.peek()) |tok| {
            if (tok.kind() == .op) {
                if (tok.text()) |op_text| {
                    if (isRedirOp(op_text)) {
                        _ = self.advance();

                        if (std.mem.eql(u8, op_text, "2>&1")) {
                            return RedirAst{ .op = op_text, .target = null };
                        }

                        if (self.isWord()) {
                            const word_tok = self.advance().?;
                            return RedirAst{ .op = op_text, .target = word_tok.parts() };
                        }

                        return ParseError.UnexpectedEOF;
                    }
                }
            }
        }
        return null;
    }

    /// Check if the current word token is a logical operator keyword (and, or)
    fn isLogicalKeyword(self: *Parser) bool {
        if (self.peek()) |tok| {
            if (tok.kind() == .word) {
                if (tok.parts()) |segs| {
                    if (segs.len == 1 and segs[0].q == .bare) {
                        const t = segs[0].t;
                        return std.mem.eql(u8, t, "and") or std.mem.eql(u8, t, "or");
                    }
                }
            }
        }
        return false;
    }

    fn parseCommand(self: *Parser) ParseError!?Command {
        var assigns: std.ArrayListUnmanaged(Assign) = .empty;
        var words: std.ArrayListUnmanaged([]const WordPart) = .empty;
        var redirs: std.ArrayListUnmanaged(RedirAst) = .empty;

        while (self.isWord() and !self.isLogicalKeyword()) {
            const tok = self.peek().?;
            if (tok.parts()) |segs| {
                if (parseEnvPrefix(segs)) |parsed| {
                    _ = self.advance();
                    const value_seg = self.allocator.alloc(WordPart, 1) catch return ParseError.OutOfMemory;
                    value_seg[0] = .{ .q = .bare, .t = parsed.value };
                    assigns.append(self.allocator, .{ .key = parsed.key, .value = value_seg }) catch return ParseError.OutOfMemory;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        while (true) {
            if (try self.parseRedir()) |redir| {
                redirs.append(self.allocator, redir) catch return ParseError.OutOfMemory;
                continue;
            }

            // Stop at logical keywords (and, or) - they belong to parseLogical
            if (self.isWord() and !self.isLogicalKeyword()) {
                const tok = self.advance().?;
                if (tok.parts()) |segs| {
                    words.append(self.allocator, segs) catch return ParseError.OutOfMemory;
                }
                continue;
            }

            break;
        }

        if (words.items.len == 0 and assigns.items.len == 0) {
            return null;
        }

        return Command{
            .assigns = assigns.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .words = words.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .redirs = redirs.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        };
    }

    fn parsePipeline(self: *Parser) ParseError!?Pipeline {
        var cmds: std.ArrayListUnmanaged(Command) = .empty;

        const first_cmd = try self.parseCommand() orelse return null;
        cmds.append(self.allocator, first_cmd) catch return ParseError.OutOfMemory;

        while (true) {
            if (self.peek()) |tok| {
                if (tok.kind() == .op) {
                    if (tok.text()) |op_text| {
                        if (isPipeOp(op_text)) {
                            _ = self.advance();
                            self.skipSeps();
                            const cmd = try self.parseCommand() orelse return ParseError.UnexpectedEOF;
                            cmds.append(self.allocator, cmd) catch return ParseError.OutOfMemory;
                            continue;
                        }
                    }
                }
            }
            break;
        }

        return Pipeline{
            .cmds = cmds.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        };
    }

    fn parseLogical(self: *Parser) ParseError!?[]ChainItem {
        var chains: std.ArrayListUnmanaged(ChainItem) = .empty;

        const first_pipeline = try self.parsePipeline() orelse return null;
        chains.append(self.allocator, .{ .op = null, .pipeline = first_pipeline }) catch return ParseError.OutOfMemory;

        while (true) {
            // Check for logical operators: &&, ||, and, or
            // These can be either op tokens (&&, ||) or word tokens (and, or)
            var op_text: ?[]const u8 = null;

            if (self.peek()) |tok| {
                if (tok.kind() == .op) {
                    if (tok.text()) |t| {
                        if (isLogicalOp(t)) {
                            op_text = t;
                        }
                    }
                } else if (tok.kind() == .word) {
                    // Check if it's a text operator keyword (and, or)
                    if (tok.parts()) |segs| {
                        if (segs.len == 1 and segs[0].q == .bare) {
                            if (isLogicalOp(segs[0].t)) {
                                op_text = segs[0].t;
                            }
                        }
                    }
                }
            }

            if (op_text) |op| {
                _ = self.advance();
                self.skipSeps();
                const pipeline = try self.parsePipeline() orelse return ParseError.UnexpectedEOF;
                chains.append(self.allocator, .{ .op = op, .pipeline = pipeline }) catch return ParseError.OutOfMemory;
            } else {
                break;
            }
        }

        return chains.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
    }

    fn parseStmt(self: *Parser) ParseError!?Statement {
        // Check for function definition: fun name ... end
        if (self.isOp("fun")) {
            return try self.parseFunDef();
        }

        // Check for if statement: if condition ... end
        if (self.isOp("if")) {
            return try self.parseIfStmt();
        }

        // Check for for loop: for var in items... end
        if (self.isOp("for")) {
            return try self.parseForStmt();
        }

        // Check for while loop: while condition ... end
        if (self.isOp("while")) {
            return try self.parseWhileStmt();
        }

        // Check for break statement
        if (self.isOp("break")) {
            _ = self.advance();
            return Statement{ .kind = .break_stmt };
        }

        // Check for continue statement
        if (self.isOp("continue")) {
            _ = self.advance();
            return Statement{ .kind = .continue_stmt };
        }

        const chains = try self.parseLogical() orelse return null;

        var bg = false;
        var capture: ?Capture = null;

        if (self.isOp("&")) {
            bg = true;
            _ = self.advance();
        }

        if (self.isOp("=>") or self.isOp("=>@")) {
            if (bg) return ParseError.CaptureWithBackground;

            const cap_tok = self.advance().?;
            const mode: CaptureMode = if (std.mem.eql(u8, cap_tok.text().?, "=>@")) .lines else .string;

            if (!self.isWord()) return ParseError.InvalidCapture;

            const var_tok = self.advance().?;
            if (var_tok.parts()) |segs| {
                if (segs.len == 1 and segs[0].q == .bare) {
                    capture = .{ .mode = mode, .variable = segs[0].t };
                } else {
                    return ParseError.InvalidCapture;
                }
            } else {
                return ParseError.InvalidCapture;
            }
        }

        return Statement{ .kind = .{ .cmd = CommandStatement{ .bg = bg, .capture = capture, .chains = chains } } };
    }

    /// Parse a function definition: fun name ... end
    fn parseFunDef(self: *Parser) ParseError!Statement {
        _ = self.advance(); // consume 'fun'
        self.skipSeps();

        // Expect function name (a word)
        if (!self.isWord()) return ParseError.InvalidFunctionName;

        const name_tok = self.advance().?;
        const name = blk: {
            if (name_tok.parts()) |segs| {
                if (segs.len == 1 and segs[0].q == .bare) {
                    break :blk segs[0].t;
                }
            }
            return ParseError.InvalidFunctionName;
        };

        self.skipSeps();

        // Capture the body: everything until we see 'end'
        const body_start_pos = self.pos;
        const scan = self.scanToBlockEnd(&.{}) orelse return ParseError.UnterminatedFunction;
        const body = std.mem.trim(u8, self.extractSourceRange(body_start_pos, scan.end_pos), " \t\n");
        _ = self.advance(); // consume 'end'

        return Statement{ .kind = .{ .fun_def = FunDef{ .name = name, .body = body } } };
    }

    /// Parse an if statement with optional else-if chains:
    ///   if cond1; body1; else if cond2; body2; else; body3; end
    /// Condition is everything until first separator (newline or semicolon)
    fn parseIfStmt(self: *Parser) ParseError!Statement {
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

        return Statement{ .kind = .{ .if_stmt = IfStmt{
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
    fn parseForStmt(self: *Parser) ParseError!Statement {
        _ = self.advance(); // consume 'for'
        self.skipSeps();

        // Parse variable name
        if (!self.isWord()) return ParseError.InvalidForLoop;
        const var_tok = self.advance().?;
        const variable = blk: {
            if (var_tok.parts()) |segs| {
                if (segs.len == 1 and segs[0].q == .bare) {
                    break :blk segs[0].t;
                }
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

        return Statement{ .kind = .{ .for_stmt = ForStmt{
            .variable = variable,
            .items_source = items_source,
            .body = body,
        } } };
    }

    /// Parse a while loop: while condition ... end
    /// Syntax: while test -f file; echo waiting; sleep 1; end
    fn parseWhileStmt(self: *Parser) ParseError!Statement {
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

        return Statement{ .kind = .{ .while_stmt = WhileStmt{
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
            token_types.TokenSpan.init(1, 1, 1, 1, self.input.len, self.input.len);

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
    const cmd_stmt = prog.statements[0].kind.cmd;
    try testing.expectEqual(false, cmd_stmt.bg);
    try testing.expectEqual(@as(?Capture, null), cmd_stmt.capture);
    try testing.expectEqual(@as(usize, 1), cmd_stmt.chains.len);
    try testing.expectEqual(@as(?[]const u8, null), cmd_stmt.chains[0].op);
    try testing.expectEqual(@as(usize, 1), cmd_stmt.chains[0].pipeline.cmds.len);
    try testing.expectEqual(@as(usize, 2), cmd_stmt.chains[0].pipeline.cmds[0].words.len);
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
    const pipeline = prog.statements[0].kind.cmd.chains[0].pipeline;
    try testing.expectEqual(@as(usize, 3), pipeline.cmds.len);
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
    try testing.expectEqual(true, prog.statements[0].kind.cmd.bg);
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
    if (prog.statements[0].kind.cmd.capture) |cap| {
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
    if (prog.statements[0].kind.cmd.capture) |cap| {
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
    const cmd_stmt = prog.statements[0].kind.cmd;
    try testing.expectEqual(@as(usize, 3), cmd_stmt.chains.len);
    try testing.expectEqual(@as(?[]const u8, null), cmd_stmt.chains[0].op);
    try testing.expectEqualStrings("&&", cmd_stmt.chains[1].op.?);
    try testing.expectEqualStrings("||", cmd_stmt.chains[2].op.?);
}

test "redirections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lex = lexer.Lexer.init(allocator, "cat < in.txt > out.txt");
    const tokens = try lex.tokenize();

    var p = Parser.init(allocator, tokens);
    const prog = try p.parse();

    const cmd = prog.statements[0].kind.cmd.chains[0].pipeline.cmds[0];
    try testing.expectEqual(@as(usize, 2), cmd.redirs.len);
    try testing.expectEqualStrings("<", cmd.redirs[0].op);
    try testing.expectEqualStrings(">", cmd.redirs[1].op);
}

test "env prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lex = lexer.Lexer.init(allocator, "FOO=bar env");
    const tokens = try lex.tokenize();

    var p = Parser.init(allocator, tokens);
    const prog = try p.parse();

    const cmd = prog.statements[0].kind.cmd.chains[0].pipeline.cmds[0];
    try testing.expectEqual(@as(usize, 1), cmd.assigns.len);
    try testing.expectEqualStrings("FOO", cmd.assigns[0].key);
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
    const fun_def = prog.statements[0].kind.fun_def;
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
    const fun_def = prog.statements[0].kind.fun_def;
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
    const fun_def = prog.statements[0].kind.fun_def;
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
    const if_stmt = prog.statements[0].kind.if_stmt;
    try testing.expectEqual(@as(usize, 1), if_stmt.branches.len);
    try testing.expectEqualStrings("true", if_stmt.branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, if_stmt.branches[0].body, "echo yes") != null);
    try testing.expectEqual(@as(?[]const u8, null), if_stmt.else_body);
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
    const if_stmt = prog.statements[0].kind.if_stmt;
    try testing.expectEqual(@as(usize, 1), if_stmt.branches.len);
    try testing.expectEqualStrings("false", if_stmt.branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, if_stmt.branches[0].body, "echo no") != null);
    try testing.expect(if_stmt.else_body != null);
    try testing.expect(std.mem.indexOf(u8, if_stmt.else_body.?, "echo yes") != null);
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
    const if_stmt = prog.statements[0].kind.if_stmt;
    try testing.expectEqual(@as(usize, 1), if_stmt.branches.len);
    try testing.expectEqualStrings("true", if_stmt.branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, if_stmt.branches[0].body, "echo yes") != null);
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
    const if_stmt = prog.statements[0].kind.if_stmt;
    try testing.expectEqual(@as(usize, 1), if_stmt.branches.len);
    try testing.expectEqualStrings("true", if_stmt.branches[0].condition);
    // Body should contain the nested if...end
    try testing.expect(std.mem.indexOf(u8, if_stmt.branches[0].body, "if false") != null);
    try testing.expect(std.mem.indexOf(u8, if_stmt.branches[0].body, "end") != null);
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
    const if_stmt = prog.statements[0].kind.if_stmt;
    try testing.expectEqual(@as(usize, 2), if_stmt.branches.len);
    try testing.expectEqualStrings("test $x -eq 1", if_stmt.branches[0].condition);
    try testing.expect(std.mem.indexOf(u8, if_stmt.branches[0].body, "echo one") != null);
    try testing.expectEqualStrings("test $x -eq 2", if_stmt.branches[1].condition);
    try testing.expect(std.mem.indexOf(u8, if_stmt.branches[1].body, "echo two") != null);
    try testing.expect(if_stmt.else_body != null);
    try testing.expect(std.mem.indexOf(u8, if_stmt.else_body.?, "echo other") != null);
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
    const if_stmt = prog.statements[0].kind.if_stmt;
    try testing.expectEqual(@as(usize, 2), if_stmt.branches.len);
    try testing.expectEqual(@as(?[]const u8, null), if_stmt.else_body);
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
    const while_stmt = prog.statements[0].kind.while_stmt;
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
    const while_stmt = prog.statements[0].kind.while_stmt;
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
    const if_stmt = prog.statements[0].kind.if_stmt;
    try testing.expectEqual(@as(usize, 1), if_stmt.branches.len);
    // Body should contain the nested while...end
    try testing.expect(std.mem.indexOf(u8, if_stmt.branches[0].body, "while false") != null);
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
    try testing.expect(prog.statements[0].kind == .break_stmt);
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
    try testing.expect(prog.statements[0].kind == .continue_stmt);
}
