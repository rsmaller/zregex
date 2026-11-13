#!/usr/bin/python3
from sys import argv
from os import system, path

def main():
    if len(argv) < 3:
        print(f"Usage: {path.basename(argv[0])} <filters> <fuzz_count> [fuzz_buflen]")
        return
    filter = argv[1]
    fuzz_count = argv[2]
    fuzz_buflen = None
    if len(argv) > 3:
        fuzz_buflen = argv[3]
    else:
        fuzz_buflen = 32
    if (fuzz_count == "unlimited"):
        system(f"zig build --fuzz -Dfuzzlen={fuzz_buflen} -Doptimize=ReleaseFast -Dtest-filter={filter} test")
    else:
        system(f"zig build --fuzz={fuzz_count} -Dfuzzlen={fuzz_buflen} -Doptimize=Debug -Dtest-filter={filter} test")

main()
