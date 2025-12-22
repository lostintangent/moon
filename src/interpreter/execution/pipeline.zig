//! Pipeline execution: fork/exec, pipe wiring, and process management
//!
//! This module handles the low-level execution of command pipelines:
//! - Forking child processes
//! - Setting up pipes between commands
//! - exec() system call
//! - Waiting for child processes

const std = @import("std");
const expansion_types = @import("../expansion/expanded.zig");
const state_mod = @import("../../runtime/state.zig");
const State = state_mod.State;
const builtins = @import("../../runtime/builtins.zig");
const io = @import("../../terminal/io.zig");
const redirect = @import("redirect.zig");
const jobs = @import("jobs.zig");

const ExpandedCmd = expansion_types.ExpandedCmd;
const posix = jobs.posix;

// =============================================================================
// Types
// =============================================================================

/// Function pointer type for trying to run commands as user-defined functions.
/// Returns exit status if command was a function, null if not a function.
pub const FunctionExecutor = *const fn (std.mem.Allocator, *State, ExpandedCmd) ?u8;

// =============================================================================
// Public API
// =============================================================================

/// Build null-terminated argv array for execvpe
pub fn buildArgv(allocator: std.mem.Allocator, cmd: ExpandedCmd) !std.ArrayListUnmanaged(?[*:0]const u8) {
    var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    errdefer argv.deinit(allocator);

    for (cmd.argv) |arg| {
        const z = try allocator.dupeZ(u8, arg);
        try argv.append(allocator, z);
    }
    try argv.append(allocator, null);

    return argv;
}

/// Execute a pipeline in foreground, checking for aliases, builtins, and functions first
pub fn executePipelineForeground(allocator: std.mem.Allocator, state: *State, commands: []const ExpandedCmd, tryRunFunction: FunctionExecutor) !u8 {
    if (commands.len == 0) return 0;

    // Single command - check for builtin first, then functions
    if (commands.len == 1) {
        const cmd = commands[0];
        if (cmd.argv.len > 0) {
            // Check if it's a builtin
            if (builtins.isBuiltin(cmd.argv[0])) {
                // If builtin has redirections, fork to apply them properly
                if (cmd.redirects.len > 0) {
                    return try executeBuiltinWithRedirects(allocator, state, cmd);
                }
                // No redirections - run builtin directly
                if (builtins.tryRun(state, cmd)) |status| {
                    return status;
                }
            }
            // Then user-defined functions
            if (cmd.redirects.len > 0) {
                if (state.getFunction(cmd.argv[0])) |_| {
                    return try executeFunctionWithRedirects(allocator, state, cmd, tryRunFunction);
                }
            } else if (tryRunFunction(allocator, state, cmd)) |status| {
                return status;
            }
        }
        return try executePipelineWithJobControl(allocator, state, commands, tryRunFunction);
    }

    return try executePipelineWithJobControl(allocator, state, commands, tryRunFunction);
}

/// Execute a builtin command with file redirections by forking
fn executeBuiltinWithRedirects(_: std.mem.Allocator, state: *State, cmd: ExpandedCmd) !u8 {
    const pid = try std.posix.fork();

    if (pid == 0) {
        // Child: apply redirections, then run builtin
        redirect.apply(cmd.redirects) catch {
            std.posix.exit(1);
        };

        const status = builtins.tryRun(state, cmd) orelse 127;
        std.posix.exit(status);
    }

    // Parent: wait for child
    return waitForChild(pid);
}

/// Execute a user-defined function with redirects in a forked child
fn executeFunctionWithRedirects(allocator: std.mem.Allocator, state: *State, cmd: ExpandedCmd, tryRunFunction: FunctionExecutor) !u8 {
    const pid = try std.posix.fork();

    if (pid == 0) {
        redirect.apply(cmd.redirects) catch {
            std.posix.exit(1);
        };

        const status = tryRunFunction(allocator, state, cmd) orelse 127;
        std.posix.exit(status);
    }

    return waitForChild(pid);
}

// =============================================================================
// Child Process Execution
// =============================================================================

/// Execute a pipeline in a child process (no job control needed)
pub fn executePipelineInChild(allocator: std.mem.Allocator, state: ?*State, commands: []const ExpandedCmd, tryRunFunction: ?FunctionExecutor) !u8 {
    if (commands.len == 0) return 0;

    // In child, we don't need job control - just execute
    if (commands.len == 1) {
        if (state) |s| {
            return try executeSingleCommand(allocator, s, commands[0], tryRunFunction);
        }
        return try executeCommandSimple(allocator, commands[0]);
    }

    // Multi-command pipeline
    const n = commands.len;
    var pipes: std.ArrayListUnmanaged([2]std.posix.fd_t) = .empty;
    defer {
        for (pipes.items) |pipe| {
            std.posix.close(pipe[0]);
            std.posix.close(pipe[1]);
        }
        pipes.deinit(allocator);
    }

    for (0..n - 1) |_| {
        const pipe = try std.posix.pipe();
        try pipes.append(allocator, pipe);
    }

    var pids: std.ArrayListUnmanaged(std.posix.pid_t) = .empty;
    defer pids.deinit(allocator);

    for (commands, 0..) |cmd, i| {
        const stdin_fd: ?std.posix.fd_t = if (i == 0) null else pipes.items[i - 1][0];
        const stdout_fd: ?std.posix.fd_t = if (i == n - 1) null else pipes.items[i][1];

        const child_pid = try std.posix.fork();

        if (child_pid == 0) {
            setupPipeRedirects(stdin_fd, stdout_fd);
            for (pipes.items) |pipe| {
                std.posix.close(pipe[0]);
                std.posix.close(pipe[1]);
            }
            execCommandWithState(allocator, state, tryRunFunction, cmd);
        }

        try pids.append(allocator, child_pid);
    }

    for (pipes.items) |pipe| {
        std.posix.close(pipe[0]);
        std.posix.close(pipe[1]);
    }
    pipes.clearRetainingCapacity();

    var last_status: u8 = 0;
    for (pids.items) |child_pid| {
        last_status = waitForChild(child_pid);
    }

    return last_status;
}

fn executeSingleCommand(allocator: std.mem.Allocator, state: *State, cmd: ExpandedCmd, tryRunFunction: ?FunctionExecutor) !u8 {
    if (cmd.argv.len == 0) return 0;

    // Builtin fast paths
    if (builtins.isBuiltin(cmd.argv[0])) {
        if (cmd.redirects.len > 0) {
            return try executeBuiltinWithRedirects(allocator, state, cmd);
        }
        if (builtins.tryRun(state, cmd)) |status| {
            return status;
        }
    }

    // Functions (only when provided)
    if (tryRunFunction) |f| {
        if (cmd.argv.len > 0) {
            if (cmd.redirects.len > 0) {
                if (state.getFunction(cmd.argv[0])) |_| {
                    return try executeFunctionWithRedirects(allocator, state, cmd, f);
                }
            } else if (f(allocator, state, cmd)) |status| {
                return status;
            }
        }
    }

    return try executeCommandSimple(allocator, cmd);
}

// =============================================================================
// Pipeline Orchestration
// =============================================================================

/// Execute a pipeline with full job control (terminal handling, process groups)
pub fn executePipelineWithJobControl(allocator: std.mem.Allocator, state: *State, commands: []const ExpandedCmd, tryRunFunction: FunctionExecutor) !u8 {
    const n = commands.len;

    // Create pipes for multi-command pipeline
    var pipes: std.ArrayListUnmanaged([2]std.posix.fd_t) = .empty;
    defer {
        for (pipes.items) |pipe| {
            std.posix.close(pipe[0]);
            std.posix.close(pipe[1]);
        }
        pipes.deinit(allocator);
    }

    for (0..n - 1) |_| {
        const pipe = try std.posix.pipe();
        try pipes.append(allocator, pipe);
    }

    // Fork all processes, putting them in the same process group
    var pids: std.ArrayListUnmanaged(std.posix.pid_t) = .empty;
    defer pids.deinit(allocator);

    var pgid: std.posix.pid_t = 0;

    for (commands, 0..) |cmd, i| {
        const stdin_fd: ?std.posix.fd_t = if (i == 0) null else pipes.items[i - 1][0];
        const stdout_fd: ?std.posix.fd_t = if (i == n - 1) null else pipes.items[i][1];

        const pid = try std.posix.fork();

        if (pid == 0) {
            // Child process
            // Set process group (first child becomes group leader)
            const child_pgid = if (pgid == 0) posix.getpid() else pgid;
            _ = posix.setpgid(0, child_pgid);

            // Reset signal handlers to default
            jobs.resetSignalsToDefault();

            setupPipeRedirects(stdin_fd, stdout_fd);

            for (pipes.items) |pipe| {
                std.posix.close(pipe[0]);
                std.posix.close(pipe[1]);
            }

            execCommandWithState(allocator, state, tryRunFunction, cmd);
        }

        // Parent: set process group (race with child)
        if (pgid == 0) pgid = pid;
        _ = posix.setpgid(pid, pgid);

        try pids.append(allocator, pid);
    }

    // Parent: close all pipe fds
    for (pipes.items) |pipe| {
        std.posix.close(pipe[0]);
        std.posix.close(pipe[1]);
    }
    pipes.clearRetainingCapacity();

    // Give terminal to the job's process group (foreground only)
    if (state.interactive and pgid != 0) {
        _ = posix.tcsetpgrp(state.terminal_fd, pgid);
    }

    // Wait for all children
    var last_status: u8 = 0;
    for (pids.items) |pid| {
        last_status = jobs.waitForChildWithStop(pid);
    }

    // Take back terminal control
    if (state.interactive) {
        _ = posix.tcsetpgrp(state.terminal_fd, state.shell_pgid);
    }

    return last_status;
}

// =============================================================================
// Simple Execution
// =============================================================================

/// Execute a single command (fork + exec + wait)
pub fn executeCommandSimple(allocator: std.mem.Allocator, cmd: ExpandedCmd) !u8 {
    if (cmd.argv.len == 0) return 0;

    const pid = try std.posix.fork();

    if (pid == 0) {
        execCommand(allocator, cmd);
    }

    return waitForChild(pid);
}

/// Set up pipeline stdin/stdout redirects (called in child)
pub fn setupPipeRedirects(stdin_fd: ?std.posix.fd_t, stdout_fd: ?std.posix.fd_t) void {
    if (stdin_fd) |fd| {
        std.posix.dup2(fd, std.posix.STDIN_FILENO) catch {
            std.posix.exit(1);
        };
    }
    if (stdout_fd) |fd| {
        std.posix.dup2(fd, std.posix.STDOUT_FILENO) catch {
            std.posix.exit(1);
        };
    }
}

// =============================================================================
// Exec Helpers
// =============================================================================

/// Execute command in child process (does not return)
pub fn execCommand(allocator: std.mem.Allocator, cmd: ExpandedCmd) noreturn {
    execCommandWithState(allocator, null, null, cmd);
}

/// Execute command in child process with optional state for builtins (does not return)
pub fn execCommandWithState(allocator: std.mem.Allocator, state: ?*State, tryRunFunction: ?FunctionExecutor, cmd: ExpandedCmd) noreturn {
    // Apply file redirections
    redirect.apply(cmd.redirects) catch {
        std.posix.exit(1);
    };

    // If we have state, try running as builtin first
    if (state) |s| {
        if (cmd.argv.len > 0 and builtins.isBuiltin(cmd.argv[0])) {
            const status = builtins.tryRun(s, cmd) orelse 127;
            std.posix.exit(status);
        }
        if (tryRunFunction) |f| {
            if (f(allocator, s, cmd)) |status| {
                std.posix.exit(status);
            }
        }
    }

    const argv = buildArgv(allocator, cmd) catch {
        std.posix.exit(127);
    };

    const envp = std.c.environ;
    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv.items.ptr);

    const err = std.posix.execvpeZ(argv.items[0].?, argv_ptr, envp);

    // If we get here, exec failed
    const msg = if (err == error.FileNotFound) "Command not found" else @errorName(err);
    io.printError("{s}: {s}\n", .{ msg, cmd.argv[0] });
    std.posix.exit(127);
}

/// Wait for child process and return exit status
pub fn waitForChild(pid: std.posix.pid_t) u8 {
    const result = std.posix.waitpid(pid, 0);

    if (std.posix.W.IFEXITED(result.status)) {
        return std.posix.W.EXITSTATUS(result.status);
    } else if (std.posix.W.IFSIGNALED(result.status)) {
        return 128 + @as(u8, @intCast(std.posix.W.TERMSIG(result.status)));
    }

    return 1;
}
