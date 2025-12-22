//! Oshen shell test infrastructure
//!
//! This module contains:
//! - Shared test helpers (TestContext, expectArgvEqual)
//! - Module test discovery for files not in the main import graph
//!
//! Note: Integration/E2E tests have been moved to scripts/e2e.wave

const std = @import("std");
const ast = @import("language/ast.zig");
const expansion_types = @import("interpreter/expansion/expanded.zig");
const State = @import("runtime/state.zig").State;
const expand = @import("interpreter/expansion/word.zig");
const lexer = @import("language/lexer.zig");
const parser = @import("language/parser.zig");
const expansion = @import("interpreter/expansion/statement.zig");

// =============================================================================
// Test Helpers
// =============================================================================

/// Test helper that manages arena, state, and expand context lifecycle.
/// Use `t.ctx` to access the expand context and `t.state` for shell state.
///
/// Example usage:
/// ```zig
/// var t = TestContext.init();
/// t.setup();
/// defer t.deinit();
///
/// try t.ctx.setVar("xs", &.{"a", "b"});
/// const result = try expand.expandWord(&t.ctx, &segs);
/// ```
///
/// NOTE: Two-phase initialization is required. State.init() and ExpandContext.init()
/// need the arena's allocator, and ExpandContext stores a pointer to state. Since Zig
/// moves structs on return, we can't take these references during construction - the
/// pointers would become invalid. Call setup() after init() when the struct is at its
/// final memory location.
pub const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    state: State,
    ctx: expand.ExpandContext,

    pub fn init() TestContext {
        const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        return .{
            .arena = arena,
            .state = undefined,
            .ctx = undefined,
        };
    }

    /// Must be called after init() - sets up state and ctx with proper pointers.
    pub fn setup(self: *TestContext) void {
        self.state = State.init(self.arena.allocator());
        self.ctx = expand.ExpandContext.init(self.arena.allocator(), &self.state);
    }

    pub fn deinit(self: *TestContext) void {
        self.ctx.deinit();
        self.state.deinit();
        self.arena.deinit();
    }

    /// Helper to parse shell input and return the AST program
    pub fn parseInput(self: *TestContext, input: []const u8) !ast.Program {
        var lex = lexer.Lexer.init(self.arena.allocator(), input);
        const tokens = try lex.tokenize();
        var p = parser.Parser.initWithInput(self.arena.allocator(), tokens, input);
        return try p.parse();
    }

    /// Helper to get the first expanded command from a program (for simple test cases)
    pub fn getFirstExpandedCmd(self: *TestContext, prog: ast.Program) !expansion_types.ExpandedCmd {
        const ast_pipeline = prog.statements[0].kind.command.chains[0].pipeline;
        const expanded_cmds = try expansion.expandPipeline(self.arena.allocator(), &self.ctx, ast_pipeline);
        return expanded_cmds[0];
    }
};

/// Compare two argv slices for equality in tests
pub fn expectArgvEqual(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |exp, i| {
        try std.testing.expectEqualStrings(exp, actual[i]);
    }
}

// =============================================================================
// Module Test Discovery
// =============================================================================

// Include modules with tests that aren't otherwise in the main import graph
test {
    _ = @import("repl/editor/editor.zig");
    _ = @import("repl/editor/history.zig");
}
