//! fg builtin - bring job to foreground
const builtins = @import("../builtins.zig");
const exec = @import("../../interpreter/execution/exec.zig");

pub const builtin = builtins.Builtin{
    .name = "fg",
    .run = run,
    .help = "Bring a job to the foreground",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const job_id = state.jobs.resolveJob(cmd.argv, "fg", false) orelse return 1;
    return exec.continueJobForeground(state, job_id);
}
