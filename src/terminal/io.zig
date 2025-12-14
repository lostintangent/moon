//! Terminal I/O utilities.
//!
//! Provides helpers for writing to file descriptors, stdout, and stderr.

const std = @import("std");

/// Write data to a file descriptor, ignoring errors
pub fn writeToFd(fd: std.posix.fd_t, data: []const u8) void {
    _ = std.posix.write(fd, data) catch {};
}

/// Write data to stdout, ignoring errors
pub fn writeStdout(data: []const u8) void {
    writeToFd(std.posix.STDOUT_FILENO, data);
}

/// Write data to stderr, ignoring errors
pub fn writeStderr(data: []const u8) void {
    writeToFd(std.posix.STDERR_FILENO, data);
}

/// Print a formatted message to a file descriptor
pub fn printToFd(fd: std.posix.fd_t, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        writeToFd(fd, "oshen: format error\n");
        return;
    };
    writeToFd(fd, msg);
}

/// Print a formatted error message to stderr
pub fn printError(comptime fmt: []const u8, args: anytype) void {
    printToFd(std.posix.STDERR_FILENO, fmt, args);
}

/// Print a formatted message to stdout
pub fn printStdout(comptime fmt: []const u8, args: anytype) void {
    printToFd(std.posix.STDOUT_FILENO, fmt, args);
}
