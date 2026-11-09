#!/usr/bin/python3
from os import system
from sys import argv
filter = argv[1]
fuzz_count = argv[2]
fuzz_buflen = None
if len(argv) > 3:
    fuzz_buflen = argv[3]
else:
    fuzz_buflen = 32
system(f"zig build --fuzz={fuzz_count} -Dfuzzlen={fuzz_buflen} -Doptimize=ReleaseFast -Dtest-filter={filter} test")
