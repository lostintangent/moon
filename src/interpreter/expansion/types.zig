//! Expanded types - the fully resolved representation ready for execution
//!
//! The expander transforms AST nodes into expanded types. Types that pass through
//! unchanged reference ast.zig directly (FunctionDefinition, IfStatement, ForStatement, WhileStatement).
//! New types are defined only where expansion does actual work:
//!
//! UNCHANGED (ast types used directly in ExpandedStmtKind union):
//!   - ast.FunctionDefinition - body stored as string, re-parsed at runtime
//!   - ast.IfStatement - condition/body stored as strings
//!   - ast.ForStatement - items expanded at runtime, not expansion time
//!   - ast.WhileStatement - condition re-evaluated each iteration
//!
//! TRANSFORMED (new types defined below):
//!   - ExpandedRedir - parses ">" into structured {fd, kind, path}
//!   - ExpandedCmd - expands $vars, globs, ~, $(cmd) into flat argv
//!   - EnvKV - expands assignment values
//!   - ExpandedChain - normalizes && to "and", || to "or"

pub const ast = @import("../../language/ast.zig");

// =============================================================================
// Re-exported from AST (needed by other modules)
// =============================================================================

pub const CaptureMode = ast.CaptureMode;
pub const Capture = ast.Capture;

// =============================================================================
// Transformed types (planner does actual work here)
// =============================================================================

/// Redirection - parsed from string operator to structured form
/// AST has: RedirAst { op: ">", target: []WordPart }
/// Expanded has: ExpandedRedir { fd: 1, kind: .write_truncate, path: "file.txt" }
pub const RedirKind = enum {
    read,
    write_truncate,
    write_append,
    dup,
};

pub const ExpandedRedir = struct {
    fd: u8,
    kind: RedirKind,
    path: ?[]const u8 = null,
    to: ?u8 = null,

    pub fn initRead(fd: u8, path: []const u8) ExpandedRedir {
        return .{ .fd = fd, .kind = .read, .path = path, .to = null };
    }

    pub fn initWriteTruncate(fd: u8, path: []const u8) ExpandedRedir {
        return .{ .fd = fd, .kind = .write_truncate, .path = path, .to = null };
    }

    pub fn initWriteAppend(fd: u8, path: []const u8) ExpandedRedir {
        return .{ .fd = fd, .kind = .write_append, .path = path, .to = null };
    }

    pub fn initDup(fd: u8, to: u8) ExpandedRedir {
        return .{ .fd = fd, .kind = .dup, .path = null, .to = to };
    }
};

/// Environment variable for command - value is expanded
/// AST has: Assignment { key, value: []WordPart }
/// Plan has: EnvKV { key, value: "expanded string" }
pub const EnvKV = struct {
    key: []const u8,
    value: []const u8,
};

/// Command - fully expanded and ready to exec
/// AST has: Command { words: [][]WordPart, ... } with $vars, globs, quotes
/// Expanded has: ExpandedCmd { argv: ["echo", "hello", "a.txt", "b.txt"], ... } flat strings
pub const ExpandedCmd = struct {
    argv: []const []const u8,
    env: []const EnvKV,
    redirects: []const ExpandedRedir,
};

/// Pipeline - list of expanded commands
pub const ExpandedPipeline = struct {
    commands: []const ExpandedCmd,
};

pub const ExpandedChain = struct {
    op: ast.ChainOperator,
    pipeline: ExpandedPipeline,
};

/// Command statement
pub const ExpandedCmdStmt = struct {
    background: bool,
    capture: ?Capture,
    chains: []const ExpandedChain,
};

// =============================================================================
// Statement wrapper (mirrors AST structure)
// =============================================================================

pub const ExpandedStmtKind = union(enum) {
    command: ExpandedCmdStmt,
    function: ast.FunctionDefinition,
    @"if": ast.IfStatement,
    @"for": ast.ForStatement,
    @"while": ast.WhileStatement,
    @"break": void,
    @"continue": void,
    @"return": ?[]const u8, // Expanded string value (parsed to u8 at execution)
};

pub const ExpandedStmt = struct {
    kind: ExpandedStmtKind,
};

pub const ExpandedProgram = struct {
    statements: []const ExpandedStmt,
};
