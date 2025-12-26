#!/usr/bin/env elvish
# Benchmark: while loop with function call (100k iterations)

var i = 0

fn inc {
    set i = (+ $i 1)
}

while (< $i 100000) {
    inc
}
