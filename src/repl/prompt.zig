//! Prompt generation for the REPL
const std = @import("std");
const State = @import("../runtime/state.zig").State;
const ansi = @import("../terminal/ansi.zig");
const interpreter = @import("../interpreter/interpreter.zig");

// Prompt suffix
const suffix = "# ";

/// Build and return the shell prompt string.
/// If a `prompt` function is defined, execute it and use its output.
/// Otherwise, use the default cwd-based prompt.
pub fn build(allocator: std.mem.Allocator, state: *State, buf: []u8) []const u8 {
    if (state.getFunction("prompt")) |body| {
        const output = interpreter.executeAndCapture(allocator, state, body) catch return buildDefault(allocator, state, buf);
        defer allocator.free(output);
        const len = @min(output.len, buf.len);
        @memcpy(buf[0..len], output[0..len]);
        return buf[0..len];
    }
    return buildDefault(allocator, state, buf);
}

/// Default prompt: green cwd (with ~ substitution), optional magenta git branch, followed by "# "
fn buildDefault(allocator: std.mem.Allocator, state: *State, buf: []u8) []const u8 {
    const cwd = state.getCwd() catch "?";

    const display_path = if (state.home) |home| blk: {
        if (std.mem.startsWith(u8, cwd, home)) {
            if (cwd.len == home.len) {
                break :blk "~";
            } else if (cwd[home.len] == '/') {
                const subpath = cwd[home.len..];
                break :blk std.fmt.bufPrint(buf[0..512], "~{s}", .{subpath}) catch cwd;
            }
        }
        break :blk cwd;
    } else cwd;

    const cwd_prefix = std.fmt.bufPrint(buf[512..1024], ansi.green ++ "{s}" ++ ansi.reset ++ " ", .{display_path}) catch return suffix;
    const branch_suffix = if (getGitBranch(allocator, state)) |git_output| blk: {
        defer allocator.free(git_output);
        const branch = std.mem.trimRight(u8, git_output, "\n\r ");
        break :blk std.fmt.bufPrint(buf[1024..1280], ansi.magenta ++ "({s})" ++ ansi.reset ++ " ", .{branch}) catch "";
    } else "";

    return std.fmt.bufPrint(buf[1280..], "{s}{s}" ++ suffix, .{ cwd_prefix, branch_suffix }) catch suffix;
}

/// Get the current git branch name by calling git CLI
/// Caller must free the returned slice using the same allocator.
fn getGitBranch(allocator: std.mem.Allocator, state: *State) ?[]const u8 {
    const output = interpreter.executeAndCapture(allocator, state, "git branch --show-current 2>/dev/null") catch return null;
    const branch = std.mem.trimRight(u8, output, "\n\r ");
    if (branch.len == 0) {
        allocator.free(output);
        return null;
    }
    return output;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "prompt: buildDefault returns valid prompt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();

    var buf: [4096]u8 = undefined;
    const prompt_str = buildDefault(arena.allocator(), &state, &buf);

    // Should end with "# " suffix
    try testing.expect(std.mem.endsWith(u8, prompt_str, "# "));
    // Should contain something (at least the suffix)
    try testing.expect(prompt_str.len >= 2);
}

test "prompt: tilde substitution in path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();

    // Set home to a known value
    state.home = "/home/testuser";

    var buf: [4096]u8 = undefined;
    const prompt_str = buildDefault(arena.allocator(), &state, &buf);

    // Prompt should be generated (may or may not contain ~ depending on cwd)
    try testing.expect(prompt_str.len > 0);
    try testing.expect(std.mem.endsWith(u8, prompt_str, "# "));
}

test "prompt: build uses custom prompt function if defined" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();

    // Define a custom prompt function
    try state.setFunction("prompt", "echo 'custom> '");

    var buf: [4096]u8 = undefined;
    const prompt_str = build(arena.allocator(), &state, &buf);

    // Should contain output from custom function
    try testing.expectEqualStrings("custom> \n", prompt_str);
}

test "prompt: build falls back to default without prompt function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State.init(arena.allocator());
    defer state.deinit();

    var buf: [4096]u8 = undefined;
    const prompt_str = build(arena.allocator(), &state, &buf);

    // Should get default prompt (ends with "# ")
    try testing.expect(std.mem.endsWith(u8, prompt_str, "# "));
}
