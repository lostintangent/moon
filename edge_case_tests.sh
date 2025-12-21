#!/bin/bash
# Additional edge case exploration

OSHEN="/Users/lostintangent/Desktop/oshen/zig-out/bin/oshen"

echo "═══════════════════════════════════════════════"
echo "  ADDITIONAL EDGE CASE EXPLORATIONS"
echo "═══════════════════════════════════════════════"
echo ""

test_it() {
    local desc="$1"
    local cmd="$2"
    echo "━━━ $desc"
    echo "CMD: $cmd"
    result=$($OSHEN -c "$cmd" 2>&1)
    exitcode=$?
    echo "OUT: $result"
    echo "EXIT: $exitcode"
    echo ""
}

echo "▶ GLOBBING SURPRISES"
test_it "Echo with glob (reported issue)" "cd /tmp; mkdir -p oshen_edge; cd oshen_edge; touch a.txt b.txt; echo *.txt"
test_it "Glob in quotes should be literal" "cd /tmp/oshen_edge; echo '*.txt'"
test_it "Glob in double quotes" 'cd /tmp/oshen_edge; echo "*.txt"'
test_it "Glob with set/var command" "cd /tmp/oshen_edge; var files *.txt; echo \$files"

echo "▶ RETURN VALUE HANDLING"
test_it "Return with specific code" "fun test; return 42; end; test; echo \$?"
test_it "Return in nested if" "fun test; if true; if true; return 99; end; end; end; test; echo \$?"
test_it "Return early in function" "fun test; echo before; return 7; echo after; end; test; echo \$?"
test_it "Function without explicit return" "fun test; echo done; end; test; echo \$?"
test_it "Return 0 explicitly" "fun test; return 0; end; test; echo \$?"

echo "▶ VARIABLE SCOPING ISSUES"
test_it "Function modifies global" "var x outer; fun change; var x inner; end; change; echo \$x"
test_it "Access undefined variable" "echo \$UNDEFINED_VAR_XYZ"
test_it "Variable in subshell" "var x parent; bash -c 'echo \$x'"
test_it "Export then modify" "export X=1; var X 2; echo \$X"

echo "▶ ALIAS ISSUES"
test_it "Alias used in function fails" "alias greet 'echo hello'; fun test; greet; end; test"
test_it "Alias expansion with args" "alias ll 'ls -la'; type ll"
test_it "Recursive alias" "alias e 'echo'; alias e 'e recursive'; e test"

echo "▶ TEST BUILTIN PROBLEMS"
test_it "Negation with ! outside test" "if ! test 1 -eq 2; echo ok; end"
test_it "Test with -a (AND)" "test 1 -eq 1 -a 2 -eq 2; echo \$?"
test_it "Test with -o (OR)" "test 1 -eq 2 -o 2 -eq 2; echo \$?"
test_it "Test ! inside" "test ! -f /nonexistent; echo \$?"

echo "▶ ECHO -e FLAG"
test_it "Echo -e for escape sequences" "echo -e 'a\\nb\\nc'"
test_it "Echo with -n and -e" "echo -n -e 'test\\n'"
test_it "Echo -e to array capture" "echo -e 'x\\ny\\nz' =>@ arr; echo \$arr"

echo "▶ MULTILINE FUNCTION DEFINITIONS"
test_it "Multiline function with newlines" $'fun test\n    echo line1\n    echo line2\nend\ntest'
test_it "Function defined over multiple statements" "fun greet; echo hello; echo world; end; greet"

echo "▶ BRACED VARIABLE INDEXING"
test_it "Braced index syntax" 'var arr a b c; echo ${arr[2]}'
test_it "Braced variable without index" 'var x test; echo ${x}'
test_it "Nested brace with var" 'var items a b; echo x_${items}_y'

echo "▶ EMPTY BRACE EXPANSION"
test_it "Empty braces" "echo {}"
test_it "Single element braces" "echo {a}"
test_it "Braces with only comma" "echo {,}"

echo "▶ EXPR ESCAPING"
test_it "Expr multiply with backslash" 'expr 6 \* 7'
test_it "Expr multiply without escape" 'expr 6 "*" 7'
test_it "Expr in backticks (if supported)" 'var x $(expr 3 + 4); echo $x'

echo "▶ FOR LOOP EDGE CASES"
test_it "For loop output to var" 'for x in a b c; echo $x; end => out; echo $out'
test_it "For loop capture array" 'for x in 1 2 3; echo $x; end =>@ nums; echo $nums'
test_it "Nested for with same variable" "for x in 1 2; for x in a b; echo \$x; end; end"

echo "▶ PIPELINE WITH CAPTURES"
test_it "Pipe then capture" "echo test | cat => x; echo \$x"
test_it "Multiple captures in sequence" "echo a => x; echo b => y; echo \$x \$y"
test_it "Capture then pipe" "echo data => temp; echo \$temp | cat"

echo "▶ STRING HANDLING"
test_it "String with literal backslash" 'echo "C:\\Users\\test"'
test_it "String with single backslash" "echo 'C:\\path'"
test_it "Empty string vs no string" 'var empty ""; echo [$empty]'
test_it "Multiple spaces collapsed" "echo a         b"

echo "▶ UNSET EDGE CASES"
test_it "Unset nonexistent returns what" "unset DOESNOTEXIST123; echo \$?"
test_it "Unset then access" "var x test; unset x; echo [\$x]"
test_it "Unset env var persists" "export TESTVAR=val; unset TESTVAR; echo \$TESTVAR"

echo "▶ CONDITIONAL EDGE CASES"
test_it "Empty if block" "if true; end"
test_it "If with only comment" "if true; end"
test_it "Else if without final else" "if false; echo a; else if false; echo b; end"

echo "▶ ARITHMETIC LIMITATIONS"
test_it "Can we do math without expr?" "var x 5; var y 3; echo \$((\$x + \$y))"
test_it "BC calculator if available" "echo '5+3' | bc"
test_it "Let command" "let x=5+3; echo \$x"

echo "▶ COMMENT HANDLING"
test_it "Inline comment after command" "echo test # this is a comment"
test_it "Comment at start of line" "# comment\necho visible"
test_it "Multiple hashes" "echo test ## double hash"
test_it "Hash in string" 'echo "hashtag #coding"'

echo "▶ BACKGROUND JOBS (if supported)"
test_it "Background job syntax" "sleep 0.1 &; jobs"
test_it "Disown job" "sleep 1 & disown"

echo "▶ SUBSHELL BEHAVIOR"
test_it "Subshell with parentheses" "(echo subshell)"
test_it "Variable in subshell" "var x outer; (var x inner; echo \$x); echo \$x"

echo "▶ SPECIAL VARIABLES"
test_it "Dollar dollar (PID)" 'echo $$'
test_it "Dollar hash (arg count) outside function" 'echo $#'
test_it "Dollar star outside function" 'echo $*'
test_it "Dollar at outside function" 'echo $@'

echo "▶ PATH EXPANSION"
test_it "Tilde at start" "echo ~"
test_it "Tilde in middle (should not expand)" "echo foo~bar"
test_it "Tilde with username" "echo ~root"
test_it "Double tilde" "echo ~~"

echo "▶ WHITESPACE ODDITIES"
test_it "Tab as separator" $'echo\ta\tb'
test_it "Mixed spaces and tabs" $'echo   \t   test'
test_it "Leading whitespace in command" "   echo test"
test_it "Trailing whitespace" "echo test   "

echo "▶ EXIT AND RETURN STATUS"
test_it "Exit in subcommand" "bash -c 'exit 42'; echo \$?"
test_it "False then status" "false; echo \$?"
test_it "True then status" "true; echo \$?"
test_it "Multiple status checks" "true; echo \$?; false; echo \$?"

echo "▶ TYPE COMMAND VARIANTS"
test_it "Type builtin" "type echo"
test_it "Type alias" "alias x='echo y'; type x"
test_it "Type function" "fun f; echo hi; end; type f"
test_it "Type external command" "type ls"
test_it "Type nonexistent" "type nonexistentcmd999"

echo "▶ CD COMMAND EDGE CASES"
test_it "CD to nonexistent" "cd /nonexistent/path/xyz; echo \$?"
test_it "CD with no args" "cd; pwd"
test_it "CD to -" "cd /tmp; cd -; pwd"
test_it "CD to .." "cd /tmp; cd ..; pwd"
test_it "CDPATH variable" "export CDPATH=/tmp:/usr; cd oshen_edge 2>&1"

echo "▶ SOURCE COMMAND"
echo "echo sourced" > /tmp/oshen_source_test.wave
test_it "Source a file" "source /tmp/oshen_source_test.wave"
test_it "Source nonexistent" "source /nonexistent/file.wave 2>&1"
rm -f /tmp/oshen_source_test.wave

echo "▶ EVAL COMMAND"
test_it "Eval simple" "eval 'echo evaluated'"
test_it "Eval with variable" "var cmd 'echo test'; eval \$cmd"
test_it "Eval nested" "eval 'eval echo double'"

echo "▶ ARRAY SLICING EDGE CASES"
test_it "Slice with 0 index" "var arr a b c; echo \$arr[0..2]"
test_it "Slice beyond bounds" "var arr a b c; echo \$arr[1..10]"
test_it "Negative to negative" "var arr a b c d e; echo \$arr[-3..-1]"
test_it "Open-ended negative slice" "var arr a b c d; echo \$arr[-2..]"

echo "▶ HEREDOC (if supported)"
test_it "Heredoc syntax" "cat << EOF\nline1\nline2\nEOF"

echo "▶ COMMAND SUBSTITUTION EDGE CASES"
test_it "Empty command substitution" 'echo x$(echo)y'
test_it "Command sub with newlines" 'echo $(echo -e "a\nb")'
test_it "Nested command substitution 3 levels" 'echo $(echo $(echo $(echo deep)))'

rm -rf /tmp/oshen_edge

echo ""
echo "═══════════════════════════════════════════════"
echo "Edge case exploration complete!"
echo "═══════════════════════════════════════════════"
