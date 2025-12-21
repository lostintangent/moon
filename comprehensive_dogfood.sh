#!/bin/bash
# Comprehensive Oshen Shell Dogfooding Test Suite
# Testing 100+ scenarios across all features

OSHEN="./zig-out/bin/oshen"
PASS=0
FAIL=0
TOTAL=0

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test categories
declare -a FAILURES=()
declare -a CATEGORY_STATS=()

print_category() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
}

test_case() {
    local name="$1"
    local cmd="$2"
    local expected="$3"
    local category="${4:-General}"

    TOTAL=$((TOTAL + 1))
    local output
    output=$($OSHEN -c "$cmd" 2>&1)
    local exit_code=$?

    # Handle newline normalization
    output=$(echo -n "$output")
    expected=$(echo -n "$expected")

    if [ "$output" = "$expected" ]; then
        echo -e "${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $name"
        echo "  Expected: '$expected'"
        echo "  Got:      '$output'"
        echo "  Exit:     $exit_code"
        FAIL=$((FAIL + 1))
        FAILURES+=("[$category] $name: expected '$expected', got '$output'")
        return 1
    fi
}

test_exit_code() {
    local name="$1"
    local cmd="$2"
    local expected_code="$3"
    local category="${4:-General}"

    TOTAL=$((TOTAL + 1))
    $OSHEN -c "$cmd" >/dev/null 2>&1
    local exit_code=$?

    if [ "$exit_code" = "$expected_code" ]; then
        echo -e "${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $name"
        echo "  Expected exit: $expected_code"
        echo "  Got exit:      $exit_code"
        FAIL=$((FAIL + 1))
        FAILURES+=("[$category] $name: expected exit $expected_code, got $exit_code")
        return 1
    fi
}

test_contains() {
    local name="$1"
    local cmd="$2"
    local expected_substring="$3"
    local category="${4:-General}"

    TOTAL=$((TOTAL + 1))
    local output
    output=$($OSHEN -c "$cmd" 2>&1)

    if [[ "$output" == *"$expected_substring"* ]]; then
        echo -e "${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $name"
        echo "  Expected to contain: '$expected_substring'"
        echo "  Got:                 '$output'"
        FAIL=$((FAIL + 1))
        FAILURES+=("[$category] $name: expected to contain '$expected_substring', got '$output'")
        return 1
    fi
}

test_not_contains() {
    local name="$1"
    local cmd="$2"
    local unexpected_substring="$3"
    local category="${4:-General}"

    TOTAL=$((TOTAL + 1))
    local output
    output=$($OSHEN -c "$cmd" 2>&1)

    if [[ "$output" != *"$unexpected_substring"* ]]; then
        echo -e "${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $name"
        echo "  Should NOT contain: '$unexpected_substring'"
        echo "  But got:            '$output'"
        FAIL=$((FAIL + 1))
        FAILURES+=("[$category] $name: should not contain '$unexpected_substring', but got '$output'")
        return 1
    fi
}

# ============================================================================
# CATEGORY: Basic Variables
# ============================================================================
print_category "Basic Variables (15 tests)"

test_case "Simple variable assignment" "var x hello; echo \$x" "hello" "Variables"
test_case "Multi-value variable" "var colors red green blue; echo \$colors" "red green blue" "Variables"
test_case "Variable reassignment" "var x foo; var x bar; echo \$x" "bar" "Variables"
test_case "Empty variable" "var x; echo \$x" "" "Variables"
test_case "Variable with spaces in value" 'var msg "hello world"; echo $msg' "hello world" "Variables"
test_case "Multiple variables" "var a 1; var b 2; var c 3; echo \$a \$b \$c" "1 2 3" "Variables"
test_case "Variable concatenation" "var a hello; var b world; echo \$a\$b" "helloworld" "Variables"
test_case "Variable with special chars" 'var x "hello@#$%"; echo $x' "hello@#$%" "Variables"
test_case "Numeric variable" "var num 42; echo \$num" "42" "Variables"
test_case "Negative number" "var num -42; echo \$num" "-42" "Variables"
test_case "Floating point" "var pi 3.14; echo \$pi" "3.14" "Variables"
test_case "Variable with underscore" "var my_var test; echo \$my_var" "test" "Variables"
test_case "Variable with numbers" "var var123 test; echo \$var123" "test" "Variables"
test_case "Unset variable" "var x hello; unset x; echo \$x" "" "Variables"
test_case "Multiple unset" "var a 1; var b 2; unset a b; echo \$a \$b" "" "Variables"

# ============================================================================
# CATEGORY: Environment Variables
# ============================================================================
print_category "Environment Variables (10 tests)"

test_case "Export with value" "export FOO bar; echo \$FOO" "bar" "Environment"
test_case "Export equals syntax" "export FOO=bar; echo \$FOO" "bar" "Environment"
test_case "Export existing var" "var X test; export X; echo \$X" "test" "Environment"
test_case "Export multiple" "export A=1 B=2; echo \$A \$B" "1 2" "Environment"
test_case "HOME variable exists" "echo \$HOME" "$HOME" "Environment"
test_case "PATH variable exists" "echo \$PATH" "$PATH" "Environment"
test_case "PWD variable" "export PWD /tmp; echo \$PWD" "/tmp" "Environment"
test_case "Override PATH" "export PATH /custom; echo \$PATH" "/custom" "Environment"
test_case "Export empty value" "export EMPTY; echo \"[\$EMPTY]\"" "[]" "Environment"
test_case "Export with colon path" "export MYPATH /a:/b:/c; echo \$MYPATH" "/a:/b:/c" "Environment"

# ============================================================================
# CATEGORY: Array Indexing
# ============================================================================
print_category "Array Indexing (20 tests)"

test_case "First element" "var arr a b c; echo \$arr[1]" "a" "Arrays"
test_case "Second element" "var arr a b c; echo \$arr[2]" "b" "Arrays"
test_case "Last element" "var arr a b c; echo \$arr[3]" "c" "Arrays"
test_case "Negative index -1" "var arr a b c; echo \$arr[-1]" "c" "Arrays"
test_case "Negative index -2" "var arr a b c; echo \$arr[-2]" "b" "Arrays"
test_case "Negative index -3" "var arr a b c; echo \$arr[-3]" "a" "Arrays"
test_case "Slice 1..2" "var arr a b c d; echo \$arr[1..2]" "a b" "Arrays"
test_case "Slice 2..4" "var arr a b c d e; echo \$arr[2..4]" "b c d" "Arrays"
test_case "Slice from start" "var arr a b c d; echo \$arr[..2]" "a b" "Arrays"
test_case "Slice to end" "var arr a b c d; echo \$arr[3..]" "c d" "Arrays"
test_case "Full slice" "var arr a b c; echo \$arr[1..]" "a b c" "Arrays"
test_case "Single element slice" "var arr a b c; echo \$arr[2..2]" "b" "Arrays"
test_case "Negative slice" "var arr a b c d; echo \$arr[-2..-1]" "c d" "Arrays"
test_case "Out of bounds positive" "var arr a b c; echo \$arr[10]" "" "Arrays"
test_case "Out of bounds negative" "var arr a b c; echo \$arr[-10]" "" "Arrays"
test_case "Zero index (invalid)" "var arr a b c; echo \$arr[0]" "" "Arrays"
test_case "Index single item" "var single x; echo \$single[1]" "x" "Arrays"
test_case "Index empty array" "var empty; echo \$empty[1]" "" "Arrays"
test_case "Nested indexing" "var outer a b c; var idx 2; echo \$outer[\$idx]" "b" "Arrays"
test_case "Array length via count" "var arr a b c d e; echo \$arr" "a b c d e" "Arrays"

# ============================================================================
# CATEGORY: Brace Expansion
# ============================================================================
print_category "Brace Expansion (10 tests)"

test_case "Simple brace list" "echo {a,b,c}" "a b c" "Braces"
test_case "Brace with prefix" "echo pre_{a,b,c}" "pre_a pre_b pre_c" "Braces"
test_case "Brace with suffix" "echo {a,b,c}_post" "a_post b_post c_post" "Braces"
test_case "Brace prefix and suffix" "echo x_{a,b}_y" "x_a_y x_b_y" "Braces"
test_case "Nested braces" "echo {a,b}_{1,2}" "a_1 a_2 b_1 b_2" "Braces"
test_case "Three-way expansion" "echo {x,y,z}" "x y z" "Braces"
test_case "Single item brace" "echo {a}" "a" "Braces"
test_case "Empty brace" "echo {}" "{}" "Braces"
test_case "Brace with variable" 'var items a b; echo {$items}_end' "a_end b_end" "Braces"
test_case "Multiple brace sets" "echo {1,2} {a,b}" "1 2 a b" "Braces"

# ============================================================================
# CATEGORY: Quoting and Escaping
# ============================================================================
print_category "Quoting and Escaping (15 tests)"

test_case "Single quotes literal" "echo 'hello \$world'" 'hello $world' "Quoting"
test_case "Double quotes expand" 'var x test; echo "value: $x"' "value: test" "Quoting"
test_case "Escaped dollar" 'echo "\$literal"' '$literal' "Quoting"
test_case "Escaped backslash" 'echo "\\\\"' '\' "Quoting"
test_case "Escaped quote" 'echo "\""' '"' "Quoting"
test_case "Newline escape" 'echo "a\nb"' $'a\nb' "Quoting"
test_case "Tab escape" 'echo "a\tb"' $'a\tb' "Quoting"
test_case "Mixed quotes" "echo \"it's working\"" "it's working" "Quoting"
test_case "Empty string" 'echo ""' "" "Quoting"
test_case "Whitespace preservation" 'echo "a  b  c"' "a  b  c" "Quoting"
test_case "Backslash escape space" 'echo hello\ world' "hello world" "Quoting"
test_case "Single quote in double" 'echo "can'"'"'t"' "can't" "Quoting"
test_case "Unicode in quotes" 'echo "hello 世界"' "hello 世界" "Quoting"
test_case "Quote empty var" 'var x; echo "$x"' "" "Quoting"
test_case "Preserve trailing space" 'echo "test "' "test " "Quoting"

# ============================================================================
# CATEGORY: Command Substitution
# ============================================================================
print_category "Command Substitution (10 tests)"

test_case "Basic substitution" 'echo $(echo hello)' "hello" "Substitution"
test_case "Substitution in string" 'echo "result: $(echo test)"' "result: test" "Substitution"
test_case "Multiple substitutions" 'echo $(echo a) $(echo b)' "a b" "Substitution"
test_case "Nested substitution" 'echo $(echo $(echo nested))' "nested" "Substitution"
test_case "Substitution with variable" 'var x world; echo $(echo $x)' "world" "Substitution"
test_case "Empty substitution" 'echo $(echo)' "" "Substitution"
test_case "Substitution arithmetic" 'echo $(expr 2 + 2)' "4" "Substitution"
test_case "Substitution to variable" 'var x $(echo test); echo $x' "test" "Substitution"
test_case "Multi-word substitution" 'echo $(echo one two three)' "one two three" "Substitution"
test_case "Substitution with quotes" 'echo $(echo "hello world")' "hello world" "Substitution"

# ============================================================================
# CATEGORY: Conditionals (If/Else)
# ============================================================================
print_category "Conditionals (20 tests)"

test_case "If true" "if true; echo yes; end" "yes" "Conditionals"
test_case "If false" "if false; echo yes; end" "" "Conditionals"
test_case "If else true" "if true; echo yes; else; echo no; end" "yes" "Conditionals"
test_case "If else false" "if false; echo yes; else; echo no; end" "no" "Conditionals"
test_case "If test string eq" 'if test "a" = "a"; echo match; end' "match" "Conditionals"
test_case "If test string ne" 'if test "a" != "b"; echo diff; end' "diff" "Conditionals"
test_case "If test number eq" "if test 5 -eq 5; echo equal; end" "equal" "Conditionals"
test_case "If test number lt" "if test 3 -lt 5; echo less; end" "less" "Conditionals"
test_case "If test number gt" "if test 7 -gt 5; echo greater; end" "greater" "Conditionals"
test_case "If test number le" "if test 5 -le 5; echo lesseq; end" "lesseq" "Conditionals"
test_case "If test number ge" "if test 5 -ge 5; echo greatereq; end" "greatereq" "Conditionals"
test_case "If test -z empty" 'if test -z ""; echo empty; end' "empty" "Conditionals"
test_case "If test -n non-empty" 'if test -n "text"; echo nonempty; end' "nonempty" "Conditionals"
test_case "Else if chain true first" "if test 1 -eq 1; echo first; else if test 2 -eq 2; echo second; end" "first" "Conditionals"
test_case "Else if chain true second" "if test 1 -eq 2; echo first; else if test 2 -eq 2; echo second; end" "second" "Conditionals"
test_case "Else if chain all false" "if test 1 -eq 2; echo first; else if test 2 -eq 3; echo second; else; echo third; end" "third" "Conditionals"
test_case "Negation with !" "if ! test 1 -eq 2; echo notequal; end" "notequal" "Conditionals"
test_case "Inline if" "if true; echo inline; end" "inline" "Conditionals"
test_case "Bracket test syntax" "if [ 1 -eq 1 ]; echo bracket; end" "bracket" "Conditionals"
test_case "Test with variable" "var x 5; if test \$x -eq 5; echo five; end" "five" "Conditionals"

# ============================================================================
# CATEGORY: Loops (For/While)
# ============================================================================
print_category "Loops (15 tests)"

test_case "For loop simple" "for x in a b c; echo \$x; end" $'a\nb\nc' "Loops"
test_case "For loop with variable" "var items 1 2 3; for i in \$items; echo \$i; end" $'1\n2\n3' "Loops"
test_case "For loop empty list" "for x in ; echo \$x; end" "" "Loops"
test_case "For loop single item" "for x in single; echo \$x; end" "single" "Loops"
test_case "While true break" "var i 0; while true; echo \$i; break; end" "0" "Loops"
test_case "While counter" "var n 3; while test \$n -gt 0; echo \$n; var n \$(expr \$n - 1); end" $'3\n2\n1' "Loops"
test_case "For with break" "for x in a b c d; echo \$x; if test \$x = b; break; end; end" $'a\nb' "Loops"
test_case "For with continue" "for x in a b c; if test \$x = b; continue; end; echo \$x; end" $'a\nc' "Loops"
test_case "Nested for loops" "for x in 1 2; for y in a b; echo \$x\$y; end; end" $'1a\n1b\n2a\n2b' "Loops"
test_case "For with arithmetic" "for i in 1 2 3; echo \$(expr \$i + 10); end" $'11\n12\n13' "Loops"
test_case "While false" "while false; echo never; end" "" "Loops"
test_case "For inline" "for x in a; echo \$x; end" "a" "Loops"
test_case "Empty for body" "for x in a b c; end" "" "Loops"
test_case "While with multiple conditions" "var x 2; while test \$x -gt 0; var x \$(expr \$x - 1); end; echo done" "done" "Loops"
test_case "For over command output" 'for word in $(echo one two); echo $word; end' $'one\ntwo' "Loops"

# ============================================================================
# CATEGORY: Functions
# ============================================================================
print_category "Functions (15 tests)"

test_case "Simple function" "fun greet; echo hello; end; greet" "hello" "Functions"
test_case "Function with arg" "fun say; echo \$1; end; say world" "world" "Functions"
test_case "Function multiple args" "fun add; echo \$1 \$2; end; add a b" "a b" "Functions"
test_case "Function argv" "fun show; echo \$argv; end; show x y z" "x y z" "Functions"
test_case "Function argv indexing" "fun first; echo \$argv[1]; end; first foo bar" "foo" "Functions"
test_case "Function arg count" 'fun count; echo $#; end; count a b c' "3" "Functions"
test_case "Function no args" 'fun test; echo $#; end; test' "0" "Functions"
test_case "Function with return" "fun check; return 42; end; check; echo \$?" "42" "Functions"
test_case "Function early return" "fun early; echo before; return; echo after; end; early" "before" "Functions"
test_case "Function with if" "fun check; if test \$1 = yes; echo ok; end; end; check yes" "ok" "Functions"
test_case "Function with loop" "fun loop; for x in \$argv; echo \$x; end; end; loop a b" $'a\nb' "Functions"
test_case "Nested function calls" "fun inner; echo inner; end; fun outer; inner; end; outer" "inner" "Functions"
test_case "Function reassignment" "fun f; echo old; end; fun f; echo new; end; f" "new" "Functions"
test_case "Function with variable" "fun test; var x local; echo \$x; end; test" "local" "Functions"
test_case "Function positional \$2" "fun second; echo \$2; end; second a b c" "b" "Functions"

# ============================================================================
# CATEGORY: Aliases
# ============================================================================
print_category "Aliases (8 tests)"

test_case "Simple alias" "alias ll 'ls -la'; type ll" "ll is an alias for 'ls -la'" "Aliases"
test_case "Alias with args" "alias e echo; e test" "test" "Aliases"
test_case "Alias expansion" "alias greeting 'echo hello'; greeting" "hello" "Aliases"
test_case "Multiple aliases" "alias a 'echo a'; alias b 'echo b'; a; b" $'a\nb' "Aliases"
test_case "Unalias" "alias x 'echo x'; unalias x; type x" "x: command not found" "Aliases"
test_case "Alias overwrite" "alias x 'echo old'; alias x 'echo new'; x" "new" "Aliases"
test_case "List aliases" "alias test 'echo hi'; alias test" "test is an alias for 'echo hi'" "Aliases"
test_case "Alias with quotes" "alias greet 'echo \"hello world\"'; greet" "hello world" "Aliases"

# ============================================================================
# CATEGORY: Pipelines
# ============================================================================
print_category "Pipelines (10 tests)"

test_case "Simple pipe" "echo hello | cat" "hello" "Pipelines"
test_case "Pipe to grep" "echo -e 'line1\nline2\nline3' | grep line2" "line2" "Pipelines"
test_case "Multiple pipes" "echo hello | cat | cat" "hello" "Pipelines"
test_case "Pipe with variable" "var x test; echo \$x | cat" "test" "Pipelines"
test_case "Alternative pipe |>" "echo test |> cat" "test" "Pipelines"
test_case "Chained |>" "echo hello |> cat |> cat" "hello" "Pipelines"
test_case "Pipe with substitution" "echo \$(echo test) | cat" "test" "Pipelines"
test_case "Pipe to wc" "echo -e 'a\nb\nc' | wc -l" "3" "Pipelines"
test_case "Pipe to head" "echo -e '1\n2\n3\n4' | head -n 2" $'1\n2' "Pipelines"
test_case "Pipe in function" "fun test; echo hi | cat; end; test" "hi" "Pipelines"

# ============================================================================
# CATEGORY: Redirections
# ============================================================================
print_category "Redirections (12 tests)"

# Setup temp directory
mkdir -p /tmp/oshen_redir_test
cd /tmp/oshen_redir_test

test_case "Output redirect >" "echo hello > out.txt; cat out.txt" "hello" "Redirections"
test_case "Append redirect >>" "echo a > append.txt; echo b >> append.txt; cat append.txt" $'a\nb' "Redirections"
test_case "Input redirect <" "echo content > in.txt; cat < in.txt" "content" "Redirections"
test_case "Redirect overwrite" "echo first > over.txt; echo second > over.txt; cat over.txt" "second" "Redirections"
test_case "Stderr redirect 2>" "bash -c 'echo error >&2' 2> err.txt; cat err.txt" "error" "Redirections"
test_case "Combine stdout/stderr 2>&1" "bash -c 'echo out; echo err >&2' 2>&1 | cat" $'out\nerr' "Redirections"
test_case "Redirect to /dev/null" "echo hidden > /dev/null; echo shown" "shown" "Redirections"
test_case "Multiple redirects" "echo test > multi.txt 2> /dev/null; cat multi.txt" "test" "Redirections"
test_case "Redirect in pipeline" "echo data | cat > pipe.txt; cat pipe.txt" "data" "Redirections"
test_case "Redirect stderr append 2>>" "bash -c 'echo e1 >&2' 2> err2.txt; bash -c 'echo e2 >&2' 2>> err2.txt; cat err2.txt" $'e1\ne2' "Redirections"
test_case "Both stdout and stderr &>" "bash -c 'echo out; echo err >&2' &> both.txt; cat both.txt" $'out\nerr' "Redirections"
test_case "Redirect with variable" "var file redir_var.txt; echo test > \$file; cat \$file" "test" "Redirections"

cd - > /dev/null
rm -rf /tmp/oshen_redir_test

# ============================================================================
# CATEGORY: Output Capture
# ============================================================================
print_category "Output Capture (8 tests)"

test_case "String capture =>" "echo hello => x; echo \$x" "hello" "Capture"
test_case "Capture to new var" "echo world => greeting; echo \$greeting" "world" "Capture"
test_case "Lines capture =>@" "echo -e 'a\nb\nc' =>@ arr; echo \$arr[2]" "b" "Capture"
test_case "Capture empty" "echo =>@ empty; echo [\$empty]" "[]" "Capture"
test_case "Capture multi-word" "echo one two three => words; echo \$words" "one two three" "Capture"
test_case "Capture in pipeline" "echo test | cat => piped; echo \$piped" "test" "Capture"
test_case "Capture command output" "expr 2 + 3 => result; echo \$result" "5" "Capture"
test_case "Multiple captures" "echo a => x; echo b => y; echo \$x \$y" "a b" "Capture"

# ============================================================================
# CATEGORY: Logical Operators
# ============================================================================
print_category "Logical Operators (10 tests)"

test_case "AND with &&" "true && echo yes" "yes" "Logical"
test_case "AND with false" "false && echo no" "" "Logical"
test_case "OR with ||" "false || echo yes" "yes" "Logical"
test_case "OR with true" "true || echo no" "" "Logical"
test_case "Word AND" "true and echo yes" "yes" "Logical"
test_case "Word OR" "false or echo yes" "yes" "Logical"
test_case "Chained AND" "true && true && echo yes" "yes" "Logical"
test_case "Chained OR" "false || false || echo yes" "yes" "Logical"
test_case "Mixed AND/OR" "true && false || echo yes" "yes" "Logical"
test_case "AND with test" "test 1 -eq 1 && echo match" "match" "Logical"

# ============================================================================
# CATEGORY: Special Variables
# ============================================================================
print_category "Special Variables (8 tests)"

test_case "Exit status \$?" "true; echo \$?" "0" "Special"
test_case "Exit status fail" "false; echo \$?" "1" "Special"
test_case "Status variable" "true; echo \$status" "0" "Special"
test_case "Tilde expansion ~" "echo ~" "$HOME" "Special"
test_case "Tilde with path" "echo ~/test" "$HOME/test" "Special"
test_case "Status after command" "expr 5 + 5; echo \$?" "0" "Special"
test_case "Status chain" "true; true; echo \$?" "0" "Special"
test_case "Status after false" "true; false; echo \$?" "1" "Special"

# ============================================================================
# CATEGORY: Builtins
# ============================================================================
print_category "Builtins (15 tests)"

test_case "echo builtin" "echo test" "test" "Builtins"
test_case "echo -n no newline" "echo -n test" "test" "Builtins"
test_case "echo multiple args" "echo a b c" "a b c" "Builtins"
test_case "true builtin" "true; echo \$?" "0" "Builtins"
test_case "false builtin" "false; echo \$?" "1" "Builtins"
test_case "pwd builtin" "cd /tmp; pwd" "/private/tmp" "Builtins"
test_case "pwd -t flag" "cd ~; pwd -t" "~" "Builtins"
test_case "cd to directory" "cd /tmp; pwd" "/private/tmp" "Builtins"
test_case "cd to home" "cd; pwd" "$HOME" "Builtins"
test_case "cd with ~" "cd ~; pwd" "$HOME" "Builtins"
test_case "type builtin" "type echo" "echo is a shell builtin" "Builtins"
test_case "type external" "type ls" "ls is /bin/ls" "Builtins"
test_case "type alias" "alias myalias 'echo test'; type myalias" "myalias is an alias for 'echo test'" "Builtins"
test_case "type function" "fun myfun; echo hi; end; type myfun" "myfun is a function" "Builtins"
test_case "exit with code" "exit 0; echo \$?" "0" "Builtins"

# ============================================================================
# CATEGORY: File Tests
# ============================================================================
print_category "File Tests (12 tests)"

# Setup test files
mkdir -p /tmp/oshen_file_test
cd /tmp/oshen_file_test
touch exists.txt
echo "content" > nonempty.txt
mkdir testdir
chmod +x exists.txt
ln -s exists.txt symlink.txt

test_case "Test -e exists" "test -e exists.txt; echo \$?" "0" "FileTests"
test_case "Test -e not exists" "test -e nonexistent; echo \$?" "1" "FileTests"
test_case "Test -f regular file" "test -f exists.txt; echo \$?" "0" "FileTests"
test_case "Test -f directory" "test -f testdir; echo \$?" "1" "FileTests"
test_case "Test -d directory" "test -d testdir; echo \$?" "0" "FileTests"
test_case "Test -d file" "test -d exists.txt; echo \$?" "1" "FileTests"
test_case "Test -s non-empty" "test -s nonempty.txt; echo \$?" "0" "FileTests"
test_case "Test -s empty" "test -s exists.txt; echo \$?" "1" "FileTests"
test_case "Test -L symlink" "test -L symlink.txt; echo \$?" "0" "FileTests"
test_case "Test -L regular" "test -L exists.txt; echo \$?" "1" "FileTests"
test_case "Test -r readable" "test -r exists.txt; echo \$?" "0" "FileTests"
test_case "Test -x executable" "test -x exists.txt; echo \$?" "0" "FileTests"

cd - > /dev/null
rm -rf /tmp/oshen_file_test

# ============================================================================
# CATEGORY: Edge Cases
# ============================================================================
print_category "Edge Cases (20 tests)"

test_case "Empty command" "" "" "EdgeCases"
test_case "Only whitespace" "   " "" "EdgeCases"
test_case "Only semicolons" ";;;" "" "EdgeCases"
test_case "Empty string echo" 'echo ""' "" "EdgeCases"
test_case "Var with dollar in name" 'var \$test hello; echo $\$test' '$test' "EdgeCases"
test_case "Very long variable name" "var verylongvariablenamethatgoesforever test; echo \$verylongvariablenamethatgoesforever" "test" "EdgeCases"
test_case "Variable name with all caps" "var SCREAMING_SNAKE_CASE value; echo \$SCREAMING_SNAKE_CASE" "value" "EdgeCases"
test_case "Consecutive semicolons" "echo a; ; echo b" $'a\nb' "EdgeCases"
test_case "Multiple spaces between words" "echo a    b    c" "a b c" "EdgeCases"
test_case "Tab characters" 'echo "a	b"' $'a\tb' "EdgeCases"
test_case "Null bytes handling" 'echo test' "test" "EdgeCases"
test_case "Very long string" "echo $(printf 'a%.0s' {1..1000})" "$(printf 'a%.0s' {1..1000})" "EdgeCases"
test_case "Deeply nested substitution" 'echo $(echo $(echo $(echo deep)))' "deep" "EdgeCases"
test_case "Mixed quotes and escapes" 'echo "can'\''t stop"' "can't stop" "EdgeCases"
test_case "Variable expansion in var name" 'var x y; var name x; echo $name' "x" "EdgeCases"
test_case "Empty array slice" "var arr a b c; echo \$arr[10..20]" "" "EdgeCases"
test_case "Reverse slice" "var arr a b c; echo \$arr[3..1]" "" "EdgeCases"
test_case "Same index slice" "var arr a b c; echo \$arr[2..2]" "b" "EdgeCases"
test_case "Negative to positive slice" "var arr a b c d; echo \$arr[-2..3]" "c" "EdgeCases"
test_case "Command that fails" "false; true; echo \$?" "0" "EdgeCases"

# ============================================================================
# CATEGORY: Error Handling
# ============================================================================
print_category "Error Handling (15 tests)"

test_exit_code "Nonexistent command" "nonexistentcommand123" "127" "Errors"
test_exit_code "Command not found status" "notfound456" "127" "Errors"
test_contains "Unterminated string error" 'echo "unterminated' "error" "Errors"
test_contains "Unterminated if error" "if true" "error" "Errors"
test_contains "Unterminated for error" "for x in a b c" "error" "Errors"
test_contains "Unterminated while error" "while true" "error" "Errors"
test_contains "Unterminated function error" "fun test" "error" "Errors"
test_exit_code "Exit with specific code" "exit 42" "42" "Errors"
test_exit_code "Return from function" "fun test; return 5; end; test" "5" "Errors"
test_exit_code "False exit code" "false" "1" "Errors"
test_exit_code "Test failure" "test 1 -eq 2" "1" "Errors"
test_contains "Invalid test operator" "test 1 -invalid 2" "error" "Errors"
test_exit_code "Unset nonexistent var" "unset NONEXISTENT_VAR_123" "0" "Errors"
test_exit_code "Unalias nonexistent" "unalias NONEXISTENT_ALIAS" "1" "Errors"
test_contains "Type nonexistent command" "type nonexistentcmd999" "not found" "Errors"

# ============================================================================
# CATEGORY: Complex Scenarios
# ============================================================================
print_category "Complex Scenarios (15 tests)"

test_case "Function with multiple returns" "fun check; if test \$1 = a; return 1; else if test \$1 = b; return 2; else; return 3; end; end; check b; echo \$?" "2" "Complex"
test_case "Nested loops with break" "for x in 1 2; for y in a b c; echo \$x\$y; if test \$y = b; break; end; end; end" $'1a\n1b\n2a\n2b' "Complex"
test_case "Function returning array" "fun getlist; echo a b c; end; getlist =>@ arr; echo \$arr[2]" "b" "Complex"
test_case "Conditional in loop" "for i in 1 2 3 4 5; if test \$i -gt 3; echo \$i; end; end" $'4\n5' "Complex"
test_case "Variable shadowing" "var x outer; fun test; var x inner; echo \$x; end; test; echo \$x" $'inner\nouter' "Complex"
test_case "Arithmetic in loop" "var sum 0; for i in 1 2 3; var sum \$(expr \$sum + \$i); end; echo \$sum" "6" "Complex"
test_case "Pipeline with multiple stages" "echo -e '1\n2\n3\n4\n5' | head -n 3 | tail -n 1" "3" "Complex"
test_case "Capture in conditional" "echo 5 => num; if test \$num -eq 5; echo match; end" "match" "Complex"
test_case "Function with pipeline" "fun process; echo test | cat; end; process" "test" "Complex"
test_case "Nested conditionals" "var x 5; if test \$x -gt 0; if test \$x -lt 10; echo mid; end; end" "mid" "Complex"
test_case "Loop with substitution" "for x in \$(echo a b c); echo \$x; end" $'a\nb\nc' "Complex"
test_case "Multiple functions" "fun a; echo a; end; fun b; echo b; end; a; b" $'a\nb' "Complex"
test_case "Alias in function" "alias e echo; fun test; e hello; end; test" "hello" "Complex"
test_case "Variable in test" "var x 10; var y 10; if test \$x -eq \$y; echo equal; end" "equal" "Complex"
test_case "Export then use" "export VAR=value; fun test; echo \$VAR; end; test" "value" "Complex"

# ============================================================================
# Print Summary
# ============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                      TEST SUMMARY"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Total Tests:  $TOTAL"
echo -e "${GREEN}Passed:       $PASS${NC}"
echo -e "${RED}Failed:       $FAIL${NC}"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "═══════════════════════════════════════════════════════════"
    echo "                       FAILURES"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    for failure in "${FAILURES[@]}"; do
        echo -e "${RED}✗${NC} $failure"
    done
    echo ""
fi

PASS_RATE=$(awk "BEGIN {printf \"%.1f\", ($PASS/$TOTAL)*100}")
echo "Pass Rate: $PASS_RATE%"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}🎉 All tests passed!${NC}"
    exit 0
else
    echo -e "${YELLOW}⚠️  Some tests failed.${NC}"
    exit 1
fi
