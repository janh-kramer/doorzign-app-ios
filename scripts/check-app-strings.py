#!/usr/bin/env python3
"""Prüft, ob alle deutschen UI-Texte der App eine englische Übersetzung haben.

Ohne Xcode gibt es keine automatische String-Extraktion. Das Skript sucht Stringliterale in
App/Sources (Heuristik: enthält Buchstaben, kein Bezeichner, keine SF-Symbol-Namen/URLs) und
vergleicht sie mit App/Resources/en.lproj/Localizable.strings. Interpolationen `\\(…)` werden
mit `%@`/`%lld` gleichgesetzt.

Aufruf: python3 scripts/check-app-strings.py   (Exit-Code 1 bei fehlenden Übersetzungen)
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "App", "Sources")
STRINGS = os.path.join(ROOT, "App", "Resources", "en.lproj", "Localizable.strings")

# Kontexte, in denen Literale keine UI-Texte sind.
SKIP_CONTEXT = re.compile(
    r"(systemImage|systemName|forInfoDictionaryKey|label|identifier|code|string|forKey): $|URL\(string: $|fields\[$|case $|"
    r"\.tag\($|== $|!= $|contains\($|accessibilityIdentifier\($"
)
# Literale ohne Übersetzungsbedarf (Produktnamen, Zahlenformate, Entwicklerwerte).
NO_TRANSLATION = re.compile(r"^[a-z0-9_.:/-]+$|^(https?://\S+$|line\.3|battery\.|de\.doorzign)|^\.zeitwart\.de$|^Europe/Berlin$")


def literals(src):
    """Liefert (Text mit %-Platzhaltern, Kontext) für jedes Literal, auch in Interpolationen."""
    i, n = 0, len(src)
    while i < n:
        if src.startswith("//", i):
            nl = src.find("\n", i)
            i = n if nl < 0 else nl
            continue
        if src[i] == '"' and not src.startswith('"""', i):
            j, out = i + 1, ""
            while src[j] != '"':
                if src[j] == "\\" and src[j + 1] == "(":
                    depth, k, in_string = 1, j + 2, False
                    while depth > 0:
                        if src[k] == '"':
                            in_string = not in_string
                        elif not in_string:
                            depth += {"(": 1, ")": -1}.get(src[k], 0)
                        k += 1
                    yield from literals(src[j + 2:k - 1])
                    out += "%"
                    j = k
                elif src[j] == "\\":
                    out += src[j + 1]
                    j += 2
                else:
                    out += src[j]
                    j += 1
            yield out, src[max(0, i - 40):i].split("\n")[-1]
            i = j + 1
            continue
        i += 1


def normalized(key):
    return key.replace("%lld", "%").replace("%@", "%")


def main():
    used = {}
    for root, _, files in os.walk(SOURCES):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(root, name)
            for text, context in literals(open(path, encoding="utf-8").read()):
                if not re.search(r"[A-Za-zÄÖÜäöüß]{2}", text) or SKIP_CONTEXT.search(context):
                    continue
                if NO_TRANSLATION.search(text) and text != "firma":
                    continue
                used.setdefault(text, os.path.relpath(path, ROOT))

    plist = subprocess.run(["plutil", "-convert", "json", "-o", "-", STRINGS], capture_output=True, text=True, check=True)
    import json
    english = json.loads(plist.stdout)
    available = {normalized(k) for k in english}

    missing = sorted((f, t) for t, f in used.items() if t not in available)
    unused = sorted(k for k in english if normalized(k) not in used)
    for f, t in missing:
        print(f"FEHLT  {f}: {t}")
    for k in unused:
        print(f"UNGENUTZT  {k}")
    print(f"{len(used)} Texte, {len(missing)} ohne Übersetzung, {len(unused)} ungenutzte Einträge.")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
