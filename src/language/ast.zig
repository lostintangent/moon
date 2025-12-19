//! Abstract Syntax Tree types produced by the parser.
//!
//! The AST is the syntax-only view of a parsed program—no expansion, no runtime
//! state. Key shapes:
//! - `Program`: Top-level list of `Statement`. There's always exactly one.
//! - `Statement`: A tagged union that represents commands, function definitions, and
//!   control flow statements.
//! - `CommandStatement`: A logical chain of pipelines with optional capture or
//!   background execution.
//! - `Pipeline`/`Command`/`Assignment`/`Redirect`: The components of a simple shell
//!   command (argv, env prefixes, redirects).
//! - Control flow: `IfStatement`, `ForStatement`, `WhileStatement`,
//!   `FunctionDefinition`

const std = @import("std");
const tokens = @import("tokens.zig");

pub const WordPart = tokens.WordPart;
pub const QuoteKind = tokens.QuoteKind;

pub const FunctionDefinition = struct {
    name: []const u8,
    body: []const u8,
};

/// A single if/else-if branch with its condition and body
pub const IfBranch = struct {
    condition: []const u8,
    body: []const u8,
};

pub const IfStatement = struct {
    /// First element is the "if" branch, rest are "else if" branches
    branches: []const IfBranch,
    /// Final "else" body if present (no condition)
    else_body: ?[]const u8,
};

pub const ForStatement = struct {
    variable: []const u8,
    items_source: []const u8, // The raw source of items to iterate over
    body: []const u8,
};

pub const WhileStatement = struct {
    condition: []const u8,
    body: []const u8,
};

pub const CaptureMode = enum {
    string,
    lines,
};

pub const Capture = struct {
    mode: CaptureMode,
    variable: []const u8,
};

pub const RedirectKind = union(enum) {
    /// Redirect input from a file to fd (defaults to 0)
    read: []const WordPart,
    /// Redirect output to a file (truncate) from fd (defaults to 1)
    write_truncate: []const WordPart,
    /// Redirect output to a file (append) from fd (defaults to 1)
    write_append: []const WordPart,
    /// Duplicate one fd to another (fd -> dup_to)
    dup: u8,
};

pub const Redirect = struct {
    /// File descriptor being redirected (parsed from operator, e.g., 2>)
    from_fd: u8,
    kind: RedirectKind,
};

pub const Assignment = struct {
    key: []const u8,
    value: []const WordPart,
};

pub const Command = struct {
    assignments: []const Assignment,
    words: []const []const WordPart,
    redirects: []const Redirect,
};

pub const ChainOperator = enum {
    none,
    @"and",
    @"or",
};

pub const Pipeline = struct {
    commands: []const Command,
};

pub const ChainItem = struct {
    op: ChainOperator,
    pipeline: Pipeline,
};

pub const CommandStatement = struct {
    chains: []const ChainItem,
    background: bool,
    capture: ?Capture,
};

pub const StatementKind = union(enum) {
    command: CommandStatement,
    function: FunctionDefinition,
    @"if": IfStatement,
    @"for": ForStatement,
    @"while": WhileStatement,
    @"break": void,
    @"continue": void,
    @"return": ?[]const WordPart,
};

pub const Statement = struct {
    kind: StatementKind,
};

pub const Program = struct {
    statements: []const Statement,
};
