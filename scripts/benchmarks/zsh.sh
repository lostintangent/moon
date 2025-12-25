#!/bin/zsh
# Benchmark: while loop with function call (100k iterations)

inc() {
    (( i++ ))
}

i=0
while (( i < 100000 )); do
    inc
done
