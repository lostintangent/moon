//! Shell runtime state
//!
//! Central state management for the shell including variables, exports,
//! functions, aliases, job control, and working directory.

const std = @import("std");
const jobs = @import("jobs.zig");
const env = @import("env.zig");
const interpreter = @import("../interpreter/interpreter.zig");

pub const JobTable = jobs.JobTable;
pub const Job = jobs.Job;
pub const JobStatus = jobs.JobStatus;

/// A user-defined function with lazy-parsed AST caching.
pub const Function = struct {
    /// The raw source text of the function body (owned by State's allocator)
    source: []const u8,

    /// Cached parse result; arena owns the AST memory, backed by page_allocator for stability
    cached: ?struct {
        arena: std.heap.ArenaAllocator,
        parsed: interpreter.ParsedInput,
    } = null,

    /// Get the parsed AST, parsing on first call.
    /// Uses page_allocator for the arena to ensure it outlives any execution arenas.
    pub fn getParsed(self: *Function) !interpreter.ParsedInput {
        if (self.cached) |c| return c.parsed;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const parsed = try interpreter.parseInput(arena.allocator(), self.source);
        self.cached = .{ .arena = arena, .parsed = parsed };
        return parsed;
    }

    /// Free all memory owned by this function.
    pub fn deinit(self: *Function, allocator: std.mem.Allocator) void {
        if (self.cached) |*c| c.arena.deinit();
        allocator.free(self.source);
    }
};

/// Shell state: variables, status, cwd, options
pub const State = struct {
    allocator: std.mem.Allocator,

    /// Last command exit status
    status: u8 = 0,

    /// Shell variables (list-valued)
    vars: std.StringHashMap([]const []const u8),

    /// Exported environment variables
    exports: std.StringHashMap([]const u8),

    /// User-defined functions (name -> Function with cached AST)
    functions: std.StringHashMap(Function),

    /// Aliases (name -> expansion text)
    aliases: std.StringHashMap([]const u8),

    /// Current working directory (cached)
    cwd: ?[]const u8 = null,

    /// Previous working directory (for `cd -`)
    prev_cwd: ?[]const u8 = null,

    /// Home directory
    home: ?[]const u8 = null,

    /// Job table for background/stopped jobs
    jobs: JobTable,

    /// Shell's process group ID (for terminal control)
    shell_pgid: std.posix.pid_t = 0,

    /// Terminal file descriptor (for tcsetpgrp)
    terminal_fd: std.posix.fd_t = std.posix.STDIN_FILENO,

    /// Whether we're an interactive shell
    interactive: bool = false,

    /// Flag to signal shell should exit
    should_exit: bool = false,

    /// Exit code to use when exiting
    exit_code: u8 = 0,

    /// Flag to signal loop should break
    loop_break: bool = false,

    /// Flag to signal loop should continue to next iteration
    loop_continue: bool = false,

    /// Flag to signal function should return
    fn_return: bool = false,

    /// Stack of deferred commands (LIFO execution order)
    deferred: std.ArrayListUnmanaged([]const u8),

    // =========================================================================
    // Memory Management Helpers
    // =========================================================================

    /// Free a variable entry (key and all values in the list)
    fn freeVarEntry(self: *State, entry: std.StringHashMap([]const []const u8).KV) void {
        self.allocator.free(entry.key);
        for (entry.value) |v| self.allocator.free(v);
        self.allocator.free(entry.value);
    }

    /// Free an export, function, or alias entry (key-value pair)
    pub fn freeStringEntry(self: *State, entry: std.StringHashMap([]const u8).KV) void {
        self.allocator.free(entry.key);
        self.allocator.free(entry.value);
    }

    pub fn init(allocator: std.mem.Allocator) State {
        var state = State{
            .allocator = allocator,
            .vars = std.StringHashMap([]const []const u8).init(allocator),
            .exports = std.StringHashMap([]const u8).init(allocator),
            .functions = std.StringHashMap(Function).init(allocator),
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .jobs = JobTable.init(allocator),
            .deferred = .empty,
        };

        // Initialize HOME from environment
        if (env.getHome()) |home| {
            state.home = home;
        }

        return state;
    }

    pub fn deinit(self: *State) void {
        // Free all variable keys and values
        var var_iter = self.vars.iterator();
        while (var_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |v| {
                self.allocator.free(v);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.vars.deinit();

        // Free all export keys and values
        var exp_iter = self.exports.iterator();
        while (exp_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.exports.deinit();

        // Free all function names and cached parse state
        var fn_iter = self.functions.iterator();
        while (fn_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.functions.deinit();

        // Free all alias names and expansions
        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.aliases.deinit();

        if (self.cwd) |cwd| {
            self.allocator.free(cwd);
        }

        if (self.prev_cwd) |prev| {
            self.allocator.free(prev);
        }

        // Clean up jobs
        self.jobs.deinit();

        // Free deferred commands
        for (self.deferred.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.deferred.deinit(self.allocator);
    }

    /// Get a variable value (returns first element for string context)
    pub fn getVar(self: *State, name: []const u8) ?[]const u8 {
        // Check shell vars first
        if (self.vars.get(name)) |list| {
            if (list.len > 0) return list[0];
        }
        // Fall back to environment
        return env.get(name);
    }

    /// Get variable as list
    pub fn getVarList(self: *State, name: []const u8) ?[]const []const u8 {
        return self.vars.get(name);
    }

    /// Set a variable (as single value)
    pub fn setVar(self: *State, name: []const u8, value: []const u8) !void {
        const list = try self.allocator.alloc([]const u8, 1);
        list[0] = try self.allocator.dupe(u8, value);

        // Free old entry if it exists
        if (self.vars.fetchRemove(name)) |old| {
            self.freeVarEntry(old);
        }

        const key = try self.allocator.dupe(u8, name);
        try self.vars.put(key, list);
    }

    /// Set a variable (as list, for tests and list variables)
    pub fn setVarList(self: *State, name: []const u8, values: []const []const u8) !void {
        // Free old entry if it exists
        if (self.vars.fetchRemove(name)) |old| {
            self.freeVarEntry(old);
        }

        // Copy all values
        const list = try self.allocator.alloc([]const u8, values.len);
        for (values, 0..) |v, i| {
            list[i] = try self.allocator.dupe(u8, v);
        }

        const key = try self.allocator.dupe(u8, name);
        try self.vars.put(key, list);
    }

    /// Remove a variable
    pub fn unsetVar(self: *State, name: []const u8) void {
        if (self.vars.fetchRemove(name)) |old| {
            self.freeVarEntry(old);
        }
    }

    /// Get a function by name (returns mutable pointer for lazy caching)
    pub fn getFunction(self: *State, name: []const u8) ?*Function {
        return self.functions.getPtr(name);
    }

    /// Define or redefine a function
    pub fn setFunction(self: *State, name: []const u8, body: []const u8) !void {
        if (self.functions.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            var func = old.value;
            func.deinit(self.allocator);
        }

        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const source = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(source);

        try self.functions.put(key, .{ .source = source });
    }

    /// Get an alias expansion by name
    pub fn getAlias(self: *State, name: []const u8) ?[]const u8 {
        return self.aliases.get(name);
    }

    /// Define or redefine an alias
    pub fn setAlias(self: *State, name: []const u8, expansion: []const u8) !void {
        if (self.aliases.fetchRemove(name)) |old| {
            self.freeStringEntry(old);
        }

        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, expansion);
        errdefer self.allocator.free(value);

        try self.aliases.put(key, value);
    }

    /// Remove an alias
    pub fn unsetAlias(self: *State, name: []const u8) void {
        if (self.aliases.fetchRemove(name)) |old| {
            self.freeStringEntry(old);
        }
    }

    /// Set last exit status
    pub fn setStatus(self: *State, status: u8) void {
        self.status = status;
    }

    /// Get current working directory
    pub fn getCwd(self: *State) ![]const u8 {
        if (self.cwd) |cwd| return cwd;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.posix.getcwd(&buf);
        self.cwd = try self.allocator.dupe(u8, cwd);
        return self.cwd.?;
    }

    /// Change directory and update prev_cwd
    pub fn chdir(self: *State, path: []const u8) !void {
        // Get current directory before changing (to save as prev_cwd)
        const old_cwd = self.getCwd() catch null;

        // Change to the new directory
        try std.posix.chdir(path);

        // Save old directory as prev_cwd after successful change
        if (old_cwd) |old| {
            // Free existing prev_cwd if any
            if (self.prev_cwd) |prev| {
                self.allocator.free(prev);
            }
            // Move the old cwd to prev_cwd (it's already allocated)
            self.prev_cwd = old;
        }

        // Invalidate cached cwd since we changed directories
        self.cwd = null;
    }

    /// Push a deferred command onto the stack (executed LIFO on function exit)
    pub fn pushDefer(self: *State, cmd: []const u8) !void {
        const duped = try self.allocator.dupe(u8, cmd);
        try self.deferred.append(self.allocator, duped);
    }

    /// Pop and return the last deferred command, or null if empty
    pub fn popDeferred(self: *State) ?[]const u8 {
        if (self.deferred.items.len == 0) return null;
        return self.deferred.pop();
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "functions: set and get" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try state.setFunction("greet", "echo hello");

    const func = state.getFunction("greet");
    try testing.expect(func != null);
    try testing.expectEqualStrings("echo hello", func.?.source);
}

test "functions: get nonexistent returns null" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try testing.expectEqual(@as(?*Function, null), state.getFunction("nonexistent"));
}

test "functions: redefinition replaces body" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try state.setFunction("greet", "echo v1");
    try state.setFunction("greet", "echo v2");

    const func = state.getFunction("greet");
    try testing.expectEqualStrings("echo v2", func.?.source);
}

test "functions: multiple functions" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try state.setFunction("foo", "echo foo");
    try state.setFunction("bar", "echo bar");
    try state.setFunction("baz", "echo baz");

    try testing.expectEqualStrings("echo foo", state.getFunction("foo").?.source);
    try testing.expectEqualStrings("echo bar", state.getFunction("bar").?.source);
    try testing.expectEqualStrings("echo baz", state.getFunction("baz").?.source);
}

test "variables: unset removes variable" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try state.setVar("foo", "bar");
    try testing.expect(state.getVar("foo") != null);

    state.unsetVar("foo");
    // After unset, should not be in vars hashmap
    try testing.expect(!state.vars.contains("foo"));
}

test "variables: unset nonexistent is safe" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    // Should not panic or error
    state.unsetVar("nonexistent");
}

test "aliases: set and get" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try state.setAlias("ll", "ls -la");

    const expansion = state.getAlias("ll");
    try testing.expect(expansion != null);
    try testing.expectEqualStrings("ls -la", expansion.?);
}

test "aliases: get nonexistent returns null" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try testing.expectEqual(@as(?[]const u8, null), state.getAlias("nonexistent"));
}

test "aliases: redefinition replaces expansion" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try state.setAlias("g", "git");
    try state.setAlias("g", "git status");

    const expansion = state.getAlias("g");
    try testing.expectEqualStrings("git status", expansion.?);
}

test "aliases: unset removes alias" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try state.setAlias("ll", "ls -la");
    try testing.expect(state.getAlias("ll") != null);

    state.unsetAlias("ll");
    try testing.expect(!state.aliases.contains("ll"));
}

test "aliases: unset nonexistent is safe" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    // Should not panic or error
    state.unsetAlias("nonexistent");
}
