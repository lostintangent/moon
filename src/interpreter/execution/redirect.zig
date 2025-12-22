//! File descriptor redirection for shell commands.
//!
//! Handles `<`, `>`, `>>`, `2>`, `2>>`, `&>`, and `2>&1` redirections
//! by opening files and using dup2() to redirect standard file descriptors.

const std = @import("std");
const expansion_types = @import("../expansion/expanded.zig");
const io = @import("../../terminal/io.zig");

const ExpandedRedirect = expansion_types.ExpandedRedirect;

/// Open a file and dup2 it to target fd
fn openAndDup(path: []const u8, flags: std.posix.O, mode: std.posix.mode_t, target_fd: u8) !void {
    const fd = std.posix.open(path, flags, mode) catch |err| {
        io.printError("oshen: {s}: {}\n", .{ path, err });
        return err;
    };
    defer std.posix.close(fd);
    try std.posix.dup2(fd, target_fd);
}

/// Apply file redirections for a command (called in child process)
/// Redirections are applied in order, which matters for cases like `>out 2>&1`
pub fn apply(redirs: []const ExpandedRedirect) !void {
    for (redirs) |redir| {
        switch (redir.kind) {
            .read => |path| {
                try openAndDup(path, .{ .ACCMODE = .RDONLY }, 0, redir.from_fd);
            },
            .write_truncate => |path| {
                try openAndDup(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644, redir.from_fd);
            },
            .write_append => |path| {
                try openAndDup(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644, redir.from_fd);
            },
            .dup => |to_fd| {
                try std.posix.dup2(to_fd, redir.from_fd);
            },
        }
    }
}
