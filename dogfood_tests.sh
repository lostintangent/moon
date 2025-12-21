#!/bin/bash

# Comprehensive dogfooding tests for Oshen CLI
# This script tests various features and edge cases

OSHEN="./zig-out/bin/oshen"
FAILED=0
PASSED=0

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

test_case() {
    local name="$1"
    local cmd="$2"
    local expected="$3"

    echo -n "Testing: $name ... "
    actual=$($OSHEN -c "$cmd" 2>&1)

    if [ "$actual" = "$expected" ]; then
        echo -e "${GREEN}PASS${NC}"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Command: $cmd"
        echo "  Expected: $expected"
        echo "  Actual: $actual"
        ((FAILED++))
    fi
}

test_case_contains() {
    local name="$1"
    local cmd="$2"
    local expected_substring="$3"

    echo -n "Testing: $name ... "
    actual=$($OSHEN -c "$cmd" 2>&1)

    if [[ "$actual" == *"$expected_substring"* ]]; then
        echo -e "${GREEN}PASS${NC}"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Command: $cmd"
        echo "  Expected to contain: $expected_substring"
        echo "  Actual: $actual"
        ((FAILED++))
    fi
}

test_exit_code() {
    local name="$1"
    local cmd="$2"
    local expected_code="$3"

    echo -n "Testing: $name ... "
    $OSHEN -c "$cmd" > /dev/null 2>&1
    actual_code=$?

    if [ "$actual_code" = "$expected_code" ]; then
        echo -e "${GREEN}PASS${NC}"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Command: $cmd"
        echo "  Expected exit code: $expected_code"
        echo "  Actual exit code: $actual_code"
        ((FAILED++))
    fi
}

echo -e "${YELLOW}=== Basic Commands ===${NC}"
test_case "Simple echo" "echo hello" "hello"
test_case "Echo with multiple args" "echo hello world" "hello world"
test_case "Echo -n flag" "echo -n test" "test"

echo -e "\n${YELLOW}=== Variables ===${NC}"
test_case "Simple var" "var x 42; echo \$x" "42"
test_case "List var" "var nums 1 2 3; echo \$nums" "1 2 3"
test_case "Var expansion in quotes" "var name Alice; echo \"Hello, \$name\"" "Hello, Alice"
test_case "Single quotes literal" "echo '\$notexpanded'" "\$notexpanded"

echo -e "\n${YELLOW}=== Array Indexing ===${NC}"
test_case "Array first element" "var arr a b c; echo \$arr[1]" "a"
test_case "Array second element" "var arr a b c; echo \$arr[2]" "b"
test_case "Array last element" "var arr a b c; echo \$arr[-1]" "c"
test_case "Array slice" "var arr a b c d; echo \$arr[2..3]" "b c"
test_case "Array slice to end" "var arr a b c d; echo \$arr[2..]" "b c d"
test_case "Array slice from start" "var arr a b c d; echo \$arr[..2]" "a b"

echo -e "\n${YELLOW}=== Environment Variables ===${NC}"
test_case "Export simple" "export FOO bar; echo \$FOO" "bar"
test_case "Export with equals" "export FOO=bar; echo \$FOO" "bar"

echo -e "\n${YELLOW}=== Control Flow ===${NC}"
test_case "If true" "if true; echo yes; end" "yes"
test_case "If false with else" "if false; echo no; else; echo yes; end" "yes"
test_case "If else if" "var x 15; if test \$x -lt 10; echo small; else if test \$x -lt 20; echo medium; end" "medium"

echo -e "\n${YELLOW}=== Loops ===${NC}"
test_case "For loop" "for x in 1 2 3; echo \$x; end" "1\n2\n3"
test_case "While loop" "var i 3; while test \$i -gt 0; echo \$i; var i 0; end" "3"

echo -e "\n${YELLOW}=== Functions ===${NC}"
test_case "Simple function" "fun greet; echo hello; end; greet" "hello"
test_case "Function with args" "fun say; echo \$1; end; say world" "world"
test_case "Function with argv" "fun myfunc; echo \$argv[1]; end; myfunc foo" "foo"

echo -e "\n${YELLOW}=== Conditional Chaining ===${NC}"
test_exit_code "true && true succeeds" "true && true" 0
test_exit_code "true && false fails" "true && false" 1
test_exit_code "false || true succeeds" "false || true" 0
test_case "And word form" "true and echo yes" "yes"
test_case "Or word form" "false or echo yes" "yes"

echo -e "\n${YELLOW}=== Test Builtin ===${NC}"
test_exit_code "test -n non-empty" "test -n hello" 0
test_exit_code "test -z empty" "test -z \"\"" 0
test_exit_code "test equality" "test foo = foo" 0
test_exit_code "test inequality" "test foo != bar" 0
test_exit_code "test numeric eq" "test 5 -eq 5" 0
test_exit_code "test numeric lt" "test 3 -lt 5" 0
test_exit_code "test numeric gt" "test 7 -gt 5" 0

echo -e "\n${YELLOW}=== Builtins ===${NC}"
test_case "pwd builtin" "cd /tmp; pwd" "/private/tmp"
test_case "true builtin" "true; echo \$?" "0"
test_case "false builtin" "false; echo \$?" "1"

echo -e "\n${YELLOW}=== Special Variables ===${NC}"
test_case "Exit status" "true; echo \$?" "0"
test_case "Home expansion" "echo ~" "$HOME"

echo -e "\n${YELLOW}=== Escaping ===${NC}"
test_case "Backslash escape dollar" "echo \\\$literal" "\$literal"
test_case "Escaped newline in quotes" "echo \"line1\\nline2\"" "line1\nline2"
test_case "Escaped tab in quotes" "echo \"a\\tb\"" "a\tb"

echo -e "\n${YELLOW}=== Edge Cases ===${NC}"
test_case "Empty var" "var x; echo \"\$x\"" ""
test_case "Unset var" "echo \"\$NONEXISTENT\"" ""
test_case "Multiple spaces" "echo a    b" "a b"
test_case "Trailing whitespace" "echo hello  " "hello"

echo -e "\n${YELLOW}=== Command Substitution ===${NC}"
test_case "Basic substitution" "echo \$(echo hello)" "hello"
test_case "Substitution in string" "echo \"result: \$(echo test)\"" "result: test"

echo -e "\n${YELLOW}=== Glob Patterns ===${NC}"
# Create test files
mkdir -p /tmp/oshen_test
touch /tmp/oshen_test/{a,b,c}.txt
test_case_contains "Glob star" "cd /tmp/oshen_test; echo *.txt" ".txt"
rm -rf /tmp/oshen_test

echo -e "\n${YELLOW}=== Brace Expansion ===${NC}"
test_case "Simple brace" "echo {a,b,c}" "a b c"
test_case "Brace with prefix" "echo test_{1,2,3}" "test_1 test_2 test_3"
test_case "Brace with suffix" "echo {x,y,z}_end" "x_end y_end z_end"

echo -e "\n${YELLOW}=== Aliases ===${NC}"
test_case "Define and use alias" "alias ll 'echo listed'; ll" "listed"

echo -e "\n${YELLOW}=== Comments ===${NC}"
test_case "Inline comment" "echo hello # this is ignored" "hello"
test_case "Full line comment" "# comment\necho world" "world"

echo -e "\n${YELLOW}=== Error Handling ===${NC}"
test_exit_code "Unknown command fails" "nonexistentcommand123" 127

echo ""
echo "================================"
echo -e "Total: $((PASSED + FAILED))"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo "================================"

exit $FAILED
