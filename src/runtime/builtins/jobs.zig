//! jobs builtin - list background/stopped jobs
const builtins = @import("../builtins.zig");

pub const builtin = builtins.Builtin{
    .name = "jobs",
    .run = run,
    .help = "List background and stopped jobs",
};

fn run(state: *builtins.State, _: builtins.ExpandedCmd) u8 {
    var iter = state.jobs.iter();
    while (iter.next()) |job| {
        const marker: u8 = if (job.status == .running) '+' else '-';
        builtins.io.printStdout("[{d}]{c}  {s}                 {s}\n", .{ job.id, marker, job.status.str(), job.cmd });
    }
    return 0;
}
