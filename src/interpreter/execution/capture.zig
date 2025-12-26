//! Subprocess output capture utilities.
//!
//! Provides `forkWithPipe()` for capturing stdout and stderr from a child process.
//! Used by:
//! - Output capture operators (`=>`, `=>@`)
//! - Command substitution `$(...)`
//! - Custom prompt function execution

const std = @import("std");
const io = @import("../../terminal/io.zig");

// C library functions
const c = struct {
    extern "c" fn waitpid(pid: std.posix.pid_t, status: ?*c_int, options: c_int) std.posix.pid_t;
};

pub const CaptureResult = struct {
    output: []const u8,
    status: u8,
};

/// Result of forkWithPipe - tells caller which process they're in.
pub const ForkResult = union(enum) {
    /// We're in the child - stdout and stderr are redirected to the pipe.
    /// Run your code and call std.posix.exit() when done.
    child: void,

    /// We're in the parent. Use readAndWait() to get the captured output.
    parent: ParentHandle,
};

pub const ParentHandle = struct {
    read_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,

    /// Read all output from the child and wait for it to exit.
    /// Returns the captured output (trimmed) and exit status.
    pub fn readAndWait(self: ParentHandle, allocator: std.mem.Allocator) !CaptureResult {
        var output: std.ArrayListUnmanaged(u8) = .empty;
        defer output.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.read_fd, &buf) catch break;
            if (n == 0) break;
            try output.appendSlice(allocator, buf[0..n]);
        }
        std.posix.close(self.read_fd);

        // Wait for child
        var status: c_int = 0;
        _ = c.waitpid(self.child_pid, &status, 0);

        const exit_status: u8 = if (std.posix.W.IFEXITED(@bitCast(status)))
            std.posix.W.EXITSTATUS(@bitCast(status))
        else
            1;

        // Trim trailing newlines
        const trimmed = std.mem.trimRight(u8, output.items, "\n");
        const owned_output = try allocator.dupe(u8, trimmed);

        return CaptureResult{
            .output = owned_output,
            .status = exit_status,
        };
    }
};

/// Fork a child process with stdout and stderr redirected to a pipe.
///
/// Returns `.child` in the child process (stdout and stderr already redirected),
/// or `.parent` with a handle to read the output and wait.
///
/// Usage:
/// ```zig
/// switch (try process.forkWithPipe()) {
///     .child => {
///         // Run code that writes to stdout/stderr
///         const status = doWork();
///         std.posix.exit(status);
///     },
///     .parent => |handle| {
///         const result = try handle.readAndWait(allocator);
///         // result.output contains captured stdout and stderr
///         // result.status contains exit code
///     },
/// }
/// ```
pub fn forkWithPipe() !ForkResult {
    const pipe_fds = try std.posix.pipe();
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    const pid = try std.posix.fork();
    if (pid == 0) {
        // Child: redirect stdout and stderr to pipe
        std.posix.close(read_fd);
        std.posix.dup2(write_fd, std.posix.STDOUT_FILENO) catch std.posix.exit(1);
        std.posix.dup2(write_fd, std.posix.STDERR_FILENO) catch std.posix.exit(1);
        std.posix.close(write_fd);
        return .child;
    }

    // Parent: close write end, return handle for reading
    std.posix.close(write_fd);
    return .{ .parent = .{
        .read_fd = read_fd,
        .child_pid = pid,
    } };
}
