#!/usr/bin/env python3
"""
Comment-aware, string-aware Swift brace balance checker.

Usage:
    python3 scripts/balance.py path/to/file.swift

Exits 0 if balanced (depth == 0), exits 1 otherwise.

Correctly ignores braces inside:
  - // line comments
  - /* block comments */
  - "..." string literals (with backslash-escape handling)
"""
import sys


def check_balance(path: str) -> int:
    with open(path, "r") as f:
        text = f.read()

    depth = 0
    line = 1
    i = 0
    in_lc = False  # in line comment
    in_bc = False  # in block comment
    in_s = False   # in string literal
    esc = False    # last char was backslash inside string
    stack = []     # line numbers of unclosed `{`

    while i < len(text):
        c = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if c == "\n":
            line += 1
            in_lc = False
            esc = False
            i += 1
            continue
        if in_lc:
            i += 1
            continue
        if in_bc:
            if c == "*" and nxt == "/":
                in_bc = False
                i += 2
                continue
            i += 1
            continue
        if in_s:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_s = False
            i += 1
            continue

        if c == "/" and nxt == "/":
            in_lc = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            in_bc = True
            i += 2
            continue
        if c == '"':
            in_s = True
            i += 1
            continue

        if c == "{":
            stack.append(line)
            depth += 1
        elif c == "}":
            if stack:
                stack.pop()
            depth -= 1
        i += 1

    print(f"Depth: {depth}")
    if depth != 0:
        if depth > 0:
            print(f"Unclosed `{{` opened at lines: {stack[-min(5, len(stack)):]}")
        else:
            print(f"Extra `}}` — {abs(depth)} more closes than opens.")
        return 1
    print("OK — braces balanced.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: balance.py <path>", file=sys.stderr)
        sys.exit(2)
    sys.exit(check_balance(sys.argv[1]))
