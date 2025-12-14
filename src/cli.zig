const std = @import("std");
const build_options = @import("build_options");

pub const RunMode = union(enum) {
    interactive,
    command: []const u8,
    script: []const u8,
};

pub const Options = struct {
    mode: RunMode = .interactive,
    is_login: bool = false,
};

pub const ParseError = error{
    MissingCommandArg,
    UnknownOption,
};

pub fn parseArgs(args: []const []const u8) ParseError!?Options {
    var opts = Options{};
    var i: usize = 1; // skip program name

    // Check if invoked as login shell (argv[0] starts with '-')
    if (args.len > 0 and args[0].len > 0 and args[0][0] == '-') {
        opts.is_login = true;
    }

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return null;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            printVersion();
            return null;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--login")) {
            opts.is_login = true;
        } else if (std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) {
                return error.MissingCommandArg;
            }
            opts.mode = .{ .command = args[i] };
        } else if (std.mem.eql(u8, arg, "-i")) {
            opts.mode = .interactive;
        } else if (arg.len > 0 and arg[0] == '-') {
            return error.UnknownOption;
        } else {
            // Treat as script file
            opts.mode = .{ .script = arg };
        }
    }

    return opts;
}

fn printHelp() void {
    const help = "\n🌊  Oshen (v" ++ build_options.version ++ ")" ++
        \\
        \\
        \\Usage: oshen [options] [script]
        \\
        \\Options:
        \\  -c <command>    Execute command and exit
        \\  -i              Force interactive mode
        \\  -l, --login     Run as a login shell
        \\  -h, --help      Show this help message
        \\  -v, --version   Show version information
        \\
        \\Examples:
        \\  oshen                    Start interactive REPL
        \\  oshen -c "echo hello"    Run a single command
        \\  oshen script.oshen        Execute a script file
        \\ 
    ;
    _ = std.posix.write(std.posix.STDOUT_FILENO, help) catch {};
}

fn printVersion() void {
    const version = build_options.version ++ "\n";
    _ = std.posix.write(std.posix.STDOUT_FILENO, version) catch {};
}
