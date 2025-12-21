//! Job control: background and stopped job management
//!
//! Manages the lifecycle of background (&) and stopped (Ctrl-Z) jobs.
//! Jobs are tracked in a fixed-size table with unique IDs.

const std = @import("std");
const io = @import("../terminal/io.zig");

/// Job status
pub const JobStatus = enum {
    running,
    stopped,
    done,

    pub fn str(self: JobStatus) []const u8 {
        return switch (self) {
            .running => "Running",
            .stopped => "Stopped",
            .done => "Done",
        };
    }
};

/// A background or stopped job
pub const Job = struct {
    id: u16,
    pgid: std.posix.pid_t,
    pids: []std.posix.pid_t,
    cmd: []const u8,
    status: JobStatus,
};

/// Maximum number of concurrent jobs.
/// This limit prevents unbounded memory growth while supporting typical
/// interactive usage (most users have fewer than 10 concurrent jobs).
const MAX_JOBS = 64;

/// Job table for managing background and stopped jobs
pub const JobTable = struct {
    allocator: std.mem.Allocator,
    jobs: [MAX_JOBS]?Job = [_]?Job{null} ** MAX_JOBS,
    next_id: u16 = 1,

    pub fn init(allocator: std.mem.Allocator) JobTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *JobTable) void {
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                self.allocator.free(job.pids);
                self.allocator.free(job.cmd);
                slot.* = null;
            }
        }
    }

    /// Add a new job to the table
    pub fn add(self: *JobTable, pgid: std.posix.pid_t, pids: []const std.posix.pid_t, cmd: []const u8, status: JobStatus) !u16 {
        // Find empty slot
        var slot_idx: ?usize = null;
        for (self.jobs, 0..) |job, i| {
            if (job == null) {
                slot_idx = i;
                break;
            }
        }

        const idx = slot_idx orelse return error.TooManyJobs;

        // Copy pids
        const pids_copy = try self.allocator.alloc(std.posix.pid_t, pids.len);
        @memcpy(pids_copy, pids);

        // Copy command string
        const cmd_copy = try self.allocator.dupe(u8, cmd);

        const job_id = self.next_id;
        // Increment with wraparound. Job ID 0 is reserved/invalid,
        // so we skip it when wrapping from max u16 back to 1.
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        self.jobs[idx] = Job{
            .id = job_id,
            .pgid = pgid,
            .pids = pids_copy,
            .cmd = cmd_copy,
            .status = status,
        };

        return job_id;
    }

    /// Get a job by ID
    pub fn get(self: *JobTable, job_id: u16) ?*Job {
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                if (job.id == job_id) return job;
            }
        }
        return null;
    }

    /// Get the most recent job (highest ID)
    pub fn getMostRecent(self: *JobTable) ?*Job {
        var best: ?*Job = null;
        var best_id: u16 = 0;
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                if (job.id >= best_id) {
                    best_id = job.id;
                    best = job;
                }
            }
        }
        return best;
    }

    /// Remove a job from the table
    pub fn remove(self: *JobTable, job_id: u16) void {
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                if (job.id == job_id) {
                    self.allocator.free(job.pids);
                    self.allocator.free(job.cmd);
                    slot.* = null;
                    return;
                }
            }
        }
    }

    /// Update job status based on waitpid results
    pub fn updateStatus(self: *JobTable, pid: std.posix.pid_t, wait_status: u32) void {
        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                for (job.pids) |job_pid| {
                    if (job_pid == pid) {
                        if (std.posix.W.IFSTOPPED(wait_status)) {
                            job.status = .stopped;
                        } else {
                            // Process exited or was killed
                            job.status = .done;
                        }
                        return;
                    }
                }
            }
        }
    }

    /// Count active (non-done) jobs
    pub fn countActive(self: *JobTable) usize {
        var count: usize = 0;
        for (self.jobs) |slot| {
            if (slot) |job| {
                if (job.status != .done) count += 1;
            }
        }
        return count;
    }

    /// Iterate over all jobs
    pub fn iter(self: *JobTable) Iterator {
        return .{ .jobs = &self.jobs, .index = 0 };
    }

    pub const Iterator = struct {
        jobs: *[MAX_JOBS]?Job,
        index: usize,

        pub fn next(self: *Iterator) ?*Job {
            while (self.index < MAX_JOBS) {
                const i = self.index;
                self.index += 1;
                if (self.jobs[i]) |*job| {
                    return job;
                }
            }
            return null;
        }
    };

    /// Resolve a job ID from command arguments, or default to the most recent job
    pub fn resolveJob(self: *JobTable, argv: []const []const u8, comptime cmd_name: []const u8, stopped_only: bool) ?u16 {
        if (argv.len < 2) {
            // No argument - use most recent (optionally stopped) job
            if (stopped_only) {
                var iterator = self.iter();
                var best: ?*Job = null;
                while (iterator.next()) |job| {
                    if (job.status == .stopped) {
                        if (best == null or job.id > best.?.id) {
                            best = job;
                        }
                    }
                }
                if (best) |job| return job.id;
            } else {
                if (self.getMostRecent()) |job| return job.id;
            }
            io.printError("oshen: " ++ cmd_name ++ ": no current job\n", .{});
            return null;
        }

        const arg = argv[1];
        return std.fmt.parseInt(u16, arg, 10) catch {
            io.printError("oshen: " ++ cmd_name ++ ": {s}: invalid job ID\n", .{arg});
            return null;
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "job table: add and get job" {
    var table = JobTable.init(testing.allocator);
    defer table.deinit();

    const pids = [_]std.posix.pid_t{1234};
    const job_id = try table.add(1234, &pids, "sleep 10 &", .running);

    try testing.expectEqual(@as(u16, 1), job_id);

    const job = table.get(job_id).?;
    try testing.expectEqual(@as(u16, 1), job.id);
    try testing.expectEqual(@as(std.posix.pid_t, 1234), job.pgid);
    try testing.expectEqualStrings("sleep 10 &", job.cmd);
    try testing.expectEqual(JobStatus.running, job.status);
}

test "job table: get nonexistent job returns null" {
    var table = JobTable.init(testing.allocator);
    defer table.deinit();

    try testing.expectEqual(@as(?*Job, null), table.get(999));
}

test "job table: remove job" {
    var table = JobTable.init(testing.allocator);
    defer table.deinit();

    const pids = [_]std.posix.pid_t{1234};
    const job_id = try table.add(1234, &pids, "sleep 10", .running);

    try testing.expect(table.get(job_id) != null);

    table.remove(job_id);

    try testing.expectEqual(@as(?*Job, null), table.get(job_id));
}

test "job table: getMostRecent" {
    var table = JobTable.init(testing.allocator);
    defer table.deinit();

    const pids1 = [_]std.posix.pid_t{1000};
    const pids2 = [_]std.posix.pid_t{2000};
    const pids3 = [_]std.posix.pid_t{3000};

    _ = try table.add(1000, &pids1, "job1", .running);
    _ = try table.add(2000, &pids2, "job2", .running);
    const job3_id = try table.add(3000, &pids3, "job3", .stopped);

    const most_recent = table.getMostRecent().?;
    try testing.expectEqual(job3_id, most_recent.id);
}

test "job table: iterate jobs" {
    var table = JobTable.init(testing.allocator);
    defer table.deinit();

    const pids1 = [_]std.posix.pid_t{100};
    const pids2 = [_]std.posix.pid_t{200};

    _ = try table.add(100, &pids1, "cmd1", .running);
    _ = try table.add(200, &pids2, "cmd2", .stopped);

    var count: usize = 0;
    var iterator = table.iter();
    while (iterator.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 2), count);
}

test "job table: countActive" {
    var table = JobTable.init(testing.allocator);
    defer table.deinit();

    const pids1 = [_]std.posix.pid_t{100};
    const pids2 = [_]std.posix.pid_t{200};
    const pids3 = [_]std.posix.pid_t{300};

    _ = try table.add(100, &pids1, "cmd1", .running);
    _ = try table.add(200, &pids2, "cmd2", .stopped);
    _ = try table.add(300, &pids3, "cmd3", .done);

    // Only running and stopped are "active"
    try testing.expectEqual(@as(usize, 2), table.countActive());
}

test "job table: updateStatus" {
    var table = JobTable.init(testing.allocator);
    defer table.deinit();

    const pids = [_]std.posix.pid_t{1234};
    const job_id = try table.add(1234, &pids, "sleep", .running);

    // Simulate process exit (WIFEXITED status)
    const exit_status: u32 = 0; // Normal exit
    table.updateStatus(1234, exit_status);

    const job = table.get(job_id).?;
    try testing.expectEqual(JobStatus.done, job.status);
}
