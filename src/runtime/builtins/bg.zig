//! bg builtin - continue job in background
const builtins = @import("../builtins.zig");
const exec = @import("../../interpreter/execution/exec.zig");

pub const builtin = builtins.Builtin{
    .name = "bg",
    .run = run,
    .help = "Continue a stopped job in the background",
};

fn run(state: *builtins.State, cmd: builtins.ExpandedCmd) u8 {
    const job_id = state.jobs.resolveJob(cmd.argv, "bg", true) orelse return 1;
    return exec.continueJobBackground(state, job_id);
}
