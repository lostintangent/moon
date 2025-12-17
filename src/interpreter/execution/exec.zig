//! Statement execution: the main orchestrator for running shell statements
//!
//! This module handles high-level execution flow:
//! - Statement dispatch (commands, functions, control flow)
//! - Control flow statements (if, for, while, break, continue)
//! - Background jobs and output capture
//!
//! Pipeline execution and job control are delegated to separate modules.

const std = @import("std");
const expansion_types = @import("../expansion/types.zig");
const state_mod = @import("../../runtime/state.zig");
const State = state_mod.State;
const builtins = @import("../../runtime/builtins.zig");
const io = @import("../../terminal/io.zig");
const interpreter_mod = @import("../interpreter.zig");
const expand = @import("../expansion/expand.zig");
const lexer_mod = @import("../../language/lexer.zig");

// Delegate to specialized modules
const jobs = @import("jobs.zig");
const pipeline = @import("pipeline.zig");
const capture_mod = @import("capture.zig");

const ExpandedCmd = expansion_types.ExpandedCmd;
const ExpandedProgram = expansion_types.ExpandedProgram;
const ExpandedStmt = expansion_types.ExpandedStmt;
const ExpandedPipeline = expansion_types.ExpandedPipeline;
const c = jobs.c;

// Re-export job control functions for external use
pub const initJobControl = jobs.initJobControl;
pub const initSignals = jobs.initSignals;
pub const continueJobForeground = jobs.continueJobForeground;
pub const continueJobBackground = jobs.continueJobBackground;

/// Execute a command plan
pub fn execute(allocator: std.mem.Allocator, state: *State, prog: ExpandedProgram, cmd_str: []const u8) !u8 {
    var last_status: u8 = 0;

    for (prog.statements) |stmt| {
        last_status = try executeStatement(allocator, state, stmt, cmd_str);
    }

    return last_status;
}

pub fn executeStatement(allocator: std.mem.Allocator, state: *State, stmt: ExpandedStmt, cmd_str: []const u8) !u8 {
    return switch (stmt.kind) {
        .cmd => |cmd_stmt| try executeCmdStatement(allocator, state, cmd_stmt, cmd_str),
        .fun_def => |fun_def| {
            // Register the function in state
            try state.setFunction(fun_def.name, fun_def.body);
            return 0;
        },
        .if_stmt => |if_stmt| executeIfStatement(allocator, state, if_stmt),
        .for_stmt => |for_stmt| executeForStatement(allocator, state, for_stmt),
        .while_stmt => |while_stmt| executeWhileStatement(allocator, state, while_stmt),
        .break_stmt => {
            state.loop_break = true;
            return 0;
        },
        .continue_stmt => {
            state.loop_continue = true;
            return 0;
        },
        .return_stmt => |opt_status_str| {
            state.fn_return = true;
            if (opt_status_str) |status_str| {
                // Parse the expanded string as u8 and set as status
                const parsed = std.fmt.parseInt(u8, status_str, 10) catch blk: {
                    io.printError("return: {s}: numeric argument required\n", .{status_str});
                    break :blk 1;
                };
                state.setStatus(parsed);
            }
            // If no argument, status is already the last command's exit status
            return state.status;
        },
    };
}

/// Execute a shell body string, catching errors and returning a status code.
/// Used by control flow statements (if, for) to break the error set cycle.
fn executeBody(allocator: std.mem.Allocator, state: *State, body: []const u8, context: []const u8) u8 {
    return interpreter_mod.execute(allocator, state, body) catch |err| {
        io.printError("{s}: {}\n", .{ context, err });
        return 1;
    };
}

/// Execute an if statement by evaluating condition branches and running appropriate branch
fn executeIfStatement(allocator: std.mem.Allocator, state: *State, if_stmt: expansion_types.ast.IfStmt) u8 {
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

/// Execute a for loop by iterating over items and running body for each.
///
/// OPTIMIZATION: Parses body once upfront, then executes the pre-parsed AST
/// on each iteration. This avoids re-lexing/parsing on every loop iteration.
fn executeForStatement(allocator: std.mem.Allocator, state: *State, for_stmt: expansion_types.ast.ForStmt) u8 {
    // Arena for items expansion and body AST caching
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Parse items_source as words and expand them
    var items: std.ArrayListUnmanaged([]const u8) = .empty;

    var lexer = lexer_mod.Lexer.init(arena_alloc, for_stmt.items_source);
    const tokens = lexer.tokenize() catch |err| {
        io.printError("for: items parse error: {}\n", .{err});
        return 1;
    };

    var expand_ctx = expand.ExpandContext.init(arena_alloc, state);
    defer expand_ctx.deinit();

    for (tokens) |tok| {
        if (tok.parts()) |segs| {
            const expanded = expand.expandWord(&expand_ctx, segs) catch |err| {
                io.printError("for: expand error: {}\n", .{err});
                return 1;
            };
            for (expanded) |word| {
                items.append(arena_alloc, word) catch |err| {
                    io.printError("for: item append error: {}\n", .{err});
                    return 1;
                };
            }
        }
    }

    // Parse body once upfront (optimization: avoid re-parsing on each iteration)
    const body_parsed = interpreter_mod.parseInput(arena_alloc, for_stmt.body) catch |err| {
        io.printError("for: body parse error: {}\n", .{err});
        return 1;
    };

    // Execute body for each item
    var last_status: u8 = 0;
    for (items.items) |item| {
        state.setVar(for_stmt.variable, item) catch |err| {
            io.printError("for: set var error: {}\n", .{err});
            return 1;
        };

        // Execute pre-parsed body (expansion happens inside executeAst)
        last_status = interpreter_mod.executeAst(allocator, state, body_parsed) catch |err| {
            io.printError("for: body error: {}\n", .{err});
            return 1;
        };

        // Check for return - propagate up without resetting
        if (state.fn_return) {
            return state.status;
        }

        // Check for break
        if (state.loop_break) {
            state.loop_break = false;
            break;
        }

        // Check for continue - just reset the flag and continue to next iteration
        if (state.loop_continue) {
            state.loop_continue = false;
        }
    }

    return last_status;
}

/// Execute a while loop by repeatedly checking condition and running body.
///
/// OPTIMIZATION: Parses condition and body once upfront, then executes the
/// pre-parsed AST on each iteration. This avoids re-lexing/parsing on every
/// loop iteration - only expansion (variable substitution, globs) happens per-iteration.
fn executeWhileStatement(allocator: std.mem.Allocator, state: *State, while_stmt: expansion_types.ast.WhileStmt) u8 {
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

        // Check for return - propagate up without resetting
        if (state.fn_return) {
            return state.status;
        }

        // Check for break
        if (state.loop_break) {
            state.loop_break = false;
            break;
        }

        // Check for continue - just reset the flag and continue to next iteration
        if (state.loop_continue) {
            state.loop_continue = false;
        }
    }

    return last_status;
}

fn executeCmdStatement(allocator: std.mem.Allocator, state: *State, stmt: expansion_types.ExpandedCmdStmt, cmd_str: []const u8) !u8 {
    // For background jobs, we run the pipeline in a process group
    if (stmt.bg) {
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
        // Check conditional logic using StaticStringMap-compatible checks
        if (chain.op) |op| {
            const is_and = std.mem.eql(u8, op, "and") or std.mem.eql(u8, op, "&&");
            const is_or = std.mem.eql(u8, op, "or") or std.mem.eql(u8, op, "||");

            if (is_and and last_status != 0) {
                should_continue = false;
            } else if (is_or and last_status == 0) {
                should_continue = false;
            }
        }

        if (!should_continue) {
            should_continue = true; // Reset for next chain
            continue;
        }

        last_status = try pipeline.executePipelineForeground(allocator, state, chain.pipeline, &tryRunFunction);
    }

    state.setStatus(last_status);
    return last_status;
}

/// Execute a command statement with output capture (=> or =>@)
fn executeCmdWithCapture(allocator: std.mem.Allocator, state: *State, stmt: expansion_types.ExpandedCmdStmt, capture: expansion_types.Capture) !u8 {
    const result = switch (try capture_mod.forkWithPipe()) {
        .child => {
            // In child: execute the command chains
            var last_status: u8 = 0;
            for (stmt.chains) |chain| {
                // For single commands, try builtin first, then external
                if (chain.pipeline.cmds.len == 1) {
                    const cmd = chain.pipeline.cmds[0];
                    if (cmd.argv.len > 0) {
                        if (builtins.tryRun(state, cmd)) |status| {
                            last_status = status;
                            continue;
                        }
                    }
                }
                // External command or pipeline
                last_status = pipeline.executePipelineInChild(allocator, chain.pipeline) catch 1;
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

fn executeBackgroundJob(allocator: std.mem.Allocator, state: *State, stmt: expansion_types.ExpandedCmdStmt, cmd_str: []const u8) !u8 {
    // Fork a child to be the process group leader
    const pid = try std.posix.fork();

    if (pid == 0) {
        // Child: create new process group with self as leader
        _ = c.setpgid(0, 0);

        // Reset signal handlers to default in child
        const default_act = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TSTP, &default_act, null);
        std.posix.sigaction(std.posix.SIG.TTIN, &default_act, null);
        std.posix.sigaction(std.posix.SIG.TTOU, &default_act, null);
        std.posix.sigaction(std.posix.SIG.CHLD, &default_act, null);

        // Execute the statement chains
        var last_status: u8 = 0;
        for (stmt.chains) |chain| {
            last_status = pipeline.executePipelineInChild(allocator, chain.pipeline) catch 1;
        }
        std.posix.exit(last_status);
    }

    // Parent: set process group (race with child doing same)
    _ = c.setpgid(pid, pid);

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

/// Try to execute a user-defined function.
/// Returns the exit status if it was a function, null otherwise.
/// Order: builtins > functions > external commands
///
/// Note: This function catches errors internally and returns a status code
/// to break the error set cycle (exec → pipeline → exec).
fn tryRunFunction(allocator: std.mem.Allocator, state: *State, cmd: ExpandedCmd) ?u8 {
    if (cmd.argv.len == 0) return null;

    const name = cmd.argv[0];
    const body = state.getFunction(name) orelse return null;

    // Save current $argv (as list)
    const old_argv = state.getVarList("argv");

    // Set $argv to function arguments (skip function name)
    if (cmd.argv.len > 1) {
        state.setVarList("argv", cmd.argv[1..]) catch {};
    } else {
        // Empty argv for no arguments
        state.setVarList("argv", &[_][]const u8{}) catch {};
    }

    // Execute the function body, catching errors and converting to status
    const status = interpreter_mod.execute(allocator, state, body) catch |err| {
        io.printError("function {s}: {}\n", .{ name, err });
        // Restore $argv before returning error status
        if (old_argv) |v| {
            state.setVarList("argv", v) catch {};
        } else {
            state.unsetVar("argv");
        }
        state.fn_return = false;
        return 1;
    };

    // Handle return statement - status is already set, just reset the flag
    if (state.fn_return) {
        state.fn_return = false;
    }

    // Restore $argv
    if (old_argv) |v| {
        state.setVarList("argv", v) catch {};
    } else {
        state.unsetVar("argv");
    }

    return status;
}
