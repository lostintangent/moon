//! Oshen shell test infrastructure
//!
//! This module contains:
//! - Shared test helpers (TestContext, expectArgvEqual)
//! - Integration tests for the full pipeline
//! - Module test discovery for files not in the main import graph

const std = @import("std");
const ast = @import("language/ast.zig");
const expansion_types = @import("interpreter/expansion/expanded.zig");
const State = @import("runtime/state.zig").State;
const builtins = @import("runtime/builtins.zig");
const var_builtin = @import("runtime/builtins/var.zig");
const interpreter_mod = @import("interpreter/interpreter.zig");
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

    /// Helper to parse shell input and return the AST program
    fn parseInput(self: *TestContext, input: []const u8) !ast.Program {
        var lex = lexer.Lexer.init(self.arena.allocator(), input);
        const tokens = try lex.tokenize();
        var p = parser.Parser.initWithInput(self.arena.allocator(), tokens, input);
        return try p.parse();
    }

    /// Helper to get the first expanded command from a program (for simple test cases)
    fn getFirstExpandedCmd(self: *TestContext, prog: ast.Program) !expansion_types.ExpandedCmd {
        const ast_pipeline = prog.statements[0].kind.command.chains[0].pipeline;
        const expanded_cmds = try expansion.expandPipeline(self.arena.allocator(), &self.ctx, ast_pipeline);
        return expanded_cmds[0];
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

    const prog_expanded = try t.parseInput("echo hello");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    const expected = [_][]const u8{ "echo", "hello" };
    try expectArgvEqual(cmd.argv, &expected);
}

test "integration: quote escapes" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("echo \"a b\" 'c\"d'");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    try std.testing.expectEqual(@as(usize, 3), cmd.argv.len);
    try std.testing.expectEqualStrings("echo", cmd.argv[0]);
    try std.testing.expectEqualStrings("a b", cmd.argv[1]);
    try std.testing.expectEqualStrings("c\"d", cmd.argv[2]);
}
test "integration: variable list expansion" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const xs_values = [_][]const u8{ "a", "b" };
    try t.ctx.setVar("xs", &xs_values);

    const prog_expanded = try t.parseInput("echo $xs");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    const expected = [_][]const u8{ "echo", "a", "b" };
    try expectArgvEqual(cmd.argv, &expected);
}

test "integration: cartesian prefix" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const xs_values = [_][]const u8{ "a", "b" };
    try t.ctx.setVar("xs", &xs_values);

    const prog_expanded = try t.parseInput("echo pre$xs");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    const expected = [_][]const u8{ "echo", "prea", "preb" };
    try expectArgvEqual(cmd.argv, &expected);
}

test "integration: tilde expansion" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    t.state.home = "/home/jon";

    const prog_expanded = try t.parseInput("cd ~/src");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    const expected = [_][]const u8{ "cd", "/home/jon/src" };
    try expectArgvEqual(cmd.argv, &expected);
}

test "integration: command substitution" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    try t.ctx.setMockCmdsub("whoami", "jon");

    const prog_expanded = try t.parseInput("echo $(whoami)");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    const expected = [_][]const u8{ "echo", "jon" };
    try expectArgvEqual(cmd.argv, &expected);
}

test "integration: glob expansion" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const matches = [_][]const u8{ "src/main.zig", "src/util.zig" };
    try t.ctx.setMockGlob("src/*.zig", &matches);

    const prog_expanded = try t.parseInput("echo src/*.zig");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    const expected = [_][]const u8{ "echo", "src/main.zig", "src/util.zig" };
    try expectArgvEqual(cmd.argv, &expected);
}

test "integration: glob suppressed in quotes" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const matches = [_][]const u8{ "src/main.zig", "src/util.zig" };
    try t.ctx.setMockGlob("src/*.zig", &matches);

    const prog_expanded = try t.parseInput("echo \"src/*.zig\"");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    const expected = [_][]const u8{ "echo", "src/*.zig" };
    try expectArgvEqual(cmd.argv, &expected);
}

test "integration: single quotes disable expansion" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const xs_values = [_][]const u8{ "a", "b" };
    try t.ctx.setVar("xs", &xs_values);

    const prog_expanded = try t.parseInput("echo '$xs'");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    const expected = [_][]const u8{ "echo", "$xs" };
    try expectArgvEqual(cmd.argv, &expected);
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
        .redirects = &.{},
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
        .redirects = &.{},
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
        .redirects = &.{},
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
    const prog_expanded = try t.parseInput("echo hello $MYNAME");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    const expected = [_][]const u8{ "echo", "hello", "world" };
    try expectArgvEqual(cmd.argv, &expected);
}

// =============================================================================
// Function Tests
// =============================================================================

test "function: definition creates function plan" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("fun greet\n  echo hello\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const fun_def = prog_expanded.statements[0].kind.function;
    try std.testing.expectEqualStrings("greet", fun_def.name);
    try std.testing.expect(std.mem.indexOf(u8, fun_def.body, "echo hello") != null);
}

test "function: inline definition" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("fun greet echo hello end");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const fun_def = prog_expanded.statements[0].kind.function;
    try std.testing.expectEqualStrings("greet", fun_def.name);
}

test "function: multiple statements after definition" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("fun greet\n  echo hello\nend\necho after");

    try std.testing.expectEqual(@as(usize, 2), prog_expanded.statements.len);
    // First statement is function definition
    try std.testing.expectEqualStrings("greet", prog_expanded.statements[0].kind.function.name);
    // Second statement is command - need to expand it
    const ast_pipeline = prog_expanded.statements[1].kind.command.chains[0].pipeline;
    const expanded_cmds = try expansion.expandPipeline(t.arena.allocator(), &t.ctx, ast_pipeline);
    const cmd = expanded_cmds[0];
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
    const prog_expanded = try t.parseInput(input);

    const fun_def = prog_expanded.statements[0].kind.function;
    try std.testing.expectEqualStrings("multi", fun_def.name);
    // Body should contain all lines
    try std.testing.expect(std.mem.indexOf(u8, fun_def.body, "echo line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, fun_def.body, "echo line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, fun_def.body, "echo line3") != null);
}

// =============================================================================
// If Statement Tests
// =============================================================================

test "if: simple condition creates if plan" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("if true\n  echo yes\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const if_stmt = prog_expanded.statements[0].kind.@"if";
    try std.testing.expectEqual(@as(usize, 1), if_stmt.branches.len);
    try std.testing.expectEqualStrings("true", if_stmt.branches[0].condition);
    try std.testing.expect(std.mem.indexOf(u8, if_stmt.branches[0].body, "echo yes") != null);
    try std.testing.expectEqual(@as(?[]const u8, null), if_stmt.else_body);
}

test "if: with else branch" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("if false\n  echo no\nelse\n  echo yes\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const if_stmt = prog_expanded.statements[0].kind.@"if";
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

    const prog_expanded = try t.parseInput("if true; echo yes; end");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const if_stmt = prog_expanded.statements[0].kind.@"if";
    try std.testing.expectEqual(@as(usize, 1), if_stmt.branches.len);
    try std.testing.expectEqualStrings("true", if_stmt.branches[0].condition);
}

test "if: command after if statement" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("if true\n  echo yes\nend\necho after");

    try std.testing.expectEqual(@as(usize, 2), prog_expanded.statements.len);
    // First statement is if
    _ = prog_expanded.statements[0].kind.@"if";
    // Second statement is command - need to expand it
    const ast_pipeline = prog_expanded.statements[1].kind.command.chains[0].pipeline;
    const expanded_cmds = try expansion.expandPipeline(t.arena.allocator(), &t.ctx, ast_pipeline);
    const cmd = expanded_cmds[0];
    const expected = [_][]const u8{ "echo", "after" };
    try expectArgvEqual(cmd.argv, &expected);
}

test "if: else if chain" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("if false\n  echo 1\nelse if false\n  echo 2\nelse if true\n  echo 3\nelse\n  echo 4\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const if_stmt = prog_expanded.statements[0].kind.@"if";
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

    const prog_expanded = try t.parseInput("if false\n  echo 1\nelse if true\n  echo 2\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const if_stmt = prog_expanded.statements[0].kind.@"if";
    try std.testing.expectEqual(@as(usize, 2), if_stmt.branches.len);
    try std.testing.expectEqual(@as(?[]const u8, null), if_stmt.else_body);
}

// =============================================================================
// Break/Continue Tests
// =============================================================================

test "break: creates break plan" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("for i in 1 2 3; if true; break; end; end");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    _ = prog_expanded.statements[0].kind.@"for";
}

test "continue: creates continue plan" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("for i in 1 2 3; if true; continue; end; end");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    _ = prog_expanded.statements[0].kind.@"for";
}

// =============================================================================
// Capture Tests
// =============================================================================

test "capture: basic string capture" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("echo hello => x");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const cmd_stmt = prog_expanded.statements[0].kind.command;
    try std.testing.expect(cmd_stmt.capture != null);
    try std.testing.expectEqual(ast.CaptureMode.string, cmd_stmt.capture.?.mode);
    try std.testing.expectEqualStrings("x", cmd_stmt.capture.?.variable);
}

test "capture: lines capture" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("ls =>@ files");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const cmd_stmt = prog_expanded.statements[0].kind.command;
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

    const prog_expanded = try t.parseInput("for x in a b c; echo $x; end");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const for_stmt = prog_expanded.statements[0].kind.@"for";
    try std.testing.expectEqualStrings("x", for_stmt.variable);
    try std.testing.expectEqualStrings("a b c", for_stmt.items_source);
    try std.testing.expect(std.mem.indexOf(u8, for_stmt.body, "echo") != null);
}

test "for: multi-line syntax" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const prog_expanded = try t.parseInput("for i in 1 2 3\necho $i\nend");

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const for_stmt = prog_expanded.statements[0].kind.@"for";
    try std.testing.expectEqualStrings("i", for_stmt.variable);
    try std.testing.expectEqualStrings("1 2 3", for_stmt.items_source);
}

// =============================================================================
// Command Substitution Tests
// =============================================================================

test "commandsub: basic substitution" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Set up mock for command substitution
    try t.ctx.setMockCmdsub("echo hello", "hello");

    const prog_expanded = try t.parseInput("echo $(echo hello)");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    // After expansion, argv should be ["echo", "hello"]
    try std.testing.expectEqual(@as(usize, 2), cmd.argv.len);
    try std.testing.expectEqualStrings("echo", cmd.argv[0]);
    try std.testing.expectEqualStrings("hello", cmd.argv[1]);
}

test "commandsub: multi-line splits into list" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    // Mock returns multi-line output
    try t.ctx.setMockCmdsub("echo lines", "a\nb\nc");

    const prog_expanded = try t.parseInput("echo $(echo lines)");
    const cmd = try t.getFirstExpandedCmd(prog_expanded);

    try std.testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
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

// =============================================================================
// Return Statement Tests
// =============================================================================

test "return: function returns specified exit code" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const status = try interpreter_mod.execute(t.arena.allocator(), &t.state, "fun myfunc; return 42; end; myfunc");
    try std.testing.expectEqual(@as(u8, 42), status);
}

test "return: zero exit code" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const status = try interpreter_mod.execute(t.arena.allocator(), &t.state, "fun check; return 0; end; check");
    try std.testing.expectEqual(@as(u8, 0), status);
}

test "return: in else if branch" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const input =
        \\fun check
        \\  if test a = b
        \\    return 1
        \\  else if test b = b
        \\    return 2
        \\  else
        \\    return 3
        \\  end
        \\end
        \\check
    ;

    const status = try interpreter_mod.execute(t.arena.allocator(), &t.state, input);
    try std.testing.expectEqual(@as(u8, 2), status);
}

// =============================================================================
// Environment Variable Tests
// =============================================================================

test "env: unset removes environment variables" {
    var t = TestContext.init();
    t.setup();
    defer t.deinit();

    const env = @import("runtime/env.zig");
    try env.set(t.arena.allocator(), "TEST_UNSET_VAR", "testvalue");

    const before = env.get("TEST_UNSET_VAR");
    try std.testing.expect(before != null);

    try env.unset(t.arena.allocator(), "TEST_UNSET_VAR");

    const after = env.get("TEST_UNSET_VAR");
    try std.testing.expectEqual(@as(?[]const u8, null), after);
}

// =============================================================================
// Directory Navigation Tests
// =============================================================================

test "cd: dash returns to previous directory" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), state.prev_cwd);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_dir = try std.posix.getcwd(&buf);

    try state.chdir("/tmp");

    try std.testing.expect(state.prev_cwd != null);
    try std.testing.expect(std.mem.indexOf(u8, state.prev_cwd.?, original_dir) != null or
        std.mem.indexOf(u8, original_dir, state.prev_cwd.?) != null);

    try state.chdir(original_dir);

    try std.testing.expect(state.prev_cwd != null);
    try std.testing.expect(std.mem.indexOf(u8, state.prev_cwd.?, "tmp") != null);
}
