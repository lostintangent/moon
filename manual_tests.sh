#!/bin/bash
# Manual interactive dogfooding tests
# These test scenarios that are hard to automate

OSHEN="/Users/lostintangent/Desktop/oshen/zig-out/bin/oshen"

echo "════════════════════════════════════════════════════════"
echo "Manual Dogfooding Test Results"
echo "════════════════════════════════════════════════════════"
echo ""

# Helper function
run_test() {
    local desc="$1"
    local cmd="$2"
    echo "Test: $desc"
    echo "  Command: $cmd"
    echo "  Output:"
    result=$($OSHEN -c "$cmd" 2>&1)
    echo "    $result"
    echo ""
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "GLOB EXPANSION TESTS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
mkdir -p /tmp/oshen_glob_manual
cd /tmp/oshen_glob_manual
touch file1.txt file2.txt file3.txt test.md readme.md

run_test "Glob with echo" "cd /tmp/oshen_glob_manual; echo *.txt"
run_test "Glob with ls" "cd /tmp/oshen_glob_manual; ls *.txt"
run_test "Glob with for loop" "cd /tmp/oshen_glob_manual; for f in *.txt; echo \$f; end"
run_test "Glob with cat" "cd /tmp/oshen_glob_manual; echo test > a.txt; cat *.txt"
run_test "Glob no matches" "cd /tmp/oshen_glob_manual; echo *.xyz"
run_test "Glob with braces" "cd /tmp/oshen_glob_manual; echo {*.txt}"
run_test "Glob pattern in variable" "cd /tmp/oshen_glob_manual; var pat '*.txt'; echo \$pat"
run_test "Multiple glob patterns" "cd /tmp/oshen_glob_manual; echo *.txt *.md"
run_test "Glob with path" "echo /tmp/oshen_glob_manual/*.txt"
run_test "Recursive glob **" "cd /tmp; echo oshen_glob_manual/**/*.txt"

cd - > /dev/null
rm -rf /tmp/oshen_glob_manual

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PATH_PREPEND BUILTIN TESTS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "path_prepend single path" "var PATH /usr/bin; path_prepend PATH /custom/bin; echo \$PATH"
run_test "path_prepend multiple paths" "var PATH /usr/bin; path_prepend PATH /a /b /c; echo \$PATH"
run_test "path_prepend with deduplication" "var PATH /usr/bin:/bin; path_prepend PATH /usr/bin /new; echo \$PATH"
run_test "path_prepend colon-separated" "export PATH /a:/b:/c; path_prepend PATH /x; echo \$PATH"
run_test "path_prepend empty var" "var EMPTY; path_prepend EMPTY /first /second; echo \$EMPTY"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST BUILTIN EDGE CASES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "test with -a operator" "test -e /tmp -a -d /tmp; echo \$?"
run_test "test with -o operator" "test -f /nonexistent -o -d /tmp; echo \$?"
run_test "test with ! negation inside" "test ! 1 -eq 2; echo \$?"
run_test "test complex condition" "test -d /tmp -a ! -f /tmp; echo \$?"
run_test "bracket test with -a" "[ -e /tmp -a -d /tmp ]; echo \$?"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VARIABLE SCOPING TESTS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Variable shadowing in function" "var x outer; fun test; var x inner; echo \$x; end; test; echo \$x"
run_test "Modify outer var from function" "var x 1; fun modify; var x 2; end; modify; echo \$x"
run_test "Function local vs global" "var global 1; fun test; var local 2; echo \$global \$local; end; test; echo \$local"
run_test "Nested function scoping" "var x 1; fun outer; var x 2; fun inner; var x 3; echo \$x; end; inner; echo \$x; end; outer; echo \$x"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ALIAS EDGE CASES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Alias with pipes" "alias lsl 'ls | head -n 5'; cd /tmp; lsl"
run_test "Alias with redirects" "alias logit 'echo logged'; logit"
run_test "Alias recursion protection" "alias echo 'echo nested'; echo test"
run_test "Alias in function" "alias greet 'echo hello'; fun test; greet; end; test"
run_test "Alias with variables" "var name world; alias sayhello 'echo hello'; sayhello \$name"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SPECIAL CHARACTER HANDLING"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Ampersand in string" 'echo "Tom & Jerry"'
run_test "Greater than in string" 'echo "5 > 3"'
run_test "Pipe in string" 'echo "a | b"'
run_test "Dollar in single quotes" "echo '\$USER'"
run_test "Backtick in string" 'echo "legacy \`command\`"'
run_test "Semicolon in string" 'echo "a; b; c"'
run_test "Hash in string" 'echo "hashtag #test"'
run_test "Parentheses in string" 'echo "func(arg)"'
run_test "Brackets in string" 'echo "array[0]"'
run_test "Curly braces in string" 'echo "{expansion}"'

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "MULTILINE AND COMPLEX SYNTAX"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Command with newlines" 'echo a; echo b; echo c'
run_test "If statement multiline" 'if test 1 -eq 1
    echo yes
end'
run_test "For loop multiline" 'for x in a b c
    echo $x
end'
run_test "Function multiline" 'fun test
    echo line1
    echo line2
end
test'

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ECHO BUILTIN SPECIFICS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "echo with -n flag" "echo -n test"
run_test "echo with -e flag" "echo -e 'a\\nb'"
run_test "echo with multiple -n" "echo -n -n test"
run_test "echo with escape sequences" 'echo "\\n\\t\\r"'
run_test "echo with ANSI colors" 'echo "\\e[31mRed\\e[0m"'
run_test "echo empty" "echo"
run_test "echo multiple empty strings" 'echo "" "" ""'

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PIPELINE COMBINATIONS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Pipe with variable assignment" "echo test | cat => result; echo \$result"
run_test "Pipe with array capture" "echo -e 'a\\nb' | cat =>@ arr; echo \$arr[1]"
run_test "Multiple pipes with capture" "echo test | cat | cat => x; echo \$x"
run_test "Pipe stderr to stdout" "bash -c 'echo err >&2' 2>&1 | cat"
run_test "Pipe with redirection" "echo data | cat > /tmp/oshen_pipe_test; cat /tmp/oshen_pipe_test; rm /tmp/oshen_pipe_test"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RETURN AND EXIT CODE HANDLING"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Return with code" "fun test; return 42; end; test; echo \$?"
run_test "Return in if branch" "fun check; if test \$1 = yes; return 0; else; return 1; end; end; check no; echo \$?"
run_test "Return in else if" "fun check; if test \$1 = a; return 1; else if test \$1 = b; return 2; else; return 3; end; end; check b; echo \$?"
run_test "Multiple returns" "fun test; if true; return 5; end; return 10; end; test; echo \$?"
run_test "Return without value" "fun test; return; end; test; echo \$?"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ARITHMETIC AND EXTERNAL COMMANDS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "expr addition" "expr 5 + 3"
run_test "expr subtraction" "expr 10 - 4"
run_test "expr multiplication" "expr 6 \\* 7"
run_test "expr division" "expr 20 / 4"
run_test "expr in variable" "var result \$(expr 2 + 2); echo \$result"
run_test "expr in loop" "for i in 1 2 3; echo \$(expr \$i \\* 2); end"
run_test "wc line count" "echo -e 'a\\nb\\nc' | wc -l"
run_test "head command" "echo -e '1\\n2\\n3\\n4' | head -n 2"
run_test "tail command" "echo -e '1\\n2\\n3\\n4' | tail -n 2"
run_test "grep simple" "echo -e 'foo\\nbar\\nbaz' | grep bar"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STRING MANIPULATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Concatenate variables" "var a hello; var b world; echo \$a\$b"
run_test "Variable in middle of string" "var x test; echo pre\${x}post"
run_test "Multiple concatenations" "var a 1; var b 2; var c 3; echo \$a-\$b-\$c"
run_test "Empty string concat" "var empty; var full test; echo \$empty\$full"
run_test "String with numbers" "var num 42; echo value_\$num"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "COMMAND CHAINING"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Sequential with semicolon" "echo a; echo b; echo c"
run_test "AND with success" "true && echo success"
run_test "AND with failure" "false && echo nope"
run_test "OR with success" "true || echo nope"
run_test "OR with failure" "false || echo fallback"
run_test "Chained AND" "true && true && echo yes"
run_test "Chained OR" "false || false || echo last"
run_test "Mixed AND OR" "false || true && echo mixed"
run_test "Word and" "true and echo yes"
run_test "Word or" "false or echo yes"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ARRAY ADVANCED OPERATIONS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Array modification" "var arr a b c; var arr \$arr d e; echo \$arr"
run_test "Array from command" "var files \$(ls /tmp | head -n 3); echo \$files"
run_test "Array slice assignment" "var nums 1 2 3 4 5; echo \$nums[2..4]"
run_test "Array negative slice" "var letters a b c d e; echo \$letters[-3..-1]"
run_test "Array cartesian product" "var pre a b; var post 1 2; echo \$pre\$post"
run_test "Empty array handling" "var empty; for x in \$empty; echo \$x; end"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FILE OPERATIONS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p /tmp/oshen_fileops
cd /tmp/oshen_fileops

run_test "Create file with redirect" "echo content > testfile.txt; cat testfile.txt"
run_test "Append to file" "echo line1 > append.txt; echo line2 >> append.txt; cat append.txt"
run_test "Read file with <" "echo data > input.txt; cat < input.txt"
run_test "Overwrite file" "echo old > over.txt; echo new > over.txt; cat over.txt"
run_test "Check file exists" "touch exists.txt; test -e exists.txt; echo \$?"
run_test "Check file type" "touch regular.txt; test -f regular.txt; echo \$?"
run_test "Check directory" "mkdir subdir; test -d subdir; echo \$?"
run_test "File size check" "echo nonempty > size.txt; test -s size.txt; echo \$?"

cd - > /dev/null
rm -rf /tmp/oshen_fileops

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CONTROL FLOW EDGE CASES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Empty if body" "if true; end; echo after"
run_test "Empty else body" "if false; else; end; echo after"
run_test "Nested if 3 levels" "if true; if true; if true; echo deep; end; end; end"
run_test "For break immediate" "for x in a b c; break; end; echo done"
run_test "While with counter" "var n 3; while test \$n -gt 0; echo \$n; var n \$(expr \$n - 1); end"
run_test "For with continue all" "for x in a b c; continue; echo never; end; echo done"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "COMMAND NOT FOUND HANDLING"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Nonexistent command" "nonexistent_cmd_12345"
run_test "Typo in builtin" "ecko test"
run_test "Command after error" "badcmd; echo \$?"
run_test "Pipeline with bad command" "echo test | badcmd 2>&1"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ENVIRONMENT INTERACTION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_test "Access HOME" "echo \$HOME"
run_test "Access PATH" "echo \$PATH | head -c 50"
run_test "Set custom env var" "export MYVAR=test123; echo \$MYVAR"
run_test "Override env var" "export HOME=/custom; echo \$HOME"
run_test "Unset env var" "export TESTVAR=value; unset TESTVAR; echo \$TESTVAR"

echo ""
echo "════════════════════════════════════════════════════════"
echo "Manual testing complete!"
echo "════════════════════════════════════════════════════════"
