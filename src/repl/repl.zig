//! REPL: the interactive Read-Eval-Print Loop.
//!
//! Orchestrates the main interaction loop:
//! 1. Display prompt (with git branch, custom prompt function support)
//! 2. Read input via the line editor (with syntax highlighting, history, completion)
//! 3. Execute command via the interpreter
//! 4. Repeat until exit
//!
//! The REPL manages terminal mode transitions - raw mode for editing, cooked mode
//! for command execution - and handles history persistence between sessions.

const std = @import("std");

const lexer = @import("../language/lexer.zig");
const parser = @import("../language/parser.zig");
const expand = @import("../interpreter/expansion/word.zig");
const expansion = @import("../interpreter/expansion/statement.zig");
const State = @import("../runtime/state.zig").State;
const io = @import("../terminal/io.zig");
const ansi = @import("../terminal/ansi.zig");
const tui = @import("../terminal/tui.zig");
const prompt = @import("prompt.zig");
const Editor = @import("editor/editor.zig").Editor;

/// History file name stored in user's home directory.
const HISTORY_FILE = ".oshen_history";

/// Errors that can occur during command evaluation.
/// This is the union of all errors from the shell pipeline stages.
pub const EvalError = lexer.LexError || parser.ParseError || expand.ExpandError || expansion.ExpandError || std.posix.ExecveError || error{Unexpected};

/// Function signature for evaluating input.
/// Returns the exit status (0-255) of the executed command.
pub const EvalFn = *const fn (std.mem.Allocator, *State, []const u8) EvalError!u8;

/// Run the interactive REPL
pub fn run(allocator: std.mem.Allocator, state: *State, evalFn: EvalFn) !void {
    var editor = Editor.init(allocator);
    defer editor.deinit();

    // Enter raw mode immediately to prevent the kernel from echoing
    // any input that arrives before we're ready (e.g., commands sent
    // to the PTY by terminal multiplexers or workspace restore features)
    try editor.enableRawMode();

    // Set state for alias-aware highlighting
    editor.state = state;

    // History file path (owned copy for async saving)
    var history_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const history_path: ?[]const u8 = if (state.home) |home|
        std.fmt.bufPrint(&history_path_buf, "{s}/{s}", .{ home, HISTORY_FILE }) catch null
    else
        null;

    // Load the user's shell history
    if (history_path) |path| {
        editor.loadHistory(path);
    }

    var prompt_buf: [4096]u8 = undefined;

    while (true) {
        const prompt_str = prompt.build(allocator, state, &prompt_buf);

        // Emit OSC 7 right before readLine so any command sent in response
        // arrives when we're ready to receive it
        if (state.getCwd()) |cwd| {
            tui.emitOsc7(cwd);
        } else |_| {}

        const line = editor.readLine(prompt_str) catch |err| {
            io.printError("oshen: input error: {}\n", .{err});
            continue;
        } orelse {
            io.writeStdout("Goodbye!\n");
            break;
        };
        defer allocator.free(line);

        if (line.len == 0) continue;

        // Restore terminal to normal mode before executing command
        // (commands expect echo, line buffering, etc.)
        editor.restoreTerminal();

        // Execute the command
        _ = evalFn(allocator, state, line) catch |err| {
            io.printError("oshen: {}\n", .{err});
        };

        // Add to history with context (CWD and exit status)
        const cwd = state.getCwd() catch "";
        _ = editor.hist.add(.{
            .command = line,
            .cwd = cwd,
            .exit_status = state.status,
        });

        // Re-enable raw mode for the next prompt
        try editor.enableRawMode();

        // Save history after each command
        if (history_path) |path| {
            editor.saveHistory(path);
        }

        // Check if exit was requested
        if (state.should_exit) {
            break;
        }
    }
}
