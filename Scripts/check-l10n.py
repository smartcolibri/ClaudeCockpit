#!/usr/bin/env python3
"""Checks the String Catalogs against the strings the compiler extracted.

Run after a Debug build (`xcodebuild ... build`), which writes one `.stringsdata` file per
Swift file into DerivedData. For the app catalog and each CockpitCore module catalog:

- every key used in code is in the catalog (otherwise it shows in English everywhere);
- every catalog key is used in code (no stale entry);
- every key has a non-empty, translated French value;
- plural variations carry `one` and `other` in English and French;
- each translation uses the same format specifiers as its key.

Usage: Scripts/check-l10n.py [DerivedData/<project>/Build/Intermediates.noindex]
Exit status 0 when clean, 1 otherwise.
"""
import glob
import json
import os
import re
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPECIFIER = re.compile(r"%(?:\d+\$)?(lld|ld|d|lf|f|@)")


def intermediates():
    if len(sys.argv) > 1:
        return sys.argv[1]
    found = sorted(
        glob.glob(os.path.expanduser(
            "~/Library/Developer/Xcode/DerivedData/ClaudeCockpit-*/Build/Intermediates.noindex")),
        key=os.path.getmtime)
    if not found:
        sys.exit("No DerivedData for ClaudeCockpit: build first, or pass the Intermediates.noindex path.")
    return found[-1]


def code_keys(directory):
    keys = set()
    for path in glob.glob(os.path.join(directory, "**", "*.stringsdata"), recursive=True):
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        for entry in data.get("tables", {}).get("Localizable", []):
            # `Picker("")` and friends: an empty title is never looked up.
            if entry["key"]:
                keys.add(entry["key"])
    return keys


def units(localization):
    """(variant, value, state) for a plain unit or each plural variant."""
    if "stringUnit" in localization:
        unit = localization["stringUnit"]
        return [("", unit.get("value", ""), unit.get("state"))]
    plural = localization.get("variations", {}).get("plural", {})
    return [(name, v["stringUnit"].get("value", ""), v["stringUnit"].get("state"))
            for name, v in plural.items()]


def check(name, catalog_path, extracted):
    with open(catalog_path, encoding="utf-8") as handle:
        catalog = json.load(handle)["strings"]
    problems = []
    for key in sorted(extracted - set(catalog)):
        problems.append(f"missing from catalog: {key!r}")
    for key in sorted(set(catalog) - extracted):
        problems.append(f"stale (not in code): {key!r}")
    translated = 0
    for key, entry in catalog.items():
        locs = entry.get("localizations", {})
        expected = Counter(SPECIFIER.findall(key))
        fr = locs.get("fr")
        if fr is None:
            problems.append(f"no French: {key!r}")
            continue
        ok = True
        for lang in ("en", "fr"):
            if lang not in locs:
                continue
            variants = units(locs[lang])
            names = {variant for variant, _, _ in variants}
            if "variations" in locs[lang] and not {"one", "other"} <= names:
                problems.append(f"{lang} plural lacks one/other: {key!r}")
                ok = False
            for variant, value, state in variants:
                if lang == "fr" and (state != "translated" or not value.strip()):
                    problems.append(f"fr not translated ({variant or 'value'}): {key!r}")
                    ok = False
                if Counter(SPECIFIER.findall(value)) != expected:
                    problems.append(f"{lang} specifiers differ ({variant or 'value'}): {key!r} -> {value!r}")
                    ok = False
        translated += ok
    print(f"{name}: {len(catalog)} keys, {len(extracted)} in code, {translated} fully translated in French, "
          f"{len(problems)} problem(s)")
    for problem in problems:
        print(f"  - {problem}")
    return not problems


def main():
    base = intermediates()
    targets = [("ClaudeCockpit (app)", os.path.join(ROOT, "ClaudeCockpit/Resources/Localizable.xcstrings"),
                os.path.join(base, "ClaudeCockpit.build"))]
    for catalog in sorted(glob.glob(os.path.join(ROOT, "CockpitCore/Sources/*/Localizable.xcstrings"))):
        module = os.path.basename(os.path.dirname(catalog))
        built = glob.glob(os.path.join(base, "CockpitCore.build", "*", f"{module}-t.build"))
        if not built:
            print(f"{module}: no build products under {base}")
            return 1
        targets.append((module, catalog, built[0]))
    results = [check(name, catalog, code_keys(directory)) for name, catalog, directory in targets]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
