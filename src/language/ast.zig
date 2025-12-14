//! Abstract Syntax Tree types produced by the parser.
//!
//! The AST represents the structural form of shell input after parsing:
//! - `Program`: a sequence of statements
//! - `Statement`: a single executable unit (command, function def, control flow)
//! - `StatementKind`: discriminated union of statement variants
//! - `CommandStatement`: a command/pipeline with optional capture and background
//! - `Pipeline`, `Command`, `Assign`, `RedirAst`: lower-level command structures
//! - Control flow: `IfStmt`, `ForStmt`, `WhileStmt`, `FunDef`
const std = @import("std");
const tokens = @import("tokens.zig");

pub const WordPart = tokens.WordPart;
pub const QuoteKind = tokens.QuoteKind;

// AST types
pub const CaptureMode = enum {
    string,
    lines,
};

pub const Capture = struct {
    mode: CaptureMode,
    variable: []const u8,
};

pub const RedirAst = struct {
    op: []const u8,
    target: ?[]const WordPart,
};

pub const Assign = struct {
    key: []const u8,
    value: []const WordPart,
};

pub const Command = struct {
    assigns: []const Assign,
    words: []const []const WordPart,
    redirs: []const RedirAst,
};

pub const Pipeline = struct {
    cmds: []const Command,
};

pub const ChainItem = struct {
    op: ?[]const u8,
    pipeline: Pipeline,
};

/// Function definition: fun name ... end
/// Ownership: name and body are slices into the parser's input buffer (arena-owned).
pub const FunDef = struct {
    name: []const u8,
    body: []const u8,
};

/// A single if/else-if branch with its condition and body
pub const IfBranch = struct {
    condition: []const u8,
    body: []const u8,
};

/// If statement with optional else-if chains: if cond1 ... else if cond2 ... else ... end
/// Ownership: all strings are slices into parser's input buffer (arena-owned).
pub const IfStmt = struct {
    /// First element is the "if" branch, rest are "else if" branches
    branches: []const IfBranch,
    /// Final "else" body if present (no condition)
    else_body: ?[]const u8,
};

/// For loop: for var in items... end
/// Ownership: variable, items_source, and body are slices into parser's input buffer (arena-owned).
pub const ForStmt = struct {
    variable: []const u8,
    items_source: []const u8, // The raw source of items to iterate over
    body: []const u8,
};

/// While loop: while condition ... end
/// Ownership: condition and body are slices into parser's input buffer (arena-owned).
pub const WhileStmt = struct {
    condition: []const u8,
    body: []const u8,
};

/// A statement can be either a regular command statement or a function definition
pub const StatementKind = union(enum) {
    /// Regular command/pipeline statement
    cmd: CommandStatement,
    /// Function definition
    fun_def: FunDef,
    /// If statement
    if_stmt: IfStmt,
    /// For loop
    for_stmt: ForStmt,
    /// While loop
    while_stmt: WhileStmt,
    /// Break from loop
    break_stmt: void,
    /// Continue to next iteration
    continue_stmt: void,
};

/// Command statement: a pipeline chain with optional capture and background execution
pub const CommandStatement = struct {
    bg: bool,
    capture: ?Capture,
    chains: []const ChainItem,
};

pub const Statement = struct {
    kind: StatementKind,

    /// Helper to check if this is a background job (only for cmd statements)
    pub fn isBg(self: Statement) bool {
        return switch (self.kind) {
            .cmd => |cmd| cmd.bg,
            .fun_def, .if_stmt, .for_stmt, .while_stmt, .break_stmt, .continue_stmt => false,
        };
    }
};

pub const Program = struct {
    statements: []const Statement,
};
