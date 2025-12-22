//! Expanded types - the fully resolved representation ready for execution
//!
//! The expander transforms AST nodes into expanded types. Statement-level types
//! use ast.StatementKind directly since control flow statements (if, for, while, etc.)
//! store their bodies as strings and are re-parsed at runtime.
//!
//! TRANSFORMED (new types defined below):
//!   - ExpandedRedir - parses ">" into structured {fd, kind, path}
//!   - ExpandedCmd - expands $vars, globs, ~, $(cmd) into flat argv
//!   - EnvKV - expands assignment values

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
