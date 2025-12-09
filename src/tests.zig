//! Oshen shell test infrastructure
//!
//! This module contains:
//! - Shared test helpers (TestContext, expectArgvEqual)
//! - Integration tests for the full pipeline
//! - Module test discovery for files not in the main import graph

const std = @import("std");
const ast = @import("language/ast.zig");
const expansion_types = @import("interpreter/expansion/types.zig");
const State = @import("runtime/state.zig").State;
const builtins = @import("runtime/builtins.zig");
const var_builtin = @import("runtime/builtins/var.zig");
const interpreter_mod = @import("interpreter/interpreter.zig");
const expand = @import("interpreter/expansion/expand.zig");
const lexer = @import("language/lexer.zig");
const parser = @import("language/parser.zig");
const expansion = @import("interpreter/expansion/expansion.zig");

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
const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    state: State,
    ctx: expand.ExpandContext,

    fn init() TestContext {
        const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        return .{
            .arena = arena,
            .state = undefined,
            .ctx = undefined,
        };
    }

    /// Must be called after init() - sets up state and ctx with proper pointers.
    fn setup(self: *TestContext) void {
        self.state = State.init(self.arena.allocator());
        self.ctx = expand.ExpandContext.init(self.arena.allocator(), &self.state);
    }

    fn deinit(self: *TestContext) void {
        self.ctx.deinit();
        self.state.deinit();
        self.arena.deinit();
    }

    /// Helper to expand shell input and return the expanded program
    fn expandInput(self: *TestContext, input: []const u8) !expansion_types.ExpandedProgram {
        var lex = lexer.Lexer.init(self.arena.allocator(), input);
        const tokens = try lex.tokenize();
        var p = parser.Parser.initWithInput(self.arena.allocator(), tokens, input);
        const prog = try p.parse();

        var stmt_expanded: std.ArrayListUnmanaged(expansion_types.ExpandedStmt) = .empty;
        for (prog.statements) |stmt| {
            const exp = try expansion.expandStmt(self.arena.allocator(), &self.ctx, stmt);
            try stmt_expanded.append(self.arena.allocator(), exp);
        }
        return expansion_types.ExpandedProgram{ .statements = try stmt_expanded.toOwnedSlice(self.arena.allocator()) };
    }
};

/// Compare two argv slices for equality in tests
fn expectArgvEqual(actual: []const []const u8, expected: []const []const u8) !void {
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

// =============================================================================
// Integration Tests (Full Pipeline: Lexer -> Parser -> Expander)
// =============================================================================

test "integration: simple echo" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("echo hello");

    const expected = [_][]const u8{ "echo", "hello" };
    try expectArgvEqual(prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0].argv, &expected);
}

test "integration: quote escapes" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("echo \"a b\" 'c\"d'");

    const argv = prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0].argv;
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("echo", argv[0]);
    try std.testing.expectEqualStrings("a b", argv[1]);
    try std.testing.expectEqualStrings("c\"d", argv[2]);
}
test "integration: variable list expansion" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const xs_values = [_][]const u8{ "a", "b" };
    try t.ctx.setVar("xs", &xs_values);

    const prog_expanded = try t.expandInput("echo $xs");

    const expected = [_][]const u8{ "echo", "a", "b" };
    try expectArgvEqual(prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0].argv, &expected);
}

test "integration: cartesian prefix" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const xs_values = [_][]const u8{ "a", "b" };
    try t.ctx.setVar("xs", &xs_values);

    const prog_expanded = try t.expandInput("echo pre$xs");

    const expected = [_][]const u8{ "echo", "prea", "preb" };
    try expectArgvEqual(prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0].argv, &expected);
}

test "integration: tilde expansion" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    t.state.home = "/home/jon";

    const prog_expanded = try t.expandInput("cd ~/src");

    const expected = [_][]const u8{ "cd", "/home/jon/src" };
    try expectArgvEqual(prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0].argv, &expected);
}

test "integration: command substitution" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    try t.ctx.setMockCmdsub("whoami", "jon");

    const prog_expanded = try t.expandInput("echo $(whoami)");

    const expected = [_][]const u8{ "echo", "jon" };
    try expectArgvEqual(prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0].argv, &expected);
}

test "integration: glob expansion" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const matches = [_][]const u8{ "src/main.zig", "src/util.zig" };
    try t.ctx.setMockGlob("src/*.zig", &matches);

    const prog_expanded = try t.expandInput("echo src/*.zig");

    const expected = [_][]const u8{ "echo", "src/main.zig", "src/util.zig" };
    try expectArgvEqual(prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0].argv, &expected);
}

test "integration: glob suppressed in quotes" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const matches = [_][]const u8{ "src/main.zig", "src/util.zig" };
    try t.ctx.setMockGlob("src/*.zig", &matches);

    const prog_expanded = try t.expandInput("echo \"src/*.zig\"");

    const expected = [_][]const u8{ "echo", "src/*.zig" };
    try expectArgvEqual(prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0].argv, &expected);
}

test "integration: single quotes disable expansion" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const xs_values = [_][]const u8{ "a", "b" };
    try t.ctx.setVar("xs", &xs_values);

    const prog_expanded = try t.expandInput("echo '$xs'");

    const expected = [_][]const u8{ "echo", "$xs" };
    try expectArgvEqual(prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0].argv, &expected);
}

// =============================================================================
// Config Model Tests (set, export, source builtins)
// =============================================================================

test "config: set builtin sets shell variable" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Create a command plan for: set MYVAR hello
    const cmd_expanded = expansion_types.ExpandedCmd{
        .argv = &[_][]const u8{ "set", "MYVAR", "hello" },
        .env = &.{},
        .redirs = &.{},
    };

    const result = var_builtin.builtin.run(&t.state, cmd_expanded);
    try std.testing.expectEqual(@as(u8, 0), result);

    // Verify the variable was set
    const value = t.state.getVar("MYVAR");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("hello", value.?);
}

test "config: set builtin with multiple values" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // set MYLIST a b c
    const cmd_expanded = expansion_types.ExpandedCmd{
        .argv = &[_][]const u8{ "set", "MYLIST", "a", "b", "c" },
        .env = &.{},
        .redirs = &.{},
    };

    const result = var_builtin.builtin.run(&t.state, cmd_expanded);
    try std.testing.expectEqual(@as(u8, 0), result);

    // First value should be "a"
    const value = t.state.getVar("MYLIST");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("a", value.?);

    // Full list should have all values
    const list = t.state.getVarList("MYLIST");
    try std.testing.expect(list != null);
    try std.testing.expectEqual(@as(usize, 3), list.?.len);
}

test "config: set builtin returns 1 for nonexistent variable" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // set NONEXISTENT (query mode for var that doesn't exist)
    const cmd_expanded = expansion_types.ExpandedCmd{
        .argv = &[_][]const u8{ "set", "NONEXISTENT_VAR_12345" },
        .env = &.{},
        .redirs = &.{},
    };

    const result = var_builtin.builtin.run(&t.state, cmd_expanded);
    try std.testing.expectEqual(@as(u8, 1), result);
}

test "config: source executes file commands" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Create a temporary config file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const config_content = "set SOURCED_VAR sourced_value\n";
    const config_file = try tmp_dir.dir.createFile("test.oshen", .{});
    try config_file.writeAll(config_content);
    config_file.close();

    // Get the full path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try tmp_dir.dir.realpath("test.oshen", &path_buf);

    // Source the file
    const result = try interpreter_mod.executeFile(t.arena.allocator(), &t.state, config_path);
    try std.testing.expectEqual(@as(u8, 0), result);

    // Verify the variable was set
    const value = t.state.getVar("SOURCED_VAR");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("sourced_value", value.?);
}

test "config: source skips comments and empty lines" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Create a config file with comments
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const config_content =
        \\# This is a comment
        \\
        \\set VAR1 value1
        \\# Another comment
        \\set VAR2 value2
        \\
    ;
    const config_file = try tmp_dir.dir.createFile("test2.oshen", .{});
    try config_file.writeAll(config_content);
    config_file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try tmp_dir.dir.realpath("test2.oshen", &path_buf);

    const result = try interpreter_mod.executeFile(t.arena.allocator(), &t.state, config_path);
    try std.testing.expectEqual(@as(u8, 0), result);

    // Both variables should be set
    try std.testing.expectEqualStrings("value1", t.state.getVar("VAR1").?);
    try std.testing.expectEqualStrings("value2", t.state.getVar("VAR2").?);
}

test "config: source nonexistent file returns error" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const result = interpreter_mod.executeFile(t.arena.allocator(), &t.state, "/nonexistent/path/to/file.oshen");
    try std.testing.expectError(error.FileNotFound, result);
}

test "config: variable set via config is expandable" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Simulate config: set MYNAME world
    try t.state.setVar("MYNAME", "world");

    // Now expand a command using that variable
    const prog_expanded = try t.expandInput("echo hello $MYNAME");

    const expected = [_][]const u8{ "echo", "hello", "world" };
    try expectArgvEqual(prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0].argv, &expected);
}

// =============================================================================
// Function Tests
// =============================================================================

test "function: definition creates fun_def plan" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("fun greet\n  echo hello\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const fun_def = prog_expanded.statements[0].kind.fun_def;
    try std.testing.expectEqualStrings("greet", fun_def.name);
    try std.testing.expect(std.mem.indexOf(u8, fun_def.body, "echo hello") != null);
}

test "function: inline definition" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("fun greet echo hello end");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const fun_def = prog_expanded.statements[0].kind.fun_def;
    try std.testing.expectEqualStrings("greet", fun_def.name);
}

test "function: multiple statements after definition" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("fun greet\n  echo hello\nend\necho after");

    try std.testing.expectEqual(@as(usize, 2), prog_expanded.statements.len);
    // First statement is function definition
    try std.testing.expectEqualStrings("greet", prog_expanded.statements[0].kind.fun_def.name);
    // Second statement is command
    const cmd = prog_expanded.statements[1].kind.cmd.chains[0].pipeline.cmds[0];
    const expected = [_][]const u8{ "echo", "after" };
    try expectArgvEqual(cmd.argv, &expected);
}

test "function: body captures multiline content" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const input =
        \\fun multi
        \\  echo line1
        \\  echo line2
        \\  echo line3
        \\end
    ;
    const prog_expanded = try t.expandInput(input);

    const fun_def = prog_expanded.statements[0].kind.fun_def;
    try std.testing.expectEqualStrings("multi", fun_def.name);
    // Body should contain all lines
    try std.testing.expect(std.mem.indexOf(u8, fun_def.body, "echo line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, fun_def.body, "echo line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, fun_def.body, "echo line3") != null);
}

// =============================================================================
// If Statement Tests
// =============================================================================

test "if: simple condition creates if_stmt plan" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("if true\n  echo yes\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const if_stmt = prog_expanded.statements[0].kind.if_stmt;
    try std.testing.expectEqual(@as(usize, 1), if_stmt.branches.len);
    try std.testing.expectEqualStrings("true", if_stmt.branches[0].condition);
    try std.testing.expect(std.mem.indexOf(u8, if_stmt.branches[0].body, "echo yes") != null);
    try std.testing.expectEqual(@as(?[]const u8, null), if_stmt.else_body);
}

test "if: with else branch" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("if false\n  echo no\nelse\n  echo yes\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const if_stmt = prog_expanded.statements[0].kind.if_stmt;
    try std.testing.expectEqual(@as(usize, 1), if_stmt.branches.len);
    try std.testing.expectEqualStrings("false", if_stmt.branches[0].condition);
    try std.testing.expect(std.mem.indexOf(u8, if_stmt.branches[0].body, "echo no") != null);
    try std.testing.expect(if_stmt.else_body != null);
    try std.testing.expect(std.mem.indexOf(u8, if_stmt.else_body.?, "echo yes") != null);
}

test "if: inline syntax" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("if true; echo yes; end");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const if_stmt = prog_expanded.statements[0].kind.if_stmt;
    try std.testing.expectEqual(@as(usize, 1), if_stmt.branches.len);
    try std.testing.expectEqualStrings("true", if_stmt.branches[0].condition);
}

test "if: command after if statement" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("if true\n  echo yes\nend\necho after");

    try std.testing.expectEqual(@as(usize, 2), prog_expanded.statements.len);
    // First statement is if
    _ = prog_expanded.statements[0].kind.if_stmt;
    // Second statement is command
    const cmd = prog_expanded.statements[1].kind.cmd.chains[0].pipeline.cmds[0];
    const expected = [_][]const u8{ "echo", "after" };
    try expectArgvEqual(cmd.argv, &expected);
}

test "if: else if chain" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("if false\n  echo 1\nelse if false\n  echo 2\nelse if true\n  echo 3\nelse\n  echo 4\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const if_stmt = prog_expanded.statements[0].kind.if_stmt;
    // Should have 3 branches: if, else if, else if
    try std.testing.expectEqual(@as(usize, 3), if_stmt.branches.len);
    try std.testing.expectEqualStrings("false", if_stmt.branches[0].condition);
    try std.testing.expectEqualStrings("false", if_stmt.branches[1].condition);
    try std.testing.expectEqualStrings("true", if_stmt.branches[2].condition);
    // Should have else body
    try std.testing.expect(if_stmt.else_body != null);
}

test "if: else if without final else" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("if false\n  echo 1\nelse if true\n  echo 2\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const if_stmt = prog_expanded.statements[0].kind.if_stmt;
    try std.testing.expectEqual(@as(usize, 2), if_stmt.branches.len);
    try std.testing.expectEqual(@as(?[]const u8, null), if_stmt.else_body);
}

// =============================================================================
// Break/Continue Tests
// =============================================================================

test "break: creates break_stmt plan" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("for i in 1 2 3; if true; break; end; end");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    _ = prog_expanded.statements[0].kind.for_stmt;
}

test "continue: creates continue_stmt plan" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("for i in 1 2 3; if true; continue; end; end");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    _ = prog_expanded.statements[0].kind.for_stmt;
}

// =============================================================================
// Capture Tests
// =============================================================================

test "capture: basic string capture" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("echo hello => x");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const cmd_stmt = prog_expanded.statements[0].kind.cmd;
    try std.testing.expect(cmd_stmt.capture != null);
    try std.testing.expectEqual(ast.CaptureMode.string, cmd_stmt.capture.?.mode);
    try std.testing.expectEqualStrings("x", cmd_stmt.capture.?.variable);
}

test "capture: lines capture" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("ls =>@ files");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const cmd_stmt = prog_expanded.statements[0].kind.cmd;
    try std.testing.expect(cmd_stmt.capture != null);
    try std.testing.expectEqual(ast.CaptureMode.lines, cmd_stmt.capture.?.mode);
    try std.testing.expectEqualStrings("files", cmd_stmt.capture.?.variable);
}

// =============================================================================
// For Loop Tests
// =============================================================================

test "for: basic loop" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("for x in a b c; echo $x; end");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const for_stmt = prog_expanded.statements[0].kind.for_stmt;
    try std.testing.expectEqualStrings("x", for_stmt.variable);
    try std.testing.expectEqualStrings("a b c", for_stmt.items_source);
    try std.testing.expect(std.mem.indexOf(u8, for_stmt.body, "echo") != null);
}

test "for: multi-line syntax" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.expandInput("for i in 1 2 3\necho $i\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const for_stmt = prog_expanded.statements[0].kind.for_stmt;
    try std.testing.expectEqualStrings("i", for_stmt.variable);
    try std.testing.expectEqualStrings("1 2 3", for_stmt.items_source);
}

// =============================================================================
// Command Substitution Tests
// =============================================================================

test "cmdsub: basic substitution" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Set up mock for command substitution
    try t.ctx.setMockCmdsub("echo hello", "hello");

    const prog_expanded = try t.expandInput("echo $(echo hello)");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const cmd = prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0];
    // After expansion, argv should be ["echo", "hello"]
    try std.testing.expectEqual(@as(usize, 2), cmd.argv.len);
    try std.testing.expectEqualStrings("echo", cmd.argv[0]);
    try std.testing.expectEqualStrings("hello", cmd.argv[1]);
}

test "cmdsub: multi-line splits into list" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Mock returns multi-line output
    try t.ctx.setMockCmdsub("echo lines", "a\nb\nc");

    const prog_expanded = try t.expandInput("echo $(echo lines)");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const cmd = prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0];
    // After expansion, argv should be ["echo", "a", "b", "c"]
    try std.testing.expectEqual(@as(usize, 4), cmd.argv.len);
    try std.testing.expectEqualStrings("echo", cmd.argv[0]);
    try std.testing.expectEqualStrings("a", cmd.argv[1]);
    try std.testing.expectEqualStrings("b", cmd.argv[2]);
    try std.testing.expectEqualStrings("c", cmd.argv[3]);
}

// =============================================================================
// Pipeline Execution Tests (full execution through interpreter.execute)
// =============================================================================

test "pipeline: variable set then used in same input" {
    // This tests the fix for statement-by-statement execution
    // Previously `set x test; echo $x` would fail because all statements
    // were expanded before any were executed
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Execute: set x hello
    _ = try interpreter_mod.execute(t.arena.allocator(), &t.state, "set x hello");

    // Verify variable is set
    const value = t.state.getVar("x");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("hello", value.?);
}

test "pipeline: multiple statements share state" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Execute multiple set commands in sequence
    _ = try interpreter_mod.execute(t.arena.allocator(), &t.state, "set a 1; set b 2; set c 3");

    // Verify all variables are set
    try std.testing.expectEqualStrings("1", t.state.getVar("a").?);
    try std.testing.expectEqualStrings("2", t.state.getVar("b").?);
    try std.testing.expectEqualStrings("3", t.state.getVar("c").?);
}

test "pipeline: function definition then call" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Define a function
    _ = try interpreter_mod.execute(t.arena.allocator(), &t.state, "fun greet; echo hello; end");

    // Verify function is registered
    const body = t.state.getFunction("greet");
    try std.testing.expect(body != null);
}
