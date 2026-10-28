"""Preserve bounded fill defaults when Zig forwards arguments at execution time."""

import os
import sys

args = sys.argv[1:]
separator = args.index("--")
command, selectors = args[:separator], args[separator + 1 :]
if not selectors:
    selectors = ["tests"] if "--evmz-diff-output" in command else [
        "--fork", "Shanghai", "tests/shanghai/eip3855_push0/test_push0.py", "-k", "key_sstore"
    ]
os.execvp(command[0], command + selectors)
