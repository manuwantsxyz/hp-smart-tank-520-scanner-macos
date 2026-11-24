#!/usr/bin/env python3
"""Checks the app's translations.

Collects every user-facing string in app/*.swift (L("…") calls and SwiftUI literals such as
Button("…")), then verifies that each translation file has every key with the same format
specifiers. It also flags Spanish-looking literals that aren't localized.

Usage: scripts/check-l10n.py [--keys]   (--keys prints the collected keys)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
SKIP = {"Demo.swift", "L10n.swift", "make_icon.swift"}
SWIFTUI = r"(?:Button|Toggle|Text|Label|Section|LabeledContent|TextField|Picker|CommandMenu|slider|\.help|Stepper)"
LIT = r'"((?:[^"\\]|\\.)*)"'
SPANISH = re.compile(r"[áéíóúñ¿¡]|\b(?:el|la|los|las|de|del|para|con|sin|una?|en|que|no|página|escane\w*|guardar)\b", re.I)
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:l|ll|h)?[@dDuUxXoOfeEgGcCsSpaA%]")


def keys_in(src: str):
    keys, unlocalized = {}, []
    for m in re.finditer(r"\bL\(\s*" + LIT, src):
        keys[m.group(1)] = True
    for m in re.finditer(SWIFTUI + r"\(\s*" + LIT, src):
        k = m.group(1)
        if "\\(" not in k:
            keys[k] = True
    for m in re.finditer(LIT, src):
        k = m.group(1)
        start = m.start()
        line = src[src.rfind("\n", 0, start) + 1: src.find("\n", start)]
        if line.strip().startswith("//") or k in keys or re.fullmatch(r"[a-z]{2}-[A-Z]{2}", k) or "\\(" in k and not SPANISH.search(re.sub(r"\\\(.*?\)", "", k)):
            continue
        if SPANISH.search(k) and not re.search(r"(?:\bL|" + SWIFTUI + r")\(\s*$", src[max(0, start - 40):start]):
            unlocalized.append((line.strip(), k))
    return keys, unlocalized


def parse_strings(path: Path):
    text = path.read_text(encoding="utf-8")
    return {m.group(1): m.group(2) for m in re.finditer(r'^\s*' + LIT + r'\s*=\s*' + LIT + r'\s*;', text, re.M)}


def main():
    keys, problems = {}, []
    for f in sorted(APP.glob("*.swift")):
        if f.name in SKIP:
            continue
        k, un = keys_in(f.read_text(encoding="utf-8"))
        keys.update(k)
        problems += [f"{f.name}: not localized: {k!r}   ← {line}" for line, k in un]
    if "--keys" in sys.argv:
        print("\n".join(sorted(keys)))
        return 0
    for strings in sorted((APP / "Resources").glob("*.lproj/Localizable.strings")):
        table = parse_strings(strings)
        lang = strings.parent.name
        for k in sorted(keys):
            if not re.search(r"[A-Za-zÁÉÍÓÚáéíóúñ]", k):
                continue
            if k not in table:
                problems.append(f"{lang}: missing {k!r}")
            elif sorted(SPEC.findall(k)) != sorted(SPEC.findall(table[k])):
                problems.append(f"{lang}: format specifiers differ for {k!r} → {table[k]!r}")
        for k in sorted(set(table) - set(keys)):
            problems.append(f"{lang}: unused key {k!r}")
    for p in problems:
        print("❌", p)
    print(f"{len(keys)} keys, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
