#!/usr/bin/env python3
"""Broad scan for every English UI string literal in Sources/.

Unlike extract_strings.py (which targets SwiftUI LocalizedStringKey call sites),
this scanner collects ALL human-readable literals including ones assigned to
String constants / enum display names / custom component arguments, plus the
full text of multi-literal `+` concatenations. Output is a worklist for
zh-Hans.lproj/Localizable.strings.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Sources"
OUT = ROOT / ".build" / "localization"

LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
# a sequence of adjacent literals joined by + (with whitespace/newlines)
CONCAT = re.compile(r'(?:"(?:[^"\\\n]|\\.)*"(?:\s*\+\s*"(?:[^"\\\n]|\\.)*")+)', re.S)

TECHNICAL = re.compile(
    r"https?://|www\.|^/|\.swift$|\.json$|\.png$|\.log$|"
    r"^io\.|^dev\.|^com\.|^org\.|^[A-Za-z0-9_.-]+\.(?:v\d+|active|input|clock|network|path)$|"
    r"\bSELECT\b|\bINSERT\b|\bCREATE TABLE\b|%[0-9]*[.0-9]*[dfs@]|\\n|^\\|"
    r"^[A-Za-z0-9_]+=[^ ]|->|:=|\bTODO\b|^\s*$"
)


def unescape(raw: str) -> str:
    try:
        return json.loads(f'"{raw}"')
    except Exception:
        return ""


def likely_ui(s: str) -> bool:
    if not s or len(s) > 1200 or len(s) < 2:
        return False
    if TECHNICAL.search(s):
        return False
    if not re.search(r"[A-Za-z]", s):
        return False
    # SF symbols / identifiers / code-ish tokens
    if re.fullmatch(r"[a-z][a-z0-9]*(?:\.[a-z0-9-]+)+", s):
        return False
    if re.fullmatch(r"[a-z0-9_]+(?:_[a-z0-9]+)+", s):
        return False
    # single word: only title-case labels (Picture, Resolution, ...)
    if " " not in s.strip():
        return bool(re.fullmatch(r"[A-Z][A-Za-z0-9+’'()\-\u2013\u2014]*", s)) or s in ("30 fps", "60 fps")
    return True


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    found = {}
    for path in sorted(SRC.rglob("*.swift")):
        text = path.read_text()
        rel = str(path.relative_to(ROOT))
        # full concatenations first
        spans = []
        for m in CONCAT.finditer(text):
            parts = LITERAL.findall(m.group(0))
            full = "".join(unescape(p) for p in parts)
            if "\\(" not in m.group(0):
                found.setdefault(full, set()).add(rel + ":concat")
            spans.append(m.span())
        # individual literals
        for m in LITERAL.finditer(text):
            if any(a <= m.start() < b for a, b in spans):
                continue
            raw = m.group(1)
            if "\\(" in raw:
                continue
            s = unescape(raw)
            if likely_ui(s):
                found.setdefault(s, set()).add(rel)

    # existing dictionary keys
    existing = set()
    strings_file = Path(__file__).parent / "zh-Hans.lproj" / "Localizable.strings"
    for m in re.finditer(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', strings_file.read_text(), re.M):
        existing.add(unescape(m.group(1)))

    missing = {k: v for k, v in found.items() if k not in existing and likely_ui(k)}
    with (OUT / "missing_ui_strings.txt").open("w") as f:
        for k in sorted(missing):
            f.write(json.dumps(k, ensure_ascii=False)[1:-1] + "\n")
    print(f"total literals: {len(found)}")
    print(f"already translated: {len(existing)}")
    print(f"missing UI candidates: {len(missing)}")
    print("wrote .build/localization/missing_ui_strings.txt")


if __name__ == "__main__":
    main()
