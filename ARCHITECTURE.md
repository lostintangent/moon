# 🌊 Oshen Architecture

This document describes Oshen's internal architecture and execution flow.

## Table of Contents

- [Subsystems](#subsystems)
  - [Language](#1-language-srclanguage)
  - [Interpreter](#2-interpreter-srcinterpreter)
  - [Runtime](#3-runtime-srcruntime)
  - [REPL](#4-repl-srcrepl)
- [Execution Pipeline](#execution-pipeline)
  - [The Four Stages](#the-four-stages)
  - [Pipeline Diagram](#pipeline-diagram)
- [Process & Job Control](#process--job-control)
- [Key Design Decisions](#key-design-decisions)

---

## Subsystems

Oshen is organized into four subsystems, each in its own directory:

```
src/
├── language/          Syntax: lexer, parser, AST, tokens
├── interpreter/       Execution: expand then execute
│   ├── expansion/     "What to do": variable/glob/tilde expansion
│   └── execution/     "Do it": fork, exec, pipes, redirects
├── runtime/           State: variables, jobs, builtins
├── repl/              Interactive: line editing, prompts, history
└── terminal/          Terminal primitives: I/O, ANSI codes, raw mode
```

Data flows: **Language → Interpreter (Expansion → Execution) → Runtime**, with **REPL** wrapping everything for interactive use. **Terminal** provides shared primitives for the REPL and interactive builtins.

---

### 1. Language (`src/language/`)

The language subsystem converts source text into a structured AST. It knows nothing about execution — only syntax.

| File | Purpose |
|------|---------|
| `tokens.zig` | Token types, `WordPart` (word segments with quoting context), `TokenSpan` (source location with byte indices) |
| `lexer.zig` | Tokenization with quote/escape handling |
| `ast.zig` | AST node definitions (`Program`, `Statement`, `Pipeline`, `Command`) |
| `parser.zig` | Token stream → AST conversion |

**Lexer** handles:
- Quoted strings (single, double, with escape sequences)
- Operators (`|`, `>`, `>>`, `&&`, `||`, `;`)
- Word boundaries and whitespace
- Comments (`#`)

**Parser** recognizes:
- Pipelines (`cmd1 | cmd2`)
- Conditionals (`&&`, `||`, `and`, `or`)
- Control flow (`if`/`else if`/`else`/`for`/`while`/`fun` blocks with `end`)
- Loop control (`break`, `continue`)
- Function control (`return [status]`)
- Redirections (`>`, `>>`, `2>`, `&>`, `2>&1`)
- Command substitution (`$(...)`)
- Output capture (`=>`, `=>@`)
- Background execution (`&`)

**Important**: The parser treats words as opaque — it doesn't interpret `$`, `~`, `*`, or `[...]` inside them. A word like `$var[1]` is passed through as-is. Expansion syntax is handled later by the expander.

### 2. Interpreter (`src/interpreter/`)

The interpreter subsystem handles expansion and execution.

```
interpreter/
├── interpreter.zig        Orchestrates: lex → parse → expand → execute
├── expansion/             "What to do" — expand AST to executable form
│   ├── expansion.zig      AST + State → expanded execution data
│   ├── types.zig          Expanded type definitions (ExpandedCmd, ExpandedStmt, etc.)
│   ├── expand.zig         Variable, tilde, command substitution expansion
│   └── glob.zig           Glob pattern matching (*, **, ?, [abc], [a-z])
└── execution/             "Do it" — run the expanded commands
    ├── exec.zig           Process spawning, pipeline wiring, job control
    ├── capture.zig        Output capture for `=>`, `=>@`, and `$(...)`
    ├── redir.zig          File descriptor manipulation for redirections
    └── io.zig             stdout/stderr write utilities
```

#### Expansion (`expansion/`)

The expander takes an AST and shell state, then produces fully-resolved **expanded types**. This involves:

- **Expansion**: Variables (`$x`), globs (`*.txt`), tilde (`~`), command substitution (`$(...)`)
- **Resolution**: Converting AST nodes to concrete `ExpandedCmd`, `ExpandedStmt` structures

The result is pure data — no more parsing or variable lookups needed.

#### Execution (`execution/`)

The executor takes expanded types and makes them happen:

- **Process management**: `fork()`, `execvpe()`, process groups
- **Pipeline wiring**: Connecting commands with pipes
- **Redirections**: File descriptors for `>`, `>>`, `2>&1`, etc.
- **Job control**: Background jobs, foreground/background switching

**Key functions:**
```zig
// Execute oshen code from a string
interpreter.execute(allocator, state, code) !u8

// Execute oshen code from a file
interpreter.executeFile(allocator, state, path) !u8

// Execute oshen code and capture stdout (for command substitution, custom prompts)
interpreter.executeAndCapture(allocator, state, code) ![]const u8
```

---

### 3. Runtime (`src/runtime/`)

The runtime maintains shell state that persists across commands.

| File | Purpose |
|------|---------|
| `state.zig` | Central state: variables, exports, functions, cwd |
| `jobs.zig` | Job table: background/stopped process management |
| `builtins.zig` | Builtin command registry and dispatch |
| `builtins/*.zig` | Individual builtin implementations |

**State contains:**
- Shell variables (`set`) — list-valued, local to oshen
- Environment variables (`export`) — passed to child processes
- Aliases — command name expansions
- User-defined functions
- Job table for background/stopped processes
- Current working directory
- Exit status

**Builtins:**

| Command | Purpose |
|---------|---------|
| `alias` | Define command aliases |
| `bg` | Continue job in background |
| `cd` | Change directory |
| `echo` | Print arguments |
| `exit` | Exit the shell |
| `export` | Set environment variables |
| `false` | Return failure (exit 1) |
| `fg` | Bring job to foreground |
| `jobs` | List background jobs |
| `pwd` | Print working directory |
| `set` | Set shell variables |
| `source` | Execute a file |
| `true` | Return success (exit 0) |
| `type` | Show command type (alias/builtin/function/external) |
| `unalias` | Remove command aliases |
| `unset` | Remove shell variables |

Builtins run in the shell process by default for performance. However, if a builtin has redirections (e.g., `echo "x" > file`) or is part of a pipeline (e.g., `echo "x" | cat`), it runs in a forked child to properly isolate file descriptor changes.

---

### 4. REPL (`src/repl/`)

The REPL provides the interactive shell experience.

| File | Purpose |
|------|---------|
| `repl.zig` | Main read-eval-print loop |
| `prompt.zig` | Prompt generation (default or custom function) |
| `editor/editor.zig` | Line editing, cursor movement, key handling |
| `editor/history.zig` | Command history with file persistence |
| `editor/highlight.zig` | Real-time syntax highlighting |
| `editor/suggest.zig` | Autosuggestions from history |

**REPL loop:**
```zig
while (true) {
    const prompt_str = prompt.build(allocator, state, &buf);
    const line = editor.readLine(prompt_str);
    const status = execute(allocator, state, line);
    state.status = status;
}
```

**Key features:**

| Feature | Implementation |
|---------|----------------|
| Syntax highlighting | Real-time coloring as you type |
| Autosuggestions | Dimmed history completions |
| History search | `Ctrl+R` reverse incremental search |
| Custom prompt | User-defined `prompt` function (stdout captured) |
| Line editing | Emacs-style keybindings |

### 5. Terminal (`src/terminal/`)

Shared primitives for terminal interaction, used by both the REPL and interactive builtins.

| File | Purpose |
|------|---------|
| `io.zig` | Output helpers (writeStdout, printError, etc.) |
| `ansi.zig` | ANSI color codes, text styling, cursor movement, display length |
| `tui.zig` | Raw mode, key reading, and interactive terminal features |

When oshen processes input, it goes through four stages:

#### 1. Lexer

Converts raw text into tokens:

```
"echo $name *.txt"  →  [word:"echo"] [word:"$name"] [word:"*.txt"]
```

#### 2. Parser

Builds an Abstract Syntax Tree from tokens:

```
Program
└── Statement (command)
    └── Pipeline
        ├── Command: [echo, $name, *.txt]
        └── Redirections: []
```

#### 3. Expander

The expander takes an AST and produces fully-resolved execution data. As it processes each command, it resolves word contents.

The expander is a **second parsing layer** that interprets expansion syntax within words. While the structural parser handles command grammar, the expander has its own mini-parser for:

```
$var        → parse identifier characters
${var}      → parse until closing }
$var[1]     → parse identifier, then parse [...]
$(cmd)      → parse until matching )
$1, $#, $*  → single special character
~           → tilde at word start
*.txt       → glob metacharacters
```

Expansion results:

```
$name     →  ["Alice"]           (from state.variables)
$1        →  ["arg1"]            (positional parameter)
$#        →  ["3"]               (argument count)
$*        →  ["a", "b", "c"]     (all arguments)
$xs[1]    →  ["first"]           (array index, 1-based)
$xs[-1]   →  ["last"]            (negative index from end)
$xs[2..4] →  ["b", "c", "d"]     (array slice, inclusive)
*.txt     →  ["a.txt", "b.txt"]  (from filesystem)
**/*.zig  →  ["src/main.zig", "src/lib/util.zig"]  (recursive glob)
[a-z].md  →  ["a.md", "b.md"]    (character class glob)
$(whoami) →  ["alice"]           (from subprocess)
~         →  ["/home/alice"]     (from $HOME)
```

**List expansion**: A variable holding `["a", "b"]` expands to two separate arguments, not one string with spaces.

The expander combines AST structure with expanded values to produce:

```zig
ExpandedCmd {
    .argv = ["echo", "Alice", "a.txt", "b.txt"],
    .env = [],
    .redirs = [],
}
```

The result is pure data — no more parsing or variable lookups needed.

#### 4. Executor

Spawns processes, wires pipes, handles redirections:

```
fork() → child: exec("echo", args)
       → parent: wait for exit status
```

---

### Pipeline Diagram

**Key insight**: Parse once, but expand/execute each statement individually. This allows `set x 1; echo $x` to work — the variable is set before `$x` is expanded.

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Input: "set x 1; echo $x"                        │
└─────────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    │    LANGUAGE SUBSYSTEM │
                    │      Lex → Parse      │
                    └───────────┬───────────┘
                                │
                    ┌───────────┴───────────┐
                    │         AST           │
                    │  [Statement, Statement]│
                    └───────────┬───────────┘
                                │
              ┌─────────────────┼─────────────────┐
              │                                   │
              ▼                                   ▼
     ┌─────────────────┐                ┌─────────────────┐
     │   Statement 1   │                │   Statement 2   │
     │   "set x 1"     │                │   "echo $x"     │
     └────────┬────────┘                └────────┬────────┘
              │                                   │
              ▼                                   │
     ┌─────────────────┐                          │
     │   INTERPRETER   │                          │
     │     Expand      │                          │
     └────────┬────────┘                          │
              │                                   │
              ▼                                   │
     ┌─────────────────┐                          │
     │    RUNTIME      │                          │
     │ state.x = "1"   │  ← Variable now exists   │
     └────────┬────────┘                          │
              │                                   │
              └──────────── NEXT ─────────────────┘
                                                  │
                                                  ▼
                                         ┌─────────────────┐
                                         │   INTERPRETER   │
                                         │ $x → "1"        │
                                         └────────┬────────┘
                                                  │
                                                  ▼
                                         ┌─────────────────┐
                                         │    RUNTIME      │
                                         │ exec: echo "1"  │
                                         └─────────────────┘
```

---

## Process & Job Control

Oshen spawns external processes via `fork()` + `exec()`. Each pipeline runs in its own process group for proper job control.

### When Processes Are Spawned

| Scenario | What Happens |
|----------|--------------|
| Simple command (`ls`) | Fork, exec in child, parent waits |
| Pipeline (`ls \| grep`) | Fork per command, wire pipes, wait for all |
| Background (`sleep &`) | Fork, don't wait, add to job table |
| Builtin (`cd`, `set`) | No fork — runs in shell process |
| Builtin with redirect (`echo > file`) | Fork to apply redirects, then run builtin |
| Builtin in pipeline (`echo \| cat`) | Fork (required for pipe wiring) |
| Command substitution (`$(cmd)`) | Fork, capture stdout, wait |

**Builtin execution model**: Builtins run in-process for performance when possible. However, redirections and pipelines require file descriptor manipulation that shouldn't affect the parent shell, so builtins fork in those cases. Even when forked, builtins run their native implementation (not via `exec`) — this ensures they have access to shell state like the job table:

```
echo "hello"           →  In-process (fast path)
cd /tmp                →  In-process (must affect parent)
set x y                →  In-process (must affect parent state)
echo "hello" > file    →  Fork, run builtin, exit (redirect needs isolated fd table)
echo "hello" | cat     →  Fork, run builtin, exit (pipe needs connected fd)
jobs | grep sleep      →  Fork, run builtin with shell state access, exit
```

This ensures common cases like `cd`, `set`, and simple `echo` remain fast, while redirects and pipelines work correctly.

### Job Table

Background and stopped processes are tracked in a job table:

```zig
Job {
    id: u16,           // Job number ([1], [2], etc.)
    pgid: pid_t,       // Process group ID
    pids: []pid_t,     // All PIDs in the pipeline
    cmd: []const u8,   // Original command string
    status: JobStatus, // running, stopped, done
}
```

### Foreground vs Background

```
┌──────────────────────────────────────────────────────────────────┐
│                          Terminal                                │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │              Foreground Process Group                      │  │
│  │  • Receives keyboard input (stdin)                         │  │
│  │  • Receives Ctrl+C (SIGINT), Ctrl+Z (SIGTSTP)              │  │
│  │  • Only ONE at a time                                      │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │             Background Process Groups                      │  │
│  │  • No terminal input                                       │  │
│  │  • Continue running while shell prompts                    │  │
│  │  • ZERO or more at a time                                  │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### Signal Handling

| Signal | Trigger | Action |
|--------|---------|--------|
| `SIGCHLD` | Child exits/stops | Reap child, update job status |
| `SIGINT` | Ctrl+C | Kill foreground job |
| `SIGTSTP` | Ctrl+Z | Stop foreground job, add to job table |
| `SIGCONT` | `fg`/`bg` | Resume stopped job |

### Job Control Flow

```
User: sleep 30 &
         │
         ▼
    ┌─────────┐
    │  fork() │
    └────┬────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
  Parent    Child
    │         │
    │    setpgid(0,0)  ← New process group
    │         │
    │    exec("sleep")
    │
Add to job table
    │
Print [1] 12345
    │
Return to prompt (child runs in background)
```

---

## Key Design Decisions

### 1. Statement-by-Statement Execution

Parse all statements upfront, but expand/execute one at a time:

```zig
for (ast.statements) |stmt| {
    var ctx = ExpandContext.init(allocator, state);
    const expanded = try expandStmt(allocator, &ctx, stmt);
    _ = try executeStatement(allocator, state, expanded, input);
}
```

This ensures side effects are visible to subsequent statements.

### 2. List Variables

Variables are arrays, not strings:

```zig
// state.variables["files"] = ["a.txt", "b.txt", "c.txt"]
// $files expands to 3 separate arguments, not "a.txt b.txt c.txt"
```

No word-splitting surprises.

### 3. Separation of AST and Expanded Types

- **AST** = syntactic structure (what the user wrote)
- **Expanded** = resolved execution intent (what to actually do)

This keeps expansion logic isolated and testable.

### 4. Arena Allocation Per Command

Each command gets its own arena allocator:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();  // Free everything at once
```

Simple, fast, no leaks.

### 5. Control Flow via Body Strings

`if`, `for`, `while`, and `fun` store their bodies as strings:

```zig
// For-loop body stored as string
ExpandedStmt {
    .kind = .for_loop: ast.ForLoop {
        .var_name = "x",
        .items = &.{"a", "b", "c"},
        .body = "echo $x",
    }
}

// If-statement with branches for if/else-if chains
ExpandedStmt {
    .kind = .if_stmt: ast.IfStmt {
        .branches = &.{
            .{ .condition = "test $x -lt 10", .body = "echo small" },
            .{ .condition = "test $x -lt 100", .body = "echo large" },
        },
        .else_body = "echo huge",
    }
}
```

Bodies are re-parsed and executed via `interpreter.execute()`. This creates a natural recursion boundary and keeps the expander simple.

### 6. Loop Control and Return via State Flags

`break`, `continue`, and `return` use state flags to communicate with loop/function executors:

```zig
// In state.zig
loop_break: bool = false,
loop_continue: bool = false,
fn_return: bool = false,

// In execution:
// 1. break_stmt sets state.loop_break = true
// 2. Loop executor checks flag after each iteration/statement
// 3. Flag is reset at end of loop iteration (continue) or loop exit (break)
// 4. return_stmt sets state.fn_return = true and state.status
// 5. Function executor checks fn_return and resets it after function completes
```

This propagation model allows break/continue/return to work correctly even when nested inside `if` statements within a loop or function body.

### 7. Two-Layer Parsing

Oshen separates **structural parsing** from **expansion parsing**:

| Layer | Location | Handles |
|-------|----------|--------|
| Structural | `parser.zig` | Commands, pipelines, control flow, redirections |
| Expansion | `expansion/expand.zig` | `$var`, `$var[n]`, `~`, `*`, `$(...)` inside words |

The structural parser treats words as opaque text — it doesn't know about variables or globs. The expander interprets the content of each word segment.

**Why this design?**

1. **Simpler grammar**: The shell grammar doesn't need rules for every expansion feature
2. **Easy to extend**: Adding `$var[1..2]` indexing required zero parser changes
3. **Testable**: Expansion logic can be unit-tested independently of parsing
4. **Quote-aware**: The expander knows which segments were quoted, enabling proper suppression of expansion in single quotes

The alternative — tokenizing `$var[1]` as `VAR_REF` + `INDEX` — would tightly couple the grammar to expansion rules and require parser changes for every new feature.
