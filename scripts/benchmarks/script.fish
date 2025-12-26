#!/usr/bin/env fish
# Benchmark: while loop with function call (100k iterations)

function inc
    set -g i (math $i + 1)
end

set -g i 0
while test $i -lt 100000
    inc
end
