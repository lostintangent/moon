//! Shell runtime state
//!
//! Central state management for the shell including variables, exports,
//! functions, aliases, job control, and working directory.
//!
//! Variables use a scope chain for proper lexical scoping:
//! - Variables defined in blocks (if/while/each/fun) are block-local
//! - Setting an existing variable updates it in the scope where it was defined
//! - Setting a new variable creates it in the current (innermost) scope

const std = @import("std");
const jobs = @import("jobs.zig");
const env = @import("env.zig");
const interpreter = @import("../interpreter/interpreter.zig");
const ast = @import("../language/ast.zig");
const Scope = @import("scope.zig").Scope;
const ScopeValue = @import("scope.zig").Value;

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

    /// Global scope for variables (always exists, never popped)
    global_scope: Scope,

    /// Current (innermost) scope for variable lookups and assignments
    current_scope: *Scope,

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

    /// Stack of deferred commands (LIFO execution order).
    /// CommandStatements contain slices that point into the cached function AST.
    deferred: std.ArrayListUnmanaged(ast.CommandStatement),

    // =========================================================================
    // Initialization
    // =========================================================================

    pub fn init(allocator: std.mem.Allocator) State {
        var state = State{
            .allocator = allocator,
            .global_scope = Scope.init(null, allocator),
            .current_scope = undefined, // Set by caller via initCurrentScope()
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

    /// Must be called after init() once the State is in its final location.
    /// This fixes up the self-referential current_scope pointer.
    pub fn initCurrentScope(self: *State) void {
        self.current_scope = &self.global_scope;
    }

    pub fn deinit(self: *State) void {
        // Pop any remaining child scopes (shouldn't happen in normal operation)
        while (self.current_scope != &self.global_scope) {
            const old_scope = self.current_scope;
            self.current_scope = old_scope.parent orelse &self.global_scope;
            old_scope.deinit();
            self.allocator.destroy(old_scope);
        }

        // Free global scope's arena (but not the struct itself - it's embedded in State)
        self.global_scope.deinit();

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

        // Deferred commands are pointers into cached AST, no need to free contents
        self.deferred.deinit(self.allocator);
    }

    // =========================================================================
    // Scope Management
    // =========================================================================

    /// Push a new scope for a block (loop, function, if statement).
    /// Returns a pointer to the new scope for direct manipulation.
    pub fn pushScope(self: *State) !*Scope {
        const new_scope = try self.allocator.create(Scope);
        new_scope.* = Scope.init(self.current_scope, self.allocator);
        self.current_scope = new_scope;
        return new_scope;
    }

    /// Pop the current scope, restoring the parent as current.
    /// Frees all memory allocated in the popped scope.
    pub fn popScope(self: *State) void {
        const old_scope = self.current_scope;

        // Don't pop the global scope
        if (old_scope == &self.global_scope) return;

        // Restore parent as current
        self.current_scope = old_scope.parent orelse &self.global_scope;

        // Free the old scope
        old_scope.deinit();
        self.allocator.destroy(old_scope);
    }

    // =========================================================================
    // Variable Operations
    // =========================================================================

    /// Find the scope where a variable should be set:
    /// - If it exists anywhere in the chain, return that scope (for updates)
    /// - Otherwise, return the current scope (for new variables)
    fn targetScope(self: *State, name: []const u8) *Scope {
        return self.current_scope.findScope(name) orelse self.current_scope;
    }

    /// Get a variable value as a string (first element for lists).
    /// Walks the scope chain, then falls back to environment.
    pub fn getVar(self: *State, name: []const u8) ?[]const u8 {
        // Walk scope chain
        if (self.current_scope.get(name)) |value| {
            return value.asScalar();
        }
        // Fall back to environment
        return env.get(name);
    }

    /// Get a variable as a list.
    /// Walks the scope chain. Does NOT fall back to environment (env vars are scalars).
    pub fn getVarList(self: *State, name: []const u8) ?[]const []const u8 {
        if (self.current_scope.get(name)) |value| {
            return switch (value) {
                .list => |l| l,
                .scalar => null, // Scalars don't convert to lists for getVarList
            };
        }
        return null;
    }

    /// Set a variable as a single value.
    /// Updates in the scope where it's defined, or creates in current scope.
    pub fn setVar(self: *State, name: []const u8, value: []const u8) !void {
        try self.targetScope(name).setLocalScalar(name, value);
    }

    /// Set a variable as a list.
    /// Updates in the scope where it's defined, or creates in current scope.
    pub fn setVarList(self: *State, name: []const u8, values: []const []const u8) !void {
        try self.targetScope(name).setLocalList(name, values);
    }

    /// Set a variable in the CURRENT scope only (for loop variables).
    /// This always creates/updates in the innermost scope, enabling proper shadowing.
    pub fn setLocalVar(self: *State, name: []const u8, value: []const u8) !void {
        try self.current_scope.setLocalScalar(name, value);
    }

    /// Set a list variable in the CURRENT scope only.
    pub fn setLocalVarList(self: *State, name: []const u8, values: []const []const u8) !void {
        try self.current_scope.setLocalList(name, values);
    }

    /// Remove a variable from the scope where it's defined.
    pub fn unsetVar(self: *State, name: []const u8) void {
        if (self.current_scope.findScope(name)) |scope| {
            _ = scope.removeLocal(name);
        }
    }

    // =========================================================================
    // Functions
    // =========================================================================

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

    // =========================================================================
    // Aliases
    // =========================================================================

    /// Get an alias expansion by name
    pub fn getAlias(self: *State, name: []const u8) ?[]const u8 {
        return self.aliases.get(name);
    }

    /// Define or redefine an alias
    pub fn setAlias(self: *State, name: []const u8, expansion: []const u8) !void {
        if (self.aliases.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
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
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    // =========================================================================
    // Exports
    // =========================================================================

    /// Free an export entry (key-value pair) - used by builtins
    pub fn freeStringEntry(self: *State, entry: std.StringHashMap([]const u8).KV) void {
        self.allocator.free(entry.key);
        self.allocator.free(entry.value);
    }

    // =========================================================================
    // Status and CWD
    // =========================================================================

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

    // =========================================================================
    // Deferred Commands
    // =========================================================================

    /// Push a deferred command onto the stack (executed LIFO on function exit).
    /// The CommandStatement's internal slices point into the cached AST, so no deep copy needed.
    pub fn pushDefer(self: *State, cmd_stmt: ast.CommandStatement) !void {
        try self.deferred.append(self.allocator, cmd_stmt);
    }

    /// Pop and return the last deferred command, or null if empty
    pub fn popDeferred(self: *State) ?ast.CommandStatement {
        if (self.deferred.items.len == 0) return null;
        return self.deferred.pop();
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "variables: set and get" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    try state.setVar("foo", "bar");
    try testing.expectEqualStrings("bar", state.getVar("foo").?);
}

test "variables: set updates existing in outer scope" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    // Set in global scope
    try state.setVar("x", "outer");

    // Push a new scope
    _ = try state.pushScope();

    // Set should update the outer scope's variable
    try state.setVar("x", "modified");

    // Check in inner scope
    try testing.expectEqualStrings("modified", state.getVar("x").?);

    // Pop scope and check global
    state.popScope();
    try testing.expectEqualStrings("modified", state.getVar("x").?);
}

test "variables: new var in inner scope is local" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    // Push a new scope
    _ = try state.pushScope();

    // Set a NEW variable in inner scope
    try state.setVar("local", "value");
    try testing.expectEqualStrings("value", state.getVar("local").?);

    // Pop scope - variable should be gone
    state.popScope();
    try testing.expect(state.getVar("local") == null);
}

test "variables: setLocalVar always creates in current scope" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    // Set in global scope
    try state.setVar("x", "outer");

    // Push a new scope
    _ = try state.pushScope();

    // setLocalVar creates in current scope even if var exists in outer
    try state.setLocalVar("x", "shadowed");
    try testing.expectEqualStrings("shadowed", state.getVar("x").?);

    // Pop - should see outer value again
    state.popScope();
    try testing.expectEqualStrings("outer", state.getVar("x").?);
}

test "variables: unset removes variable" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    try state.setVar("foo", "bar");
    try testing.expect(state.getVar("foo") != null);

    state.unsetVar("foo");
    try testing.expect(state.getVar("foo") == null);
}

test "variables: unset nonexistent is safe" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    // Should not panic or error
    state.unsetVar("nonexistent");
}

test "variables: list operations" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    const values = [_][]const u8{ "a", "b", "c" };
    try state.setVarList("xs", &values);

    const list = state.getVarList("xs");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 3), list.?.len);
    try testing.expectEqualStrings("a", list.?[0]);

    // getVar returns first element
    try testing.expectEqualStrings("a", state.getVar("xs").?);
}

test "scope: push and pop" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    const global = state.current_scope;
    try testing.expect(global == &state.global_scope);

    const inner = try state.pushScope();
    try testing.expect(state.current_scope == inner);
    try testing.expect(inner.parent == global);

    state.popScope();
    try testing.expect(state.current_scope == global);
}

test "scope: reset for loop optimization" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    const scope = try state.pushScope();

    // Simulate loop iterations
    for (0..3) |i| {
        scope.reset(); // Clear vars, retain memory

        var buf: [16]u8 = undefined;
        const idx = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        try scope.setLocalScalar("i", idx);
    }

    // After reset, only the last value remains
    try testing.expectEqualStrings("2", scope.getLocal("i").?.asScalar().?);

    state.popScope();
}

test "functions: set and get" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    try state.setFunction("greet", "echo hello");

    const func = state.getFunction("greet");
    try testing.expect(func != null);
    try testing.expectEqualStrings("echo hello", func.?.source);
}

test "functions: get nonexistent returns null" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    try testing.expectEqual(@as(?*Function, null), state.getFunction("nonexistent"));
}

test "functions: redefinition replaces body" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    try state.setFunction("greet", "echo v1");
    try state.setFunction("greet", "echo v2");

    const func = state.getFunction("greet");
    try testing.expectEqualStrings("echo v2", func.?.source);
}

test "functions: multiple functions" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    try state.setFunction("foo", "echo foo");
    try state.setFunction("bar", "echo bar");
    try state.setFunction("baz", "echo baz");

    try testing.expectEqualStrings("echo foo", state.getFunction("foo").?.source);
    try testing.expectEqualStrings("echo bar", state.getFunction("bar").?.source);
    try testing.expectEqualStrings("echo baz", state.getFunction("baz").?.source);
}

test "aliases: set and get" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    try state.setAlias("ll", "ls -la");

    const expansion = state.getAlias("ll");
    try testing.expect(expansion != null);
    try testing.expectEqualStrings("ls -la", expansion.?);
}

test "aliases: get nonexistent returns null" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    try testing.expectEqual(@as(?[]const u8, null), state.getAlias("nonexistent"));
}

test "aliases: redefinition replaces expansion" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    try state.setAlias("g", "git");
    try state.setAlias("g", "git status");

    const expansion = state.getAlias("g");
    try testing.expectEqualStrings("git status", expansion.?);
}

test "aliases: unset removes alias" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    try state.setAlias("ll", "ls -la");
    try testing.expect(state.getAlias("ll") != null);

    state.unsetAlias("ll");
    try testing.expect(!state.aliases.contains("ll"));
}

test "aliases: unset nonexistent is safe" {
    var state = State.init(testing.allocator);
    state.initCurrentScope();
    defer state.deinit();

    // Should not panic or error
    state.unsetAlias("nonexistent");
}
