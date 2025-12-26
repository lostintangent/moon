//! Statement execution: the main orchestrator for running shell statements
//!
//! This module handles high-level execution flow:
//! - Statement dispatch (commands, functions, control flow)
//! - Control flow statements (if, for, each, while, break, continue)
//! - Background jobs and output capture
//!
//! Pipeline execution and job control are delegated to separate modules.

const std = @import("std");
const expansion_types = @import("../expansion/expanded.zig");
const state_mod = @import("../../runtime/state.zig");
const State = state_mod.State;
const builtins = @import("../../runtime/builtins.zig");
const io = @import("../../terminal/io.zig");
const interpreter_mod = @import("../interpreter.zig");
const expand = @import("../expansion/word.zig");
const lexer_mod = @import("../../language/lexer.zig");
const expansion_statement = @import("../expansion/statement.zig");

// Delegate to specialized modules
const jobs = @import("jobs.zig");
const pipeline = @import("pipeline.zig");
const capture_mod = @import("capture.zig");

const ast = @import("../../language/ast.zig");
const ExpandedCmd = expansion_types.ExpandedCmd;
const posix = jobs.posix;

// =============================================================================
// Re-exports
// =============================================================================

pub const initJobControl = jobs.initJobControl;
pub const initSignals = jobs.initSignals;
pub const continueJobForeground = jobs.continueJobForeground;
pub const continueJobBackground = jobs.continueJobBackground;

// =============================================================================
// Public API
// =============================================================================

/// Execute a parsed program
pub fn execute(allocator: std.mem.Allocator, state: *State, prog: ast.Program, cmd_str: []const u8) !u8 {
    var last_status: u8 = 0;

    for (prog.statements) |stmt| {
        last_status = try executeStatement(allocator, state, stmt, cmd_str);
    }

    return last_status;
}

pub fn executeStatement(allocator: std.mem.Allocator, state: *State, stmt: ast.Statement, cmd_str: []const u8) !u8 {
    return switch (stmt) {
        .command => |cmd_stmt| try executeCmdStatement(allocator, state, cmd_stmt, cmd_str),
        .function => |fun_def| {
            // Register the function in state
            try state.setFunction(fun_def.name, fun_def.body);
            return 0;
        },
        .@"if" => |if_stmt| executeIfStatement(allocator, state, if_stmt),
        .each => |each_stmt| executeEachStatement(allocator, state, each_stmt),
        .@"while" => |while_stmt| executeWhileStatement(allocator, state, while_stmt),
        .@"break" => {
            state.loop_break = true;
            return 0;
        },
        .@"continue" => {
            state.loop_continue = true;
            return 0;
        },
        .@"return" => |opt_status_str| {
            state.fn_return = true;
            if (opt_status_str) |status_str| {
                // Tokenize, expand, and parse the status value at runtime
                var lexer = lexer_mod.Lexer.init(allocator, status_str);
                const tokens = lexer.tokenize() catch {
                    io.printError("return: invalid argument\n", .{});
                    state.setStatus(1);
                    return 1;
                };
                if (tokens.len > 0 and tokens[0].kind == .word) {
                    var expand_ctx = expand.ExpandContext.init(allocator, state);
                    defer expand_ctx.deinit();
                    const expanded = expand.expandWord(&expand_ctx, tokens[0].kind.word) catch {
                        io.printError("return: expansion error\n", .{});
                        state.setStatus(1);
                        return 1;
                    };
                    if (expanded.len > 0) {
                        const parsed = std.fmt.parseInt(u8, expanded[0], 10) catch blk: {
                            io.printError("return: {s}: numeric argument required\n", .{expanded[0]});
                            break :blk 1;
                        };
                        state.setStatus(parsed);
                    }
                }
            }
            // If no argument, status is already the last command's exit status
            return state.status;
        },
        .@"defer" => |cmd_source| {
            // Push the command onto the defer stack (will be executed LIFO on function exit)
            state.pushDefer(cmd_source) catch {
                return 1;
            };
            return 0;
        },
    };
}

// =============================================================================
// Control Flow
// =============================================================================

/// Execute a shell body string, catching errors and returning a status code.
/// Used by control flow statements (if, for) to break the error set cycle.
fn executeBody(allocator: std.mem.Allocator, state: *State, body: []const u8, context: []const u8) u8 {
    return interpreter_mod.execute(allocator, state, body) catch |err| {
        io.printError("{s}: {}\n", .{ context, err });
        return 1;
    };
}

const LoopSignal = enum { break_, continue_, ret };

fn consumeLoopSignal(state: *State) ?LoopSignal {
    if (state.fn_return) return .ret;
    if (state.loop_break) {
        state.loop_break = false;
        return .break_;
    }
    if (state.loop_continue) {
        state.loop_continue = false;
        return .continue_;
    }
    return null;
}

/// Execute an if statement by evaluating condition branches and running appropriate branch
fn executeIfStatement(allocator: std.mem.Allocator, state: *State, if_stmt: expansion_types.ast.IfStatement) u8 {
    // Try each branch in order (first is "if", rest are "else if")
    for (if_stmt.branches) |branch| {
        const cond_status = executeBody(allocator, state, branch.condition, "if: condition error");

        // Check for return during condition evaluation
        if (state.fn_return) return state.status;

        // Exit status 0 means true (success) - execute this branch's body
        if (cond_status == 0) {
            const body_status = executeBody(allocator, state, branch.body, "if: body error");
            // fn_return propagates automatically since we return the status
            return body_status;
        }
    }

    // No branch condition was true - try else body if present
    if (if_stmt.else_body) |else_body| {
        return executeBody(allocator, state, else_body, "if: else error");
    }

    return 0;
}

/// Execute an each loop (for is an alias).
///
/// Sets $item (or custom var) and $index (1-based) on each iteration.
/// Inner loops shadow outer loop variables; values are restored on loop exit.
///
/// OPTIMIZATION: Parses body once upfront, then executes the pre-parsed AST
/// on each iteration. This avoids re-lexing/parsing on every loop iteration.
fn executeEachStatement(allocator: std.mem.Allocator, state: *State, stmt: expansion_types.ast.EachStatement) u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Save previous values of loop variables (for nested loop shadowing).
    // Must dupe because the original slices point into state's memory,
    // which gets freed when we set the loop variable.
    const old_item: ?[]const u8 = if (state.getVar(stmt.variable)) |v|
        arena_alloc.dupe(u8, v) catch null
    else
        null;
    const old_index: ?[]const u8 = if (state.getVar("index")) |v|
        arena_alloc.dupe(u8, v) catch null
    else
        null;

    // Restore loop variables on exit (handles break, continue, return, normal exit)
    defer {
        if (old_item) |v| {
            state.setVar(stmt.variable, v) catch {};
        } else {
            state.unsetVar(stmt.variable);
        }
        if (old_index) |v| {
            state.setVar("index", v) catch {};
        } else {
            state.unsetVar("index");
        }
    }

    // Expand items_source into a list of strings
    const items = expandItems(arena_alloc, state, stmt.items_source) orelse return 1;

    // Parse body once (cached for all iterations)
    const body_ast = interpreter_mod.parseInput(arena_alloc, stmt.body) catch |err| {
        io.printError("each: body parse error: {}\n", .{err});
        return 1;
    };

    // Execute body for each item
    var index_buf: [20]u8 = undefined;
    var last_status: u8 = 0;

    for (items, 0..) |item, i| {
        state.setVar(stmt.variable, item) catch |err| {
            io.printError("each: set var error: {}\n", .{err});
            return 1;
        };

        // Set $index (1-based, matching Oshen's 1-based array indexing)
        const index_str = std.fmt.bufPrint(&index_buf, "{d}", .{i + 1}) catch unreachable;
        state.setVar("index", index_str) catch |err| {
            io.printError("each: set index error: {}\n", .{err});
            return 1;
        };

        last_status = interpreter_mod.executeAst(allocator, state, body_ast) catch |err| {
            io.printError("each: body error: {}\n", .{err});
            return 1;
        };

        if (consumeLoopSignal(state)) |signal| switch (signal) {
            .ret => return state.status,
            .break_ => break,
            .continue_ => continue,
        };
    }

    return last_status;
}

/// Expand items_source into a list of strings. Returns null on error.
fn expandItems(arena_alloc: std.mem.Allocator, state: *State, items_source: []const u8) ?[]const []const u8 {
    var items: std.ArrayListUnmanaged([]const u8) = .empty;

    var lexer = lexer_mod.Lexer.init(arena_alloc, items_source);
    const tokens = lexer.tokenize() catch |err| {
        io.printError("each: items parse error: {}\n", .{err});
        return null;
    };

    var expand_ctx = expand.ExpandContext.init(arena_alloc, state);
    defer expand_ctx.deinit();

    for (tokens) |tok| {
        if (tok.kind == .word) {
            const expanded = expand.expandWord(&expand_ctx, tok.kind.word) catch |err| {
                io.printError("each: expand error: {}\n", .{err});
                return null;
            };
            for (expanded) |word| {
                items.append(arena_alloc, word) catch |err| {
                    io.printError("each: append error: {}\n", .{err});
                    return null;
                };
            }
        }
    }

    return items.items;
}

/// Execute a while loop by repeatedly checking condition and running body.
///
/// OPTIMIZATION: Parses condition and body once upfront, then executes the
/// pre-parsed AST on each iteration. This avoids re-lexing/parsing on every
/// loop iteration - only expansion (variable substitution, globs) happens per-iteration.
fn executeWhileStatement(allocator: std.mem.Allocator, state: *State, while_stmt: expansion_types.ast.WhileStatement) u8 {
    // Parse arena - lives for entire loop duration, holds the cached ASTs
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_alloc = parse_arena.allocator();

    // Parse condition and body once upfront
    const cond_parsed = interpreter_mod.parseInput(parse_alloc, while_stmt.condition) catch |err| {
        io.printError("while: condition parse error: {}\n", .{err});
        return 1;
    };
    const body_parsed = interpreter_mod.parseInput(parse_alloc, while_stmt.body) catch |err| {
        io.printError("while: body parse error: {}\n", .{err});
        return 1;
    };

    var last_status: u8 = 0;

    while (true) {
        // Execute pre-parsed condition (expansion happens inside executeAst)
        const cond_status = interpreter_mod.executeAst(allocator, state, cond_parsed) catch |err| {
            io.printError("while: condition error: {}\n", .{err});
            return 1;
        };

        // Check for return during condition evaluation
        if (state.fn_return) return state.status;

        // Exit status 0 means true (continue), non-zero means false (stop)
        if (cond_status != 0) break;

        // Execute pre-parsed body
        last_status = interpreter_mod.executeAst(allocator, state, body_parsed) catch |err| {
            io.printError("while: body error: {}\n", .{err});
            return 1;
        };

        if (consumeLoopSignal(state)) |signal| switch (signal) {
            .ret => return state.status,
            .break_ => break,
            .continue_ => continue,
        };
    }

    return last_status;
}

// =============================================================================
// Command Execution
// =============================================================================

fn executeCmdStatement(allocator: std.mem.Allocator, state: *State, stmt: expansion_types.ast.CommandStatement, cmd_str: []const u8) !u8 {
    // For background jobs, we run the pipeline in a process group
    if (stmt.background) {
        return executeBackgroundJob(allocator, state, stmt, cmd_str);
    }

    // Handle capture: redirect stdout to a pipe and read the output
    if (stmt.capture) |capture| {
        return executeCmdWithCapture(allocator, state, stmt, capture);
    }

    // Foreground execution
    var last_status: u8 = 0;
    var should_continue = true;

    for (stmt.chains) |chain| {
        // Check conditional logic using explicit operator enum
        switch (chain.op) {
            .none => {},
            .@"and" => if (last_status != 0) {
                should_continue = false;
            },
            .@"or" => if (last_status == 0) {
                should_continue = false;
            },
        }

        if (!should_continue) {
            should_continue = true; // Reset for next chain
            continue;
        }

        // Expand pipeline with current state/cwd
        const expanded_cmds = try expandPipeline(allocator, state, chain.pipeline);
        defer freeCommands(allocator, expanded_cmds);

        last_status = try pipeline.executePipelineForeground(allocator, state, expanded_cmds, &tryRunFunction);
    }

    state.setStatus(last_status);
    return last_status;
}

/// Free memory allocated for expanded commands
fn freeCommands(allocator: std.mem.Allocator, cmds: []const ExpandedCmd) void {
    for (cmds) |cmd| {
        allocator.free(cmd.argv);
        allocator.free(cmd.env);
        allocator.free(cmd.redirects);
    }
    allocator.free(cmds);
}

/// Expand a pipeline with current state
fn expandPipeline(allocator: std.mem.Allocator, state: *State, ast_pipeline: expansion_types.ast.Pipeline) ![]const ExpandedCmd {
    var ctx = expand.ExpandContext.init(allocator, state);
    defer ctx.deinit();
    return expansion_statement.expandPipeline(allocator, &ctx, ast_pipeline);
}

/// Expand a pipeline in a child process context (exits on error instead of returning)
fn expandPipelineInChild(allocator: std.mem.Allocator, state: *State, ast_pipeline: expansion_types.ast.Pipeline) []const ExpandedCmd {
    var ctx = expand.ExpandContext.init(allocator, state);
    defer ctx.deinit();
    return expansion_statement.expandPipeline(allocator, &ctx, ast_pipeline) catch {
        std.posix.exit(1);
    };
}

/// Execute a command statement with output capture (=> or =>@)
fn executeCmdWithCapture(allocator: std.mem.Allocator, state: *State, stmt: expansion_types.ast.CommandStatement, capture: expansion_types.Capture) !u8 {
    const result = switch (try capture_mod.forkWithPipe()) {
        .child => {
            // In child: execute the command chains
            var last_status: u8 = 0;
            for (stmt.chains) |chain| {
                // Expand pipeline (exits on error)
                const expanded_cmds = expandPipelineInChild(allocator, state, chain.pipeline);

                // For single commands, try builtin first, then external
                if (expanded_cmds.len == 1) {
                    const cmd = expanded_cmds[0];
                    if (cmd.argv.len > 0) {
                        if (builtins.tryRun(state, cmd)) |status| {
                            last_status = status;
                            continue;
                        }
                    }
                }
                // External command or pipeline
                last_status = pipeline.executePipelineInChild(allocator, state, expanded_cmds, &tryRunFunction) catch 1;
            }
            std.posix.exit(last_status);
        },
        .parent => |handle| try handle.readAndWait(allocator),
    };
    defer allocator.free(result.output);

    switch (capture.mode) {
        .string => {
            // Store as single string
            try state.setVar(capture.variable, result.output);
        },
        .lines => {
            // Store as list of lines
            var lines: std.ArrayListUnmanaged([]const u8) = .empty;
            defer lines.deinit(allocator);

            var iter = std.mem.splitScalar(u8, result.output, '\n');
            while (iter.next()) |line| {
                const line_copy = try allocator.dupe(u8, line);
                try lines.append(allocator, line_copy);
            }

            try state.setVarList(capture.variable, lines.items);
        },
    }

    state.setStatus(result.status);
    return result.status;
}

fn executeBackgroundJob(allocator: std.mem.Allocator, state: *State, stmt: expansion_types.ast.CommandStatement, cmd_str: []const u8) !u8 {
    // Fork a child to be the process group leader
    const pid = try std.posix.fork();

    if (pid == 0) {
        // Child: create new process group with self as leader
        _ = posix.setpgid(0, 0);

        // Reset signal handlers to default in child
        jobs.resetSignalsToDefault();

        // Execute the statement chains
        var last_status: u8 = 0;
        for (stmt.chains) |chain| {
            // Expand pipeline (exits on error)
            const expanded_cmds = expandPipelineInChild(allocator, state, chain.pipeline);

            last_status = pipeline.executePipelineInChild(allocator, state, expanded_cmds, &tryRunFunction) catch 1;
        }
        std.posix.exit(last_status);
    }

    // Parent: set process group (race with child doing same)
    _ = posix.setpgid(pid, pid);

    // Add to job table
    const pids = try allocator.alloc(std.posix.pid_t, 1);
    errdefer allocator.free(pids);
    pids[0] = pid;
    const job_id = state.jobs.add(pid, pids, cmd_str, .running) catch {
        io.printStdout("[bg] {d}\n", .{pid});
        state.setStatus(0);
        return 0;
    };

    io.printStdout("[{d}] {d}\n", .{ job_id, pid });
    state.setStatus(0);
    return 0;
}

// =============================================================================
// Functions
// =============================================================================

/// Saved argv state for restoration after function call.
/// Deep copies values using state's allocator to outlive ephemeral arenas.
const SavedArgv = struct {
    values: ?[]const []const u8,
    allocator: std.mem.Allocator,

    fn save(state: *State) SavedArgv {
        const allocator = state.allocator;
        const old = state.getVarList("argv") orelse return .{ .values = null, .allocator = allocator };
        return .{
            .values = deepCopy(allocator, old) catch null,
            .allocator = allocator,
        };
    }

    fn restore(self: SavedArgv, state: *State) void {
        defer self.deinit();
        if (self.values) |v| state.setVarList("argv", v) catch {} else state.unsetVar("argv");
    }

    fn deinit(self: SavedArgv) void {
        const values = self.values orelse return;
        for (values) |v| self.allocator.free(v);
        self.allocator.free(values);
    }

    fn deepCopy(allocator: std.mem.Allocator, source: []const []const u8) ![]const []const u8 {
        const copy = try allocator.alloc([]const u8, source.len);
        var copied: usize = 0;
        errdefer {
            for (copy[0..copied]) |s| allocator.free(s);
            allocator.free(copy);
        }
        for (source) |s| {
            copy[copied] = try allocator.dupe(u8, s);
            copied += 1;
        }
        return copy;
    }
};

/// Execute deferred commands from a given index in LIFO order.
/// This allows nested functions to only run their own defers.
fn runDeferredCommandsFromIndex(allocator: std.mem.Allocator, state: *State, from_index: usize) void {
    // Pop and execute in reverse order (LIFO), but only commands added after from_index
    while (state.deferred.items.len > from_index) {
        const cmd = state.popDeferred().?;
        defer state.allocator.free(cmd);
        _ = interpreter_mod.execute(allocator, state, cmd) catch {};
    }
}

fn runFunctionWithArgs(allocator: std.mem.Allocator, state: *State, cmd: ExpandedCmd) ?u8 {
    if (cmd.argv.len == 0) return null;

    const name = cmd.argv[0];
    const func = state.getFunction(name) orelse return null;

    // Save current $argv (deep copy to survive setVarList freeing the original)
    const saved_argv = SavedArgv.save(state);

    // Remember how many deferred commands exist before this function
    const defer_count_before = state.deferred.items.len;

    // Guaranteed cleanup on all exit paths
    defer saved_argv.restore(state);
    defer runDeferredCommandsFromIndex(allocator, state, defer_count_before);

    // Set $argv to function arguments (skip function name)
    state.setVarList("argv", if (cmd.argv.len > 1) cmd.argv[1..] else &.{}) catch {};

    // Get cached parse or parse on first call, then execute
    const parsed = func.getParsed() catch |err| {
        io.printError("function {s}: {}\n", .{ name, err });
        state.fn_return = false;
        return 1;
    };

    const status = interpreter_mod.executeAst(allocator, state, parsed) catch |err| {
        io.printError("function {s}: {}\n", .{ name, err });
        state.fn_return = false;
        return 1;
    };

    if (state.fn_return) {
        state.fn_return = false;
        return state.status;
    }
    return status;
}

/// Try to execute a user-defined function.
/// Returns the exit status if it was a function, null otherwise.
/// Order: builtins > functions > external commands
///
/// Note: This function catches errors internally and returns a status code
/// to break the error set cycle (exec → pipeline → exec).
fn tryRunFunction(allocator: std.mem.Allocator, state: *State, cmd: ExpandedCmd) ?u8 {
    return runFunctionWithArgs(allocator, state, cmd);
}
