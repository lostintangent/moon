//! Expanded types - the fully resolved representation ready for execution
//!
//! The expander transforms AST nodes into expanded types. Statement-level types
//! use ast.StatementKind directly since control flow statements (if, for, while, etc.)
//! store their bodies as strings and are re-parsed at runtime.
//!
//! TRANSFORMED (new types defined below):
//!   - ExpandedCmd - expands $vars, globs, ~, $(cmd) into flat argv
//!   - Uses ast.Assignment for expanded environment variables
//!   - Uses ast.Redirect for expanded redirections

pub const ast = @import("../../language/ast.zig");

// =============================================================================
// Re-exported from AST (needed by other modules)
// =============================================================================

pub const CaptureMode = ast.CaptureMode;
pub const Capture = ast.Capture;

// =============================================================================
// Transformed types (planner does actual work here)
// =============================================================================

/// Command - fully expanded and ready to exec
/// AST has: Command { words: [][]WordPart, ... } with $vars, globs, quotes
/// Expanded has: ExpandedCmd { argv: ["echo", "hello", "a.txt", "b.txt"], ... } flat strings
pub const ExpandedCmd = struct {
    argv: []const []const u8,
    env: []const ast.Assignment,
    redirects: []const ast.Redirect,
};
