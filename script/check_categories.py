#!/usr/bin/env python3
import re
import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ClipFlow/Models/ClipboardItem.swift"


def extract_categorize(source: str) -> str:
    match = re.search(r"\n\s{4}static func categorize\(_ text: String\) -> Category \{", source)
    if not match:
        raise SystemExit("categorize function not found")

    start = match.start() + 1
    depth = 0
    seen_open = False
    for index in range(start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
            seen_open = True
        elif char == "}":
            depth -= 1
            if seen_open and depth == 0:
                return source[start : index + 1]

    raise SystemExit("categorize function end not found")


categorize = extract_categorize(SOURCE.read_text())

tests = [
    ("Contact me at a.b+tag@example.co.uk", "email"),
    ("Visit example.com/path?q=1", "url"),
    ("docs.example.xyz/guide", "url"),
    ("localhost:3000/api", "url"),
    ("127.0.0.1:8000/api", "url"),
    ("npm install sqlite3", "code"),
    ("git commit -m fix", "code"),
    ("SELECT * FROM users WHERE id = 1", "code"),
    ("hello (world)", "english"),
    ("hello from home", "english"),
    ("see [attachment]", "english"),
    ("constellation; stars", "english"),
    ("+86 138 0013 8000", "number"),
    ("2026-06-30 12:30", "number"),
    ("192.168.1.1", "number"),
]

test_lines = "\n".join(
    f"check({json.dumps(sample, ensure_ascii=False)}, {json.dumps(expected)})"
    for sample, expected in tests
)

swift = f"""
import Foundation

enum ClipboardItem {{
    enum Category: String {{
        case url
        case email
        case code
        case number
        case chinese
        case english
        case mixed
        case other
    }}

{categorize}
}}

func check(_ text: String, _ expected: String) {{
    let actual = ClipboardItem.categorize(text).rawValue
    if actual != expected {{
        print("FAIL: \\(text) -> \\(actual), expected \\(expected)")
        exit(1)
    }}
}}

{test_lines}
print("category checks passed")
"""

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as handle:
    handle.write(swift)
    path = handle.name

subprocess.run(["swift", path], check=True)
