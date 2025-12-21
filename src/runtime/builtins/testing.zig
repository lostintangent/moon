//! Shared test utilities for builtin commands

const builtins = @import("../builtins.zig");

/// Create an ExpandedCmd for testing with minimal boilerplate.
pub fn makeCmd(argv: []const []const u8) builtins.ExpandedCmd {
    return builtins.ExpandedCmd{
        .argv = argv,
        .env = &.{},
        .redirects = &.{},
    };
}
