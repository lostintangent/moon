//! Expanded types - the fully resolved representation ready for execution
//!
//! The expander transforms AST nodes into expanded types. Statement-level types
//! use ast.StatementKind directly since control flow statements (if, for, while, etc.)
//! store their bodies as strings and are re-parsed at runtime.
//!
//! TRANSFORMED (new types defined below):
//!   - ExpandedCmd - expands $vars, globs, ~, $(cmd) into flat argv
//!   - ExpandedRedirect - expands redirections (paths as strings)

pub const ast = @import("../../language/ast.zig");

// =============================================================================
// Re-exported from AST (needed by other modules)
// =============================================================================

pub const CaptureMode = ast.CaptureMode;
pub const Capture = ast.Capture;

// =============================================================================
// Expanded Redirect Types
// =============================================================================

/// The type of I/O redirection after expansion (paths are strings).
pub const ExpandedRedirectKind = union(enum) {
    /// Redirect input from a file to fd (defaults to stdin)
    read: []const u8,
    /// Redirect output to a file (truncate) from fd (defaults to stdout)
    write_truncate: []const u8,
    /// Redirect output to a file (append) from fd (defaults to stdout)
    write_append: []const u8,
    /// Duplicate one fd to another (e.g., 2>&1)
    dup: u8,
};

/// A single I/O redirection after expansion (paths are resolved strings).
pub const ExpandedRedirect = struct {
    /// File descriptor being redirected (0=stdin, 1=stdout, 2=stderr)
    from_fd: u8,
    /// The type and target of the redirection
    kind: ExpandedRedirectKind,
};

// =============================================================================
// Transformed types (planner does actual work here)
// =============================================================================

/// Command - fully expanded and ready to exec
/// AST has: Command { words: [][]WordPart, ... } with $vars, globs, quotes
/// Expanded has: ExpandedCmd { argv: ["echo", "hello", "a.txt", "b.txt"], ... } flat strings
pub const ExpandedCmd = struct {
    argv: []const []const u8,
    env: []const ast.Assignment,
    redirects: []const ExpandedRedirect,
};
