---
description: Verify Swift brace balance in AMCreditTrackerApp.swift after edits
---

Run `python3 scripts/balance.py AMCreditTracker/AMCreditTrackerApp.swift` and report the depth.

Depth must be exactly 0. If non-zero, find the imbalance:
1. Show the line numbers of the last 5 unclosed `{` (if depth > 0) or recently-closed `}` (if depth < 0)
2. Don't try to "guess fix" — pinpoint the actual problem area in the file and ask which edit introduced it

This script is comment-aware and string-aware, so braces inside `//` comments, `/* */` blocks, and `"..."` strings are correctly ignored.
