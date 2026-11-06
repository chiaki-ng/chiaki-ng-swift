#!/usr/bin/env python3
"""Extract user-facing SwiftUI string literals for localization.

Scans Sources/ for string literals passed to SwiftUI APIs that accept
LocalizedStringKey (auto-localized against Localizable.strings), and emits:

  .build/localization/keys.txt              unique keys (one per line, escaped)
  .build/localization/interpolated.tsv      keys with format specifiers + source refs

Keys equal the English source text, so zh-Hans/Localizable.strings only needs
the key -> Chinese mapping. Plain-literal keys are auto-generated; interpolated
keys (with %@, %lld, ...) are listed separately for review.
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Sources"

# SwiftUI APIs whose first argument (or named label: / title: / prompt: /
# promptText: argument) is a LocalizedStringKey.
FIRST_ARG_LITERALS = [
    "Text", "Label", "Button", "ToggleButton", "Toggle", "Picker",
    "TextField", "SecureField", "LabeledContent", "Stepper", "GroupBox",
    "Menu", "ShareLink", "ControlGroup", "Section", "Gauge", "ContentUnavailableView",
]
MODIFIER_LITERALS = [
    "navigationTitle", "navigationSubtitle", "help", "accessibilityLabel",
    "alert", "confirmationDialog", "badge", "accessibilityHint", "accessibilityValue",
]
NAMED_ARGS = ["label", "title", "prompt", "promptText", "name"]

CALL = re.compile(r"\b(" + "|".join(FIRST_ARG_LITERALS + MODIFIER_LITERALS) + r")\s*\(")
NAMED = re.compile(r"\b(?:label|title|prompt|promptText|name)\s*:\s*")

STRING = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
INTERP = re.compile(r"\\\(([^)]*)\)")
EMPTY_CALL = re.compile(r"\b(\w+)\s*\(\s*\)")  # to skip Text() / empty parens


JUNK = re.compile(
    r"^[()\[\]{}<>.,;:!?\-–—_*/+=|&^%$#@~`'\"\\ ]+$"      # punctuation only
    r"|^[a-z0-9]+(_[a-z0-9]+)+$"                            # snake_case identifiers
    r"|^(?:[A-Fa-f0-9]{8,}|[A-Z]{2,}[-_][A-Za-z0-9._-]+)$"  # hex ids / SCREAMING ids
)


def unescape(s: str) -> str:
    return json.loads(f'"{s}"')


def escape(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)[1:-1]


def spec_for(expr: str) -> str:
    """Guess a printf specifier for an interpolation expression."""
    e = expr.strip()
    if re.fullmatch(r"\d+|Int\w*|UInt\w*|\w*[Cc]ount\b|\w*[Ii]ndex\b|\w*[Nn]umber\b|\w*\.count\b|\w*\.percent\b", e):
        return "%lld"
    if e.startswith("$") or re.search(r"\bname\b|\btitle\b|\bid\b|\bhost\b|\bversion\b", e, re.I):
        return "%@"
    return "%@"


def extract_strings(text: str):
    """Yield (start, raw_literal) for interesting string literals."""
    for match in CALL.finditer(text):
        api = match.group(1)
        depth = 1
        i = match.end()
        start = i
        while i < len(text) and depth:
            c = text[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            elif c == '"':
                j = i + 1
                while j < len(text):
                    if text[j] == "\\":
                        j += 2
                        continue
                    if text[j] == '"' or text[j] == "\n":
                        break
                    j += 1
                if j < len(text) and text[j] == '"' and depth == 1:
                    yield start, api, text[i + 1:j], "first"
                i = j + 1
                continue
            i += 1
    # named arguments (label:, prompt:, ...) inside any call
    for match in NAMED.finditer(text):
        i = match.end()
        if i < len(text) and text[i] == '"':
            j = i + 1
            while j < len(text):
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"' or text[j] == "\n":
                    break
                j += 1
            if text[j:j + 1] == '"':
                yield i, "named", text[i + 1:j], "named"


def main():
    keys = defaultdict(set)          # key -> set of "file:line"
    interpolated = defaultdict(set)  # key -> set of refs
    for path in sorted(SRC.rglob("*.swift")):
        text = path.read_text()
        rel = path.relative_to(ROOT)
        for start, api, raw, kind in extract_strings(text):
            if not raw or not raw.strip():
                continue
            line = text.count("\n", 0, start) + 1
            ref = f"{rel}:{line} ({api})"
            if INTERP.search(raw):
                parts, pos = [], 0
                for m in INTERP.finditer(raw):
                    parts.append(raw[pos:m.start()])
                    parts.append(spec_for(m.group(1)))
                    pos = m.end()
                parts.append(raw[pos:])
                key = "".join(parts)
                interpolated[key].add(ref)
            else:
                try:
                    plain = unescape(raw)
                except Exception:
                    continue
                if not JUNK.fullmatch(plain) and len(plain.strip()) > 1:
                    keys[plain].add(ref)
    out = ROOT / ".build" / "localization"
    out.mkdir(parents=True, exist_ok=True)
    with (out / "keys.txt").open("w") as f:
        for key in sorted(keys):
            f.write(escape(key) + "\n")
    with (out / "interpolated.tsv").open("w") as f:
        for key in sorted(interpolated):
            refs = "; ".join(sorted(interpolated[key])[:3])
            f.write(f"{escape(key)}\t{refs}\n")
    print(f"plain keys: {len(keys)}")
    print(f"interpolated keys: {len(interpolated)}")
    print("wrote .build/localization/keys.txt and interpolated.tsv")


if __name__ == "__main__":
    main()
