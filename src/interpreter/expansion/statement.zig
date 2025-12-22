//! AST expansion: transforms parsed statements into expanded form ready for execution.
//!
//! This module bridges the parser and executor by expanding AST nodes:
//! - Command arguments are expanded (variables, globs, command substitution)
//! - Aliases are resolved
//! - Redirections are evaluated
//! - Control flow statements pass through unchanged (expanded at execution time)

const std = @import("std");
const ast = @import("../../language/ast.zig");
const expansion_types = @import("expanded.zig");
const token_types = @import("../../language/tokens.zig");
const expand = @import("word.zig");
const lexer_mod = @import("../../language/lexer.zig");
const State = @import("../../runtime/state.zig").State;

// =============================================================================
// Type Aliases
// =============================================================================

const Program = ast.Program;
const Stmt = ast.Statement;
const ChainItem = ast.ChainItem;
const Pipeline = ast.Pipeline;
const Command = ast.Command;
const Redirect = ast.Redirect;
const WordPart = token_types.WordPart;
const CaptureMode = ast.CaptureMode;

const ExpandedPipeline = expansion_types.ExpandedPipeline;
const ExpandedCmd = expansion_types.ExpandedCmd;
const ExpandedRedir = expansion_types.ExpandedRedir;
const EnvKV = expansion_types.EnvKV;
const Capture = expansion_types.Capture;

pub const ExpandError = error{
    EmptyCommand,
    ExpansionError,
};

// =============================================================================
// Public API
// =============================================================================

/// Statements pass through unchanged - expansion happens at execution time.
/// This function exists for interface compatibility during the transition.
pub fn expandStatement(_: std.mem.Allocator, _: *expand.ExpandContext, stmt: Stmt) (ExpandError || expand.ExpandError || std.mem.Allocator.Error)!Stmt {
    return stmt;
}

// =============================================================================
// Internal Expansion Functions
// =============================================================================

// Made public for JIT expansion during execution
pub fn expandPipeline(allocator: std.mem.Allocator, ctx: *expand.ExpandContext, pipeline: Pipeline) (ExpandError || expand.ExpandError || std.mem.Allocator.Error)!ExpandedPipeline {
    var cmd_expanded: std.ArrayListUnmanaged(ExpandedCmd) = .empty;

    for (pipeline.commands) |cmd| {
        const expanded_result = try expandCommand(allocator, ctx, cmd);
        try cmd_expanded.append(allocator, expanded_result);
    }

    return ExpandedPipeline{
        .commands = try cmd_expanded.toOwnedSlice(allocator),
    };
}

fn expandCommand(allocator: std.mem.Allocator, ctx: *expand.ExpandContext, cmd: Command) (ExpandError || expand.ExpandError || std.mem.Allocator.Error)!ExpandedCmd {
    var env_list: std.ArrayListUnmanaged(EnvKV) = .empty;

    const words_with_alias = try applyAliasExpansion(allocator, ctx, cmd.words);

    for (cmd.assignments) |assign| {
        const expanded_values = try expand.expandWord(ctx, assign.value);
        const joined = try joinValues(allocator, expanded_values);
        try env_list.append(allocator, .{ .key = assign.key, .value = joined });
    }

    const expanded_argv = try expand.expandWords(ctx, words_with_alias);

    var redir_expanded: std.ArrayListUnmanaged(ExpandedRedir) = .empty;
    for (cmd.redirects) |redir| {
        const redir_result = try expandRedirect(allocator, ctx, redir);
        try redir_expanded.append(allocator, redir_result);
    }

    return ExpandedCmd{
        .argv = expanded_argv,
        .env = try env_list.toOwnedSlice(allocator),
        .redirects = try redir_expanded.toOwnedSlice(allocator),
    };
}

// =============================================================================
// Alias Expansion
// =============================================================================

/// Apply alias expansion to the first word of the command, if any.
/// Expands only once to avoid recursive alias loops.
fn applyAliasExpansion(allocator: std.mem.Allocator, ctx: *expand.ExpandContext, words: []const []const WordPart) ![]const []const WordPart {
    if (words.len == 0) return words;
    if (words[0].len == 0 or words[0][0].quotes != .none) return words;

    const alias_name = words[0][0].text;
    const alias_text = ctx.state.getAlias(alias_name) orelse return words;

    var lex = lexer_mod.Lexer.init(allocator, alias_text);
    const tokens = lex.tokenize() catch return words; // On lex error, leave unchanged

    var alias_words: std.ArrayListUnmanaged([]const WordPart) = .empty;
    defer alias_words.deinit(allocator);

    for (tokens) |tok| {
        if (tok.kind != .word) break;
        try alias_words.append(allocator, tok.kind.word);
    }

    if (alias_words.items.len == 0) return words;

    var combined: std.ArrayListUnmanaged([]const WordPart) = .empty;
    errdefer combined.deinit(allocator);

    try combined.appendSlice(allocator, alias_words.items);
    try combined.appendSlice(allocator, words[1..]);

    return try combined.toOwnedSlice(allocator);
}

// =============================================================================
// Redirect and Helper Functions
// =============================================================================

fn expandRedirect(_: std.mem.Allocator, ctx: *expand.ExpandContext, redirect: Redirect) (ExpandError || expand.ExpandError || std.mem.Allocator.Error)!ExpandedRedir {
    return switch (redirect.kind) {
        .dup => |to_fd| ExpandedRedir.initDup(redirect.from_fd, to_fd),
        .read => |parts| blk: {
            const expanded = try expand.expandWord(ctx, parts);
            const target_str = if (expanded.len > 0) expanded[0] else "";
            break :blk ExpandedRedir.initRead(redirect.from_fd, target_str);
        },
        .write_truncate => |parts| blk: {
            const expanded = try expand.expandWord(ctx, parts);
            const target_str = if (expanded.len > 0) expanded[0] else "";
            break :blk ExpandedRedir.initWriteTruncate(redirect.from_fd, target_str);
        },
        .write_append => |parts| blk: {
            const expanded = try expand.expandWord(ctx, parts);
            const target_str = if (expanded.len > 0) expanded[0] else "";
            break :blk ExpandedRedir.initWriteAppend(redirect.from_fd, target_str);
        },
    };
}

fn joinValues(allocator: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error![]const u8 {
    if (values.len == 0) return "";
    if (values.len == 1) return values[0];

    var total_len: usize = 0;
    for (values) |v| {
        total_len += v.len;
    }
    total_len += values.len - 1;

    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    for (values, 0..) |v, i| {
        @memcpy(result[pos .. pos + v.len], v);
        pos += v.len;
        if (i < values.len - 1) {
            result[pos] = ' ';
            pos += 1;
        }
    }

    return result;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const parser = @import("../../language/parser.zig");

fn expandInput(allocator: std.mem.Allocator, input: []const u8) !Program {
    var lex = lexer_mod.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();
    var p = parser.Parser.init(allocator, tokens);
    return try p.parse();
}

test "simple command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = expand.ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const prog = try expandInput(arena.allocator(), "echo hello world");

    try testing.expectEqual(@as(usize, 1), prog.statements.len);
    // Expand the pipeline at execution time
    const ast_pipeline = prog.statements[0].kind.command.chains[0].pipeline;
    const expanded_pipeline = try expandPipeline(arena.allocator(), &ctx, ast_pipeline);
    const cmd_expanded = expanded_pipeline.commands[0];
    try testing.expectEqual(@as(usize, 3), cmd_expanded.argv.len);
    try testing.expectEqualStrings("echo", cmd_expanded.argv[0]);
    try testing.expectEqualStrings("hello", cmd_expanded.argv[1]);
    try testing.expectEqualStrings("world", cmd_expanded.argv[2]);
}

test "pipeline normalizes |> to |" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try expandInput(arena.allocator(), "cat file |> grep foo");

    const pipeline = prog.statements[0].kind.command.chains[0].pipeline;
    try testing.expectEqual(@as(usize, 2), pipeline.commands.len);
}

test "with variable expansion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = expand.ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const name_values = [_][]const u8{"world"};
    try ctx.setVar("name", &name_values);

    const prog = try expandInput(arena.allocator(), "echo $name");

    // Expand the pipeline at execution time
    const ast_pipeline = prog.statements[0].kind.command.chains[0].pipeline;
    const expanded_pipeline = try expandPipeline(arena.allocator(), &ctx, ast_pipeline);
    const cmd_expanded = expanded_pipeline.commands[0];
    try testing.expectEqual(@as(usize, 2), cmd_expanded.argv.len);
    try testing.expectEqualStrings("echo", cmd_expanded.argv[0]);
    try testing.expectEqualStrings("world", cmd_expanded.argv[1]);
}

test "with env prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = expand.ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const prog = try expandInput(arena.allocator(), "FOO=bar env");

    // Expand the pipeline at execution time
    const ast_pipeline = prog.statements[0].kind.command.chains[0].pipeline;
    const expanded_pipeline = try expandPipeline(arena.allocator(), &ctx, ast_pipeline);
    const cmd_expanded = expanded_pipeline.commands[0];
    try testing.expectEqual(@as(usize, 1), cmd_expanded.env.len);
    try testing.expectEqualStrings("FOO", cmd_expanded.env[0].key);
    try testing.expectEqualStrings("bar", cmd_expanded.env[0].value);
}

test "capture preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try expandInput(arena.allocator(), "whoami => user");

    try testing.expectEqualStrings("user", prog.statements[0].kind.command.capture.?.variable);
    try testing.expectEqual(ast.CaptureMode.string, prog.statements[0].kind.command.capture.?.mode);
}

test "background preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prog = try expandInput(arena.allocator(), "sleep 10 &");

    try testing.expectEqual(true, prog.statements[0].kind.command.background);
}
