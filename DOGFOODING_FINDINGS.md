# Oshen CLI Dogfooding Test Results

## Summary
Ran comprehensive tests on the Oshen CLI. Found **51/57 basic tests passing** with several significant issues and UX inconsistencies identified.

---

## 🐛 Critical Bugs

### 1. ~~**`return` in `else if` blocks causes parse error**~~ ✅ FIXED
**Severity:** High
**Impact:** Cannot use early returns in else-if chains within functions

```sh
# This used to fail with "error.UnterminatedFunction"
fun check_status
    if test $1 -eq 0
        return 0
    else if test $1 -lt 100
        return 1  # ← Parse error here
    else
        return 2
    end
end
```

**Expected:** Should parse and work correctly
**Actual (BEFORE FIX):** `oshen: error.UnterminatedFunction`
**Status:** ✅ **FIXED** in `src/language/parser.zig:scanToBlockEnd()` - Now correctly detects "else if" as a single construct and doesn't double-increment depth counter.

---

### 2. ~~**`pwd` outputs escape sequences in non-interactive mode**~~ ✅ FIXED
**Severity:** Medium
**Impact:** Pollutes output when using `pwd` in scripts

```sh
$ oshen -c 'cd /tmp; pwd'
]7;file://MQPHQ56DJR/private/tmp/private/tmp  # Before fix
```

**Expected:** `/private/tmp` (or `/tmp`)
**Actual (BEFORE FIX):** Includes OSC 7 escape sequence for terminal integration
**Status:** ✅ **FIXED** in `src/runtime/builtins/cd.zig` - Now only emits OSC 7 escape sequences when `state.interactive` is true, preventing escape code pollution in script mode.

**Note:** `pwd -t` works correctly and outputs `~/Desktop/oshen` format

---

### 3. **Globs don't expand with `echo` builtin**
**Severity:** Medium
**Impact:** Surprising behavior - globs work everywhere except `echo`

```sh
$ cd /tmp/oshen_glob_test
$ oshen -c 'echo *.txt'
*.txt  # ← Not expanded

$ oshen -c 'ls *.txt'
file1.txt file2.txt  # ← Works fine

$ oshen -c 'for f in *.txt; echo $f; end'
file1.txt
file2.txt  # ← Works fine
```

**Expected:** `echo *.txt` should expand like it does for other commands
**Actual:** Glob pattern passed literally to echo

---

### 4. **`path_prepend` doesn't work as documented**
**Severity:** Medium
**Impact:** Key configuration builtin is broken

```sh
$ oshen -c 'var PATH /usr/bin; path_prepend PATH /custom/bin /other/bin; echo $PATH'
/usr/bin  # ← No change!

$ oshen -c 'var PATH /usr/bin:/bin; path_prepend PATH /usr/bin /new/bin; echo $PATH'
/usr/bin:/bin  # ← No change, no deduplication
```

**Expected:** Should prepend paths and deduplicate
**Actual:** Does nothing

---

### 5. **`test` with `-a` and `-o` operators fails**
**Severity:** Medium
**Impact:** Cannot combine test conditions as documented

```sh
$ oshen -c 'test -e README.md -a -e VERSION; echo $?'
test: too many arguments
2
```

**Expected:** Should work per README documentation
**Actual:** Parser treats it as too many arguments

---

### 6. ~~**`$argv[n]` indexing doesn't work in functions**~~ ✅ NOT A BUG
**Severity:** Medium
**Impact:** Documented feature for accessing function args fails

```sh
$ oshen -c 'fun test; echo $argv[1]; end; test foo'
  # ← Empty output

$ oshen -c 'fun test; echo $argv; end; test foo bar'
foo bar  # ← $argv works, but not $argv[1]
```

**Expected:** Should output `foo`
**Actual:** Empty output
**Status:** ✅ **NOT A BUG** - The issue was that the function name `test` shadowed the `test` builtin, so the function was never getting called. Using a different function name works perfectly:
```sh
$ oshen -c 'fun myfunc; echo $argv[1]; end; myfunc foo'
foo  # ← Works correctly!
```

---

### 7. **Braced variable indexing doesn't work**
**Severity:** Low
**Impact:** Alternative syntax fails

```sh
$ oshen -c 'var items a b c; echo ${items[1]}'
$items[1]  # ← Literal output
```

**Expected:** Should output `a`
**Actual:** Outputs literal string

---

### 8. **`echo -e` option not supported but used in examples**
**Severity:** Low
**Impact:** Trying to use `-e` flag treats it as a literal argument

```sh
$ oshen -c 'echo -e "a\nb\nc" =>@ arr; echo $arr'
-e a b c  # ← The -e is treated as text
```

**Expected:** Either support `-e` or don't use it in test cases
**Actual:** Treated as regular argument

---

## ⚠️ UX Issues & Oddities

### 9. **Newline handling in test comparisons**
**Severity:** Low
**Behavior:** Escape sequences in quotes actually expand

```sh
$ oshen -c 'echo "line1\nline2"'
line1
line2  # ← Actual newlines

# But test expected this to be literal '\n'
```

This is actually **correct behavior**, but may surprise users coming from Bash where `echo` doesn't interpret escapes by default.

---

### 10. **Multi-line commands with `#` comments fail**
**Severity:** Low
**Impact:** Cannot use newlines with comments in `-c` mode

```sh
$ oshen -c '# comment\necho world'
  # ← Empty output (expected: world)
```

**Likely cause:** The `#` comments out everything including the newline and subsequent command.

---

### 11. **For loop output formatting in tests**
**Severity:** None (test issue)
**Note:** For loops correctly output each item on separate lines, test script expected `\n` literal

```sh
$ oshen -c 'for x in 1 2 3; echo $x; end'
1
2
3  # ← Correct

# Test expected: "1\n2\n3" (literal string)
```

This is correct behavior; the test was wrong.

---

### 12. **`/tmp` vs `/private/tmp` on macOS**
**Severity:** None (OS quirk)
**Note:** macOS symlinks `/tmp` to `/private/tmp`, causing path confusion

```sh
$ oshen -c 'cd /tmp; pwd'
# Shows /private/tmp
```

This is actually correct Unix behavior.

---

## ✅ What Works Well

### Features that work perfectly:
- ✅ Basic variable assignment and expansion
- ✅ List variables and cartesian products (`test_$files` → `test_a.txt test_b.txt`)
- ✅ Array indexing: `$arr[1]`, `$arr[-1]`, `$arr[2..4]`, `$arr[2..]`, `$arr[..2]`
- ✅ Brace expansion: `{a,b,c}`, `{a,b}_{1,2}`, `prefix_{x,y,z}`
- ✅ If/else if/else chains (when not using `return`)
- ✅ For loops with break/continue
- ✅ While loops
- ✅ Functions with `$1`, `$2`, `$argv`, `$#` positional parameters
- ✅ Aliases (`alias`, `unalias`)
- ✅ Command substitution `$(cmd)`
- ✅ Output capture `=>` and `=>@` (mostly - see issue #8)
- ✅ Pipelines with `|` and `|>`
- ✅ Redirections: `>`, `>>`, `2>`, `2>&1`, `<`
- ✅ Conditional chaining: `&&`, `||`, `and`, `or`
- ✅ Test builtin file checks: `-e`, `-f`, `-d`, `-r`, `-w`, `-x`, `-s`, `-L`
- ✅ Test builtin string checks: `-z`, `-n`, `=`, `!=`
- ✅ Test builtin numeric checks: `-eq`, `-ne`, `-lt`, `-le`, `-gt`, `-ge`
- ✅ Test negation: `! EXPR`
- ✅ Builtins: `echo`, `cd`, `pwd -t`, `var`, `export`, `type`, `unset`, `source`, `eval`
- ✅ Special variables: `$?`, `$status`, `~`, `$HOME`
- ✅ Help flags: `--help`, `-h` on builtins and main command
- ✅ Error messages for unclosed constructs (clear errors)
- ✅ Escape sequences in double quotes: `\n`, `\t`, `\\`, `\"`, `\$`
- ✅ Variable concatenation: `$a$b$c`
- ✅ Nested command substitution: `$(echo $(echo nested))`
- ✅ Preserving whitespace in quotes
- ✅ Script file execution
- ✅ Bracket syntax for test: `[ expr ]`

---

## 💭 Design Questions / Room for Improvement

### 13. **Inconsistent behavior: Why don't globs expand in `echo`?**

Most shells expand globs before passing to commands (including echo). Oshen seems to have special logic that prevents glob expansion for `echo` but allows it for external commands and loop constructs. This feels inconsistent.

**Questions:**
- Is this intentional?
- Is `echo` treating globs as literals for safety?
- Should there be a way to force expansion?

---

### 14. **Error messages expose implementation details**

```sh
$ oshen -c 'if true'
oshen: error.UnterminatedIf

$ oshen -c 'echo "unclosed'
oshen: error.UnterminatedString
```

**Observation:** Error names look like Zig error types. Consider user-friendly messages:
- `error.UnterminatedIf` → `syntax error: unterminated 'if' statement (missing 'end')`
- `error.UnterminatedString` → `syntax error: unterminated string (missing closing quote)`

---

### 15. **OSC 7 escape codes in non-TTY output**

The `pwd` command emits OSC 7 sequences even in non-interactive mode (`-c`). This pollutes script output.

**Suggestion:** Only emit escape sequences when stdout is a TTY.

---

### 16. **Out-of-bounds array access returns empty**

```sh
$ oshen -c 'var arr a b c; echo $arr[10]'
  # Empty output

$ oshen -c 'var arr a b c; echo $arr[-10]'
  # Empty output
```

**Observation:** Silently returns empty string. Some shells error on out-of-bounds access.

**Question:** Is silent empty the desired behavior, or should this warn/error?

---

### 17. **Reverse slices return empty**

```sh
$ oshen -c 'var arr a b c; echo $arr[3..1]'
  # Empty output
```

**Question:** Should this error or perhaps support descending slices?

---

### 18. **`/tmp` writable check fails on macOS**

```sh
$ oshen -c 'test -w /tmp; echo $?'
1  # ← Claims not writable, but it is
```

This might be a permissions issue or symlink-related on macOS.

---

### 19. **No math builtin but examples use `expr`**

The README shows:
```sh
var count $(math $count - 1)
```

But testing shows `expr` is used instead:
```sh
var count $(expr $count + 1)
```

**Question:** Is there a `math` builtin planned? Or should docs use `expr`?

---

### 20. **`jobs`, `fg`, `bg` builtins not tested**

Didn't test background job control features in `-c` mode. These may require interactive mode.

**Suggestion:** Add examples or integration tests for job control.

---

## 🎯 Recommendations

### Priority 1 (High Impact):
1. Fix `return` in `else if` blocks (bug #1)
2. Fix `pwd` escape sequence pollution (bug #2)
3. Fix `path_prepend` builtin (bug #4)
4. Fix `test -a` and `-o` operators (bug #5)

### Priority 2 (Medium Impact):
5. Fix `$argv[n]` indexing in functions (bug #6)
6. Decide on glob expansion policy for `echo` (bug #3)
7. Improve error messages to be user-friendly (issue #14)
8. Only emit OSC codes when stdout is TTY (issue #15)

### Priority 3 (Low Impact / Polish):
9. Support or document `-e` flag for echo (bug #8)
10. Fix braced indexing `${var[n]}` (bug #7)
11. Document out-of-bounds behavior (issue #16)
12. Review math/expr documentation consistency (issue #19)

---

## 📊 Test Statistics

- **Total tests:** 57
- **Passed:** 53 ⬆️⬆️ (was 51, then 52)
- **Failed:** 4 ⬇️⬇️ (was 6, then 5)
- **Pass rate:** 93.0% ⬆️⬆️ (was 89.5%, then 91.2%)

### Failed Tests Breakdown:
1. For loop newline formatting (test issue, not a bug)
2. ~~Function with `$argv[1]` indexing~~ ✅ FIXED (was test naming issue)
3. ~~`pwd` without `-t` flag (escape codes)~~ ✅ FIXED
4. Escaped `\n` in quotes (expected literal, got newline - actually correct!)
5. Escaped `\t` in quotes (expected literal, got tab - actually correct!)
6. Multi-line comment handling

**Actual bugs from failed tests:** 1 (multi-line comments)
**Test expectations wrong:** 3 (newline formatting, \n and \t escaping)

---

## 🎬 Conclusion

Oshen is impressively functional for a 0.0.1 shell! The core features work well:
- Variables, lists, and array operations are solid
- Control flow (if/for/while) works correctly
- Functions work (except for the `else if` + `return` edge case)
- The modern features like `=>` capture and `|>` pipes are nice

**Biggest issues:**
1. The `else if` + `return` bug blocks practical use cases
2. `path_prepend` being broken hurts configuration
3. `pwd` pollution makes scripting annoying
4. `test -a`/`-o` not working limits conditional logic

**Overall:** With the top 4-5 bugs fixed, this would be a very usable shell for daily driving! 🌊
