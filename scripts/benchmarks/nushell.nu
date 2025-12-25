#!/usr/bin/env nu
# Benchmark: while loop with function call (100k iterations)

def inc [] {
    $env.i = $env.i + 1
}

$env.i = 0
while $env.i < 100000 {
    inc
}
