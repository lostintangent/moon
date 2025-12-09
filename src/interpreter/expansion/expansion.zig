const std = @import("std");
const ast = @import("../../language/ast.zig");
const expansion_types = @import("types.zig");
const token_types = @import("../../language/tokens.zig");
const expand = @import("expand.zig");
const State = @import("../../runtime/state.zig").State;

const Program = ast.Program;
const Stmt = ast.Statement;
const ChainItem = ast.ChainItem;
const Pipeline = ast.Pipeline;
const Command = ast.Command;
const RedirAst = ast.RedirAst;
const WordPart = token_types.WordPart;
const CaptureMode = ast.CaptureMode;

const ExpandedProgram = expansion_types.ExpandedProgram;
const ExpandedStmt = expansion_types.ExpandedStmt;
const ExpandedChain = expansion_types.ExpandedChain;
const ExpandedPipeline = expansion_types.ExpandedPipeline;
const ExpandedCmd = expansion_types.ExpandedCmd;
const ExpandedRedir = expansion_types.ExpandedRedir;
const EnvKV = expansion_types.EnvKV;
const Capture = expansion_types.Capture;

pub const ExpandError = error{
    EmptyCommand,
    ExpansionError,
};

pub fn expandStmt(allocator: std.mem.Allocator, ctx: *expand.ExpandContext, stmt: Stmt) (ExpandError || expand.ExpandError || std.mem.Allocator.Error)!ExpandedStmt {
    return switch (stmt.kind) {
        .cmd => |cmd_stmt| blk: {
            var chain_expanded: std.ArrayListUnmanaged(ExpandedChain) = .empty;

            for (cmd_stmt.chains) |chain| {
                const expanded_result = try expandChain(allocator, ctx, chain);
                try chain_expanded.append(allocator, expanded_result);
            }

            var capture_expanded: ?Capture = null;

            if (cmd_stmt.capture) |cap| {
                capture_expanded = .{
                    .mode = cap.mode,
                    .variable = cap.variable,
                };
            }

            break :blk ExpandedStmt{
                .kind = .{ .cmd = expansion_types.ExpandedCmdStmt{
                    .bg = cmd_stmt.bg,
                    .capture = capture_expanded,
                    .chains = try chain_expanded.toOwnedSlice(allocator),
                } },
            };
        },
        .fun_def => |fun_def| ExpandedStmt{
            .kind = .{ .fun_def = expansion_types.ast.FunDef{
                .name = fun_def.name,
                .body = fun_def.body,
            } },
        },
        .if_stmt => |if_stmt| ExpandedStmt{
            .kind = .{ .if_stmt = expansion_types.ast.IfStmt{
                .branches = if_stmt.branches,
                .else_body = if_stmt.else_body,
            } },
        },
        .for_stmt => |for_stmt| ExpandedStmt{
            .kind = .{ .for_stmt = expansion_types.ast.ForStmt{
                .variable = for_stmt.variable,
                .items_source = for_stmt.items_source,
                .body = for_stmt.body,
            } },
        },
        .while_stmt => |while_stmt| ExpandedStmt{
            .kind = .{ .while_stmt = expansion_types.ast.WhileStmt{
                .condition = while_stmt.condition,
                .body = while_stmt.body,
            } },
        },
        .break_stmt => ExpandedStmt{
            .kind = .break_stmt,
        },
        .continue_stmt => ExpandedStmt{
            .kind = .continue_stmt,
        },
    };
}

fn expandChain(allocator: std.mem.Allocator, ctx: *expand.ExpandContext, chain: ChainItem) (ExpandError || expand.ExpandError || std.mem.Allocator.Error)!ExpandedChain {
    const op = normalizeOp(chain.op);
    const pipeline = try expandPipeline(allocator, ctx, chain.pipeline);

    return ExpandedChain{
        .op = op,
        .pipeline = pipeline,
    };
}

fn normalizeOp(op: ?[]const u8) ?[]const u8 {
    if (op) |o| {
        if (std.mem.eql(u8, o, "&&")) return "and";
        if (std.mem.eql(u8, o, "||")) return "or";
        return o;
    }
    return null;
}

fn expandPipeline(allocator: std.mem.Allocator, ctx: *expand.ExpandContext, pipeline: Pipeline) (ExpandError || expand.ExpandError || std.mem.Allocator.Error)!ExpandedPipeline {
    var cmd_expanded: std.ArrayListUnmanaged(ExpandedCmd) = .empty;

    for (pipeline.cmds) |cmd| {
        const expanded_result = try expandCommand(allocator, ctx, cmd);
        try cmd_expanded.append(allocator, expanded_result);
    }

    return ExpandedPipeline{
        .cmds = try cmd_expanded.toOwnedSlice(allocator),
    };
}

fn expandCommand(allocator: std.mem.Allocator, ctx: *expand.ExpandContext, cmd: Command) (ExpandError || expand.ExpandError || std.mem.Allocator.Error)!ExpandedCmd {
    var env_list: std.ArrayListUnmanaged(EnvKV) = .empty;

    for (cmd.assigns) |assign| {
        const expanded_values = try expand.expandWord(ctx, assign.value);
        const joined = try joinValues(allocator, expanded_values);
        try env_list.append(allocator, .{ .key = assign.key, .value = joined });
    }

    const expanded_argv = try expand.expandWords(ctx, cmd.words);

    var redir_expanded: std.ArrayListUnmanaged(ExpandedRedir) = .empty;
    for (cmd.redirs) |redir| {
        const redir_result = try expandRedir(allocator, ctx, redir);
        try redir_expanded.append(allocator, redir_result);
    }

    return ExpandedCmd{
        .argv = expanded_argv,
        .env = try env_list.toOwnedSlice(allocator),
        .redirs = try redir_expanded.toOwnedSlice(allocator),
    };
}

fn expandRedir(_: std.mem.Allocator, ctx: *expand.ExpandContext, redir: RedirAst) (ExpandError || expand.ExpandError || std.mem.Allocator.Error)!ExpandedRedir {
    if (redir.target) |target| {
        const expanded = try expand.expandWord(ctx, target);
        const target_str = if (expanded.len > 0) expanded[0] else "";
        return parseRedirToExpandedRedir(redir.op, target_str);
    }

    return parseRedirToExpandedRedir(redir.op, null);
}

/// Parse redirection operator using switch for O(1) dispatch
fn parseRedirToExpandedRedir(op: []const u8, target: ?[]const u8) ExpandedRedir {
    const path = target orelse "";

    if (op.len == 0) return ExpandedRedir.initWriteTruncate(1, path);

    return switch (op[0]) {
        '<' => ExpandedRedir.initRead(0, path),
        '>' => if (op.len == 1)
            ExpandedRedir.initWriteTruncate(1, path)
        else // ">>"
            ExpandedRedir.initWriteAppend(1, path),
        '2' => blk: {
            if (op.len >= 4 and op[1] == '>' and op[2] == '&' and op[3] == '1') {
                break :blk ExpandedRedir.initDup(2, 1);
            } else if (op.len >= 3 and op[1] == '>' and op[2] == '>') {
                break :blk ExpandedRedir.initWriteAppend(2, path);
            } else {
                break :blk ExpandedRedir.initWriteTruncate(2, path);
            }
        },
        '&' => ExpandedRedir.initWriteTruncate(1, path), // "&>"
        else => ExpandedRedir.initWriteTruncate(1, path),
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
const lexer = @import("../../language/lexer.zig");
const parser = @import("../../language/parser.zig");

fn expandInput(allocator: std.mem.Allocator, ctx: *expand.ExpandContext, input: []const u8) !ExpandedProgram {
    var lex = lexer.Lexer.init(allocator, input);
    const tokens = try lex.tokenize();
    var p = parser.Parser.init(allocator, tokens);
    const prog = try p.parse();

    // Expand each statement (mirrors statement-by-statement execution)
    var stmt_expanded: std.ArrayListUnmanaged(ExpandedStmt) = .empty;
    for (prog.statements) |stmt| {
        const expanded = try expandStmt(allocator, ctx, stmt);
        try stmt_expanded.append(allocator, expanded);
    }
    return ExpandedProgram{ .statements = try stmt_expanded.toOwnedSlice(allocator) };
}

test "simple command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = expand.ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const prog_expanded = try expandInput(arena.allocator(), &ctx, "echo hello world");

    try testing.expectEqual(@as(usize, 1), prog_expanded.statements.len);
    const cmd_expanded = prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0];
    try testing.expectEqual(@as(usize, 3), cmd_expanded.argv.len);
    try testing.expectEqualStrings("echo", cmd_expanded.argv[0]);
    try testing.expectEqualStrings("hello", cmd_expanded.argv[1]);
    try testing.expectEqualStrings("world", cmd_expanded.argv[2]);
}

test "pipeline normalizes |> to |" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = expand.ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const prog_expanded = try expandInput(arena.allocator(), &ctx, "cat file |> grep foo");

    const pipeline_expanded = prog_expanded.statements[0].kind.cmd.chains[0].pipeline;
    try testing.expectEqual(@as(usize, 2), pipeline_expanded.cmds.len);
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

    const prog_expanded = try expandInput(arena.allocator(), &ctx, "echo $name");

    const cmd_expanded = prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0];
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

    const prog_expanded = try expandInput(arena.allocator(), &ctx, "FOO=bar env");

    const cmd_expanded = prog_expanded.statements[0].kind.cmd.chains[0].pipeline.cmds[0];
    try testing.expectEqual(@as(usize, 1), cmd_expanded.env.len);
    try testing.expectEqualStrings("FOO", cmd_expanded.env[0].key);
    try testing.expectEqualStrings("bar", cmd_expanded.env[0].value);
}

test "capture preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = expand.ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const prog_expanded = try expandInput(arena.allocator(), &ctx, "whoami => user");

    try testing.expectEqualStrings("user", prog_expanded.statements[0].kind.cmd.capture.?.variable);
    try testing.expectEqual(ast.CaptureMode.string, prog_expanded.statements[0].kind.cmd.capture.?.mode);
}

test "background preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();
    var ctx = expand.ExpandContext.init(arena.allocator(), &state);
    defer ctx.deinit();

    const prog_expanded = try expandInput(arena.allocator(), &ctx, "sleep 10 &");

    try testing.expectEqual(true, prog_expanded.statements[0].kind.cmd.bg);
}
