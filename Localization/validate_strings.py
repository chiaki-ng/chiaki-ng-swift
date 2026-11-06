#!/usr/bin/env python3
"""Validate the canonical zh-Hans Localizable.strings table."""
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLE = ROOT / "Localization" / "zh-Hans.lproj" / "Localizable.strings"
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
PLACEHOLDER = re.compile(r"%(?:([0-9]+)\$)?(@|lld|ld|d|f)")


def decode(value: str) -> str:
    return json.loads('"' + value + '"')


def placeholders(value: str) -> Counter:
    # Ignore escaped percent signs, which represent a literal '%' in .strings.
    value = value.replace("%%", "")
    return Counter(match.group(2) for match in PLACEHOLDER.finditer(value))


def main() -> int:
    entries = {}
    duplicates = []
    malformed = []
    in_comment = False
    for line_number, line in enumerate(TABLE.read_text().splitlines(), 1):
        stripped = line.strip()
        if in_comment:
            if "*/" in stripped:
                in_comment = False
            continue
        if stripped.startswith("/*"):
            in_comment = "*/" not in stripped
            continue
        if not stripped:
            continue
        match = ENTRY.match(line)
        if match is None:
            malformed.append(line_number)
            continue
        key, value = map(decode, match.groups())
        if key in entries:
            duplicates.append((line_number, key))
        entries[key] = value

    placeholder_mismatches = [
        key for key, value in entries.items() if placeholders(key) != placeholders(value)
    ]
    if malformed or duplicates or placeholder_mismatches:
        if malformed:
            print("Malformed entries on lines:", ", ".join(map(str, malformed)))
        if duplicates:
            print("Duplicate keys:", ", ".join(repr(key) for _, key in duplicates))
        if placeholder_mismatches:
            print("Placeholder count/type mismatch:", ", ".join(repr(key) for key in placeholder_mismatches))
        return 1

    print(f"Validated {len(entries)} unique zh-Hans entries; placeholder counts match.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
