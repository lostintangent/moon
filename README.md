# 🌊 Oshen

A terminal shell that's optimized for fun, yet powerful enough to be a daily driver.

Oshen ships with the features developers expect out of the box: syntax highlighting, autosuggestions, and tab completions. Variables are lists, syntax is clean, and there's no surprise word-splitting.

---

> [!WARNING] 
> I built Oshen entirely for myself. And while it's capable enough to be a daily driver, its major limitation is a lack of integration with other tools that don't "speak" Oshen script (e.g. Homebrew, NVM, VS Code, etc.). Therefore, before I'd recommend anyone use this, I probably need to support a subset of Bash/Zsh/Fish, to allow Oshen to inherit existing support from tools.

## Installation

### macOS (Homebrew)

```sh
brew tap lostintangent/oshen https://github.com/lostintangent/oshen
brew install lostintangent/oshen/oshen
```

### Linux

Download the latest release:

```sh
curl -LO https://github.com/lostintangent/oshen/releases/latest/download/oshen-linux-x86_64.tar.gz
tar -xzf oshen-linux-x86_64.tar.gz
sudo mv oshen /usr/local/bin/
```

### Set as Default Shell (Seriously, don't do this)

```sh
# Add to /etc/shells
echo "$(which oshen)" | sudo tee -a /etc/shells

# Change your default shell
chsh -s $(which oshen)
```

---

## Quick Start

```sh
# Run interactive shell
oshen

# Run a command
oshen -c "echo hello world"

# Run a script
oshen script.wave
```

---

### Interactive Shell

- [Syntax Highlighting](#syntax-highlighting)
- [Autosuggestions](#autosuggestions)
- [Tab Completion](#tab-completion)
- [Line Editing](#line-editing)
- [History](#history)
- [Configuration](#configuration)

### Core Language

- [Variables](#variables)
- [Environment Variables](#environment-variables)
- [Quoting & Escaping](#quoting--escaping)
- [Comments](#comments)

### Control Flow

- [If Statements](#if-statements)
- [For Loops](#for-loops)
- [While Loops](#while-loops)
- [Conditional Chaining](#conditional-chaining)
- [Functions](#functions)

### Commands & I/O

- [Pipelines](#pipelines)
- [Redirections](#redirections)
- [Output Capture](#output-capture)
- [Command Substitution](#command-substitution)
- [Job Control](#job-control)
- [Glob Patterns](#glob-patterns)

### Reference

- [Builtins](#builtins)
- [Command Line Options](#command-line-options)

---

# Interactive Shell

Oshen's interactive mode provides a modern editing experience out of the box—no plugins or configuration required.

## Syntax Highlighting

Commands, strings, operators, and variables are color-coded as you type:

- **Commands** — Valid commands (builtins and executables) shown in blue
- **Invalid commands** — Unknown commands shown in red
- **Strings** — Single and double-quoted strings in green
- **Variables** — `$var` expansions highlighted distinctly
- **Operators** — Pipes, redirections, and logical operators in cyan
- **Comments** — Dimmed gray

Highlighting updates in real-time as you edit, giving instant feedback on syntax errors.

## Autosuggestions

As you type, Oshen shows suggestions from your command history in dimmed text:

```shell
$ git com                           # You type this
$ git commit -m "Update docs"       # Suggestion appears dimmed
```

- Press **→** or **End** to accept the full suggestion
- Press **Alt+→** to accept word-by-word
- Continue typing to refine or ignore

Suggestions match against your history, preferring recent and frequently-used commands.

## Tab Completion

Press **Tab** to complete commands and paths:

### Command Completion

At the start of a line, Tab completes from:
- All builtin commands (`cd`, `set`, `export`, etc.)
- Executables found in your `$PATH`

```shell
$ ec<Tab>        →  $ echo
$ gi<Tab>        →  $ git
```

### Path Completion

In argument positions (or when the word contains `/`, `.`, or `~`), Tab completes file and directory paths:

```shell
$ cat ~/Doc<Tab>      →  $ cat ~/Documents/
$ ls src/*.z<Tab>     →  $ ls src/main.zig
```

- Directories get a trailing `/` automatically
- Hidden files (starting with `.`) are shown only when the prefix starts with `.`

### Multiple Matches

When multiple completions exist, Tab inserts the common prefix. Press Tab again to see all options.

## Line Editing

Oshen provides Emacs-style line editing keybindings:

| Key | Action |
|-----|--------|
| **←** / **→** | Move cursor left/right |
| **Ctrl+A** / **Home** | Move to beginning of line |
| **Ctrl+E** / **End** | Move to end of line |
| **Ctrl+W** | Delete word before cursor |
| **Ctrl+U** | Delete from cursor to beginning |
| **Ctrl+K** | Delete from cursor to end |
| **Backspace** | Delete character before cursor |
| **Delete** | Delete character at cursor |
| **Ctrl+L** | Clear screen |
| **Ctrl+C** | Cancel current line |
| **Ctrl+D** | Exit shell (on empty line) |

## History

Command history is automatically saved to `~/.oshen_log` and persists across sessions.

| Key | Action |
|-----|--------|
| **↑** / **Ctrl+P** | Previous command in history |
| **↓** / **Ctrl+N** | Next command in history |
| **Ctrl+R** | Reverse incremental search |

### History Search

Press **Ctrl+R** to search your command history as you type:

```shell
(reverse-i-search)`git': git commit -m "Update docs"
```

- Type to filter history entries
- Press **Ctrl+R** again to find the next match
- Press **Enter** to execute the matched command
- Press **Esc** or **Ctrl+G** to cancel

History features:
- Commands are saved as you enter them
- Duplicate consecutive commands are not added
- History file is loaded on startup and saved on exit

## Configuration

Oshen loads `~/.oshen_floor` for every interactive shell. Like fish, there's no separate "profile" vs "rc" file—just one config that runs each time.

### Example Configuration

```sh
# ~/.oshen_floor

# Homebrew (macOS)
export HOMEBREW_PREFIX "/opt/homebrew"
export HOMEBREW_CELLAR "/opt/homebrew/Cellar"
export HOMEBREW_REPOSITORY "/opt/homebrew"
path_prepend PATH /opt/homebrew/bin /opt/homebrew/sbin

# Node.js (nvm)
export NVM_DIR "$HOME/.nvm"
path_prepend PATH $NVM_DIR/versions/node/v22.17.1/bin

# Other tools
path_prepend PATH $HOME/.local/bin $HOME/bin

# Aliases
alias ll 'ls -la'
alias gs 'git status'
alias gp 'git push'

# Shell variables
var EDITOR vim
var PAGER less

# Custom functions
fun mkcd
    mkdir -p $1 && cd $1
end
```

### path_prepend

The `path_prepend` builtin adds paths to a variable while **deduplicating**—safe to run on every shell without duplicating entries:

```sh
path_prepend PATH /opt/homebrew/bin /opt/homebrew/sbin
path_prepend MANPATH /opt/homebrew/share/man
```

### Custom Prompt

The default prompt shows your current directory in green, and if you're in a git repository, the current branch in magenta:

```
~/projects/oshen (main) #
```

To customize this, define a function named `prompt`. The function's stdout becomes the prompt string:

```sh
# Simple custom prompt
fun prompt
    echo "oshen > "
end

# Show git branch
fun prompt
    var branch $(git branch --show-current 2>/dev/null)
    if test -n "$branch"
        echo "[$branch] $ "
    else
        echo "$ "
    end
end

# Colorful prompt with path
fun prompt
    echo "\e[32m$(pwd -t)\e[0m # "
end
```

---

# Core Language

## Variables

Use `var` to create shell variables:

```sh
var name "Alice"
var colors red green blue    # List with multiple values

echo $name                   # Alice
echo $colors                 # red green blue
```

### Variable Expansion

```sh
var greeting hello
echo $greeting               # Simple: hello
echo ${greeting}             # Braced: hello
echo "$greeting world"       # In double quotes: hello world
echo '$greeting'             # Single quotes: literal $greeting
```

### List Variables

Variables in Oshen are **lists by default**:

```sh
var files a.txt b.txt c.txt

# Each item becomes a separate argument
echo $files                  # Equivalent to: echo a.txt b.txt c.txt

# Prefix/suffix applies to each item (cartesian product)
echo test_$files             # test_a.txt test_b.txt test_c.txt
```

### Array Indexing

Access individual elements or slices of a list using bracket notation. Indices are **1-based**, and negative indices count from the end:

```sh
var colors red green blue yellow

echo $colors[1]              # red (first element)
echo $colors[2]              # green
echo $colors[-1]             # yellow (last element)
echo $colors[-2]             # blue (second-to-last)
```

#### Slicing

Use `..` to extract a range of elements (both bounds inclusive):

```sh
var nums a b c d e

echo $nums[2..4]             # b c d
echo $nums[3..]              # c d e (from index 3 to end)
echo $nums[..2]              # a b (from start to index 2)
echo $nums[-2..-1]           # d e (last two elements)
```

#### With argv

Commonly used to access function arguments:

```sh
fun greet
    echo "Hello, $argv[1]!"
    echo "Remaining args: $argv[2..]"
end

greet Alice Bob Carol
# Hello, Alice!
# Remaining args: Bob Carol
```

| Syntax | Description |
|--------|-------------|
| `$var[n]` | Element at index n (1-based) |
| `$var[-n]` | Element n from the end |
| `$var[a..b]` | Elements from a to b (inclusive) |
| `$var[n..]` | Elements from n to end |
| `$var[..n]` | Elements from start to n |

### Special Expansions

```sh
~                            # Home directory
~/projects                   # Home + path
$?                           # Last exit status
$status                      # Same as $?
```

### Positional Parameters

Inside functions, access arguments by position:

```sh
fun greet
    echo "Hello, $1!"       # First argument
    echo "You said: $2"     # Second argument
    echo "All args: $*"     # All arguments
    echo "Count: $#"        # Number of arguments
end

greet Alice "good morning"
# Hello, Alice!
# You said: good morning
# All args: Alice good morning
# Count: 2
```

| Variable | Description |
|----------|-------------|
| `$1`-`$9` | Positional arguments |
| `$#` | Argument count |
| `$*` | All arguments (as separate words) |
| `$argv` | All arguments (as a list) |

---

## Environment Variables

Use `export` to make variables available to child processes:

```sh
export PATH "$HOME/bin:$PATH"
export EDITOR vim

# Or use = syntax
export EDITOR=vim

# Export an existing shell variable
var MY_VAR value
export MY_VAR
```

---

## Quoting & Escaping

### Single Quotes — Literal

```sh
echo 'No $expansion here'    # No $expansion here
echo 'Preserves "quotes"'    # Preserves "quotes"
```

### Double Quotes — Interpolated

```sh
set name Alice
echo "Hello, $name"          # Hello, Alice
echo "Tab:\there"            # Tab:    here
```

Supported escapes: `\n`, `\t`, `\\`, `\"`, `\$`

### Backslash Escaping

```sh
echo \$literal               # $literal
echo hello\ world            # hello world (single argument)
```

---

## Comments

```sh
# This is a comment
echo hello  # inline comment
```

---

# Control Flow

## If Statements

```sh
if test -f config.txt
    echo "Config found"
else
    echo "No config"
end

# Inline form
if test $x -eq 0; echo "zero"; end
```

The condition is any command — exit status 0 means true.

### Else If Chains

Use `else if` to chain multiple conditions:

```sh
var x 15

if test $x -lt 10
    echo "small"
else if test $x -lt 20
    echo "medium"
else if test $x -lt 100
    echo "large"
else
    echo "huge"
end
```

Only the first matching branch executes. The final `else` is optional.

---

## For Loops

Iterate over items:

```sh
for file in *.txt
    echo "Processing $file"
end

# Loop over a variable list
var names Alice Bob Carol
for name in $names
    echo "Hello, $name"
end

# Inline form
for x in a b c; echo $x; end
```

---

## While Loops

Repeat while a condition is true:

```sh
var count 5
while test $count -gt 0
    echo "Countdown: $count"
    var count (math $count - 1)
end

# Wait for a file to appear
while test ! -f ready.txt
    echo "Waiting..."
    sleep 1
end

# Inline form
while true; echo "loop"; end
```

The condition is any command — exit status 0 means continue.

---

## Break and Continue

Control loop execution with `break` and `continue`:

### Break

Exit the loop immediately:

```sh
for i in 1 2 3 4 5
    echo $i
    if test $i -eq 3
        break
    end
end
# Output: 1 2 3
```

### Continue

Skip the rest of the current iteration and continue with the next:

```sh
for i in 1 2 3 4 5
    if test $i -eq 3
        continue
    end
    echo $i
end
# Output: 1 2 4 5
```

Both `break` and `continue` work in `for` and `while` loops.

---

## Conditional Chaining

```sh
test -f file.txt && echo "exists"
test -f file.txt || echo "missing"

# Word forms
test -f file.txt and echo "exists"
test -f file.txt or  echo "missing"
```

---

## Functions

Define reusable commands:

```sh
fun greet
    echo "Hello, $argv[1]!"
end

greet Alice                  # Hello, Alice!

# Inline definition
fun hi echo "Hi there" end
```

Functions receive arguments in `$argv`. Use `return` to exit early with a status code (or omit the argument to use the last command's status):

```sh
fun check_file
    if test ! -f $1
        return 1
    end
    cat $1
end
```

---

# Commands & I/O

## Pipelines

```sh
cat file.txt | grep error | wc -l

# Alternative syntax (reads like data flow)
cat file.txt |> grep error |> wc -l
```

---

## Redirections

### Output Redirection

| Operator | Description |
|----------|-------------|
| `>`      | Write stdout (truncate) |
| `>>`     | Write stdout (append) |
| `2>`     | Write stderr (truncate) |
| `2>>`    | Write stderr (append) |
| `&>`     | Write both stdout and stderr |
| `2>&1`   | Redirect stderr to stdout |

### Input Redirection

```sh
sort < unsorted.txt
wc -l < data.txt
```

### Examples

```sh
# Save output to file
ls -la > listing.txt

# Append to log
echo "Done" >> log.txt

# Redirect errors
./script.sh 2> errors.log

# Combine stderr with stdout in pipeline
./script.sh 2>&1 | grep ERROR
```

---

## Output Capture

Capture command output directly into variables:

### String Capture (`=>`)

```sh
git rev-parse --short HEAD => sha
echo "Current commit: $sha"

whoami => user
echo "Logged in as $user"
```

### Lines Capture (`=>@`)

Split output into a list (one item per line):

```sh
ls *.txt =>@ files
for f in $files
    echo "File: $f"
end
```

---

## Command Substitution

Inline capture using `$(...)`:

```sh
echo "Today is $(date +%A)"
set files $(ls *.txt)

# Multi-line output becomes a list
for f in $(ls)
    echo "- $f"
end
```

---

## Job Control

Run and manage background processes:

### Background Execution

```sh
sleep 30 &                   # Run in background
[1] 12345                    # Job ID and PID
```

### Managing Jobs

```sh
jobs                         # List all jobs
fg %1                        # Bring job 1 to foreground
bg %1                        # Resume stopped job in background
fg                           # Foreground most recent job
```

### Signals

- **Ctrl+C** — Send SIGINT to foreground job
- **Ctrl+Z** — Stop foreground job, return to prompt

---

## Glob Patterns

Oshen expands glob patterns against the filesystem:

```sh
*.txt                        # All .txt files
src/*.zig                    # .zig files in src/
test?.txt                    # test1.txt, testA.txt, etc.
[abc].txt                    # a.txt, b.txt, or c.txt
[a-z].txt                    # Single lowercase letter .txt
[!0-9].txt                   # Not starting with a digit
```

| Pattern | Matches |
|---------|----------|
| `*` | Any sequence of characters |
| `**` | Any directory depth (recursive) |
| `?` | Any single character |
| `[abc]` | Any character in the set |
| `[a-z]` | Any character in the range |
| `[!abc]` or `[^abc]` | Any character NOT in the set |

### Recursive Globbing

Use `**` to match files across any directory depth:

```sh
**/*.zig                     # All .zig files anywhere
src/**/*.zig                 # All .zig files under src/
**/*_test.zig                # All test files anywhere
```

Globs are **suppressed in quotes**:

```sh
echo "*.txt"                 # Literal: *.txt
echo *.txt                   # Expanded: file1.txt file2.txt ...
```

If no files match, the pattern is passed through literally.

---

# Reference

## Builtins

| Command | Description |
|---------|-------------|
| `alias [name [cmd...]]` | Define or list command aliases |
| `bg [%n]` | Resume job in background |
| `cd [dir]` | Change directory (`cd` alone goes home) |
| `echo [-n] [args...]` | Print arguments (`-n`: no newline, supports `\e` for ESC) |
| `eval [code...]` | Execute arguments as shell code |
| `exit [code]` | Exit shell with optional status |
| `export [name [value]]` \| `[name=value]` | Export to environment |
| `false` | Return failure (exit 1) |
| `fg [%n]` | Bring job to foreground |
| `jobs` | List background/stopped jobs |
| `path_prepend VAR path...` | Prepend paths to a variable (deduplicates) |
| `pwd [-t]` | Print working directory (`-t`: replace $HOME with ~) |
| `var` / `set `[name [values...]]` | Get/set shell variables |
| `source <file>` | Execute file in current shell |
| `test <expr>` / `[ <expr> ]` | Evaluate conditional expression |
| `true` | Return success (exit 0) |
| `type <name>...` | Show how a name resolves (alias/builtin/function/external) |
| `unalias <name>...` | Remove command aliases |
| `unset <name>...` | Remove shell variables |

> Note: All builtins support `-h` or `--help` to display usage information.

### Test Expressions

The `test` builtin (and its `[` alias) evaluates conditional expressions:

| Expression | True if... |
|------------|------------|
| **File tests** | |
| `-e FILE` | File exists |
| `-f FILE` | Regular file exists |
| `-d FILE` | Directory exists |
| `-r FILE` | File is readable |
| `-w FILE` | File is writable |
| `-x FILE` | File is executable |
| `-s FILE` | File has size > 0 |
| `-L FILE` | File is a symbolic link |
| **String tests** | |
| `-z STRING` | String is empty |
| `-n STRING` | String is non-empty |
| `S1 = S2` | Strings are equal |
| `S1 != S2` | Strings are different |
| **Numeric tests** | |
| `N1 -eq N2` | Numbers are equal |
| `N1 -ne N2` | Numbers are not equal |
| `N1 -lt N2` | N1 < N2 |
| `N1 -le N2` | N1 ≤ N2 |
| `N1 -gt N2` | N1 > N2 |
| `N1 -ge N2` | N1 ≥ N2 |
| **Logical** | |
| `! EXPR` | Negate expression |
| `EXPR -a EXPR` | AND |
| `EXPR -o EXPR` | OR |

```sh
# File tests
if test -f config.json; echo "config exists"; end
if [ -d ~/.config ]; echo "config dir exists"; end

# String tests
if test -n "$name"; echo "name is set"; end
if [ "$x" = "yes" ]; echo "x is yes"; end

# Numeric tests
var count 5
if [ $count -gt 0 ]; echo "count is positive"; end
```

---

## Command Line Options

| Option | Description |
|--------|-------------|
| `-c <cmd>` | Execute command and exit |
| `-i` | Force interactive mode |
| `-h`, `--help` | Show help |
| `-v`, `--version` | Show version |
