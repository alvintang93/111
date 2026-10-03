#!/usr/bin/env python3
"""Fail if a user-facing Swift string literal implies diagnosis, illness detection,
guaranteed safety or injury prevention. Margin is a training/readiness aid based
on sensor readings; see docs/METHODOLOGY.md section 5."""
import pathlib
import re
import sys

BANNED = re.compile(
    r"\b(ill|illness|sick|diagnos\w*|disease|infection|injur\w*|medically|guarantee\w*|safety|safe to)\b",
    re.IGNORECASE,
)
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
# Software term for the developer screen the user asked for, not a health claim.
ALLOWED = re.compile(r"developer diagnostics", re.IGNORECASE)
ROOTS = ["MarginWatch", "MarginCore/Sources"]

failures = []
for root in ROOTS:
    for path in sorted(pathlib.Path(root).rglob("*.swift")):
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            for literal in STRING.findall(line):
                m = BANNED.search(ALLOWED.sub("", literal))
                if m:
                    failures.append(f"{path}:{n}: '{m.group(0)}' in \"{literal}\"")

if failures:
    print("Product-language check failed:")
    print("\n".join(failures))
    sys.exit(1)
print("Product-language check passed: no banned terms in user-facing Swift strings.")
