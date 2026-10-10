#!/usr/bin/env python3
"""Checks the String Catalogs against the strings the compiler extracted.

Run after a Debug build (`xcodebuild ... build`), which writes one `.stringsdata` file per
Swift file into DerivedData. For the app catalog and each CockpitCore module catalog:

- every key used in code is in the catalog (otherwise it shows in English everywhere);
- every catalog key is used in code (no stale entry);
- every key has a non-empty, translated French value;
- plural variations carry `one` and `other` in English and French;
- each translation uses the same format specifiers as its key.

The DerivedData used is the one whose `info.plist` names this checkout's
`ClaudeCockpit.xcodeproj` (several checkouts or worktrees each have their own), or the
DerivedData folder passed as argument. Only the Debug intermediates are read, a
`.stringsdata` whose Swift file no longer exists is ignored, and the check fails when the
build is older than a Swift file or a catalog: a stale build would hide missing keys.

Usage: Scripts/check-l10n.py [~/Library/Developer/Xcode/DerivedData/ClaudeCockpit-<hash>]
Exit status 0 when clean, 1 otherwise.
"""
import glob
import json
import os
import plistlib
import re
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPECIFIER = re.compile(r"%(?:\d+\$)?(lld|ld|d|lf|f|@)")


def derived_data():
    """The DerivedData folder of this checkout's project."""
    if len(sys.argv) > 1:
        return sys.argv[1]
    project = os.path.join(ROOT, "ClaudeCockpit.xcodeproj")
    for candidate in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/ClaudeCockpit-*")):
        try:
            with open(os.path.join(candidate, "info.plist"), "rb") as handle:
                workspace = plistlib.load(handle).get("WorkspacePath")
        except (OSError, plistlib.InvalidFileException):
            continue
        if workspace and os.path.realpath(workspace) == os.path.realpath(project):
            return candidate
    sys.exit(f"No DerivedData for {project}: build it first, or pass its DerivedData folder.")


def stringsdata(directory):
    """(path, source) of each `.stringsdata` under `directory` whose Swift file still exists."""
    found = []
    for path in glob.glob(os.path.join(directory, "**", "*.stringsdata"), recursive=True):
        with open(path, encoding="utf-8") as handle:
            source = json.load(handle).get("source", "")
        if os.path.exists(source):
            found.append((path, source))
    return found


def code_keys(files):
    keys = set()
    for path, _ in files:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        for entry in data.get("tables", {}).get("Localizable", []):
            # `Picker("")` and friends: an empty title is never looked up.
            if entry["key"]:
                keys.add(entry["key"])
    return keys


def staleness(name, sources_dir, files, catalog_path, compiled):
    """Problems when the build predates a Swift file or the catalog it is checked against."""
    problems = []
    # The compiler rewrites a `.stringsdata` only when its strings change, so the time a file
    # was last compiled is its object file's, next to it.
    def compiled_at(path):
        objects = os.path.splitext(path)[0] + ".o"
        return max(os.path.getmtime(path), os.path.getmtime(objects) if os.path.exists(objects) else 0)
    built = {os.path.realpath(source): compiled_at(path) for path, source in files}
    for swift in glob.glob(os.path.join(sources_dir, "**", "*.swift"), recursive=True):
        extracted = built.get(os.path.realpath(swift))
        if extracted is None:
            problems.append(f"not built: {os.path.relpath(swift, ROOT)}")
        elif extracted < os.path.getmtime(swift):
            problems.append(f"changed since the build: {os.path.relpath(swift, ROOT)}")
    if not os.path.exists(compiled) or os.path.getmtime(compiled) < os.path.getmtime(catalog_path):
        problems.append(f"catalog changed since the build: {os.path.relpath(catalog_path, ROOT)}")
    for problem in problems:
        print(f"{name}: stale build, {problem}")
    return problems


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
    derived = derived_data()
    base = os.path.join(derived, "Build", "Intermediates.noindex")
    products = os.path.join(derived, "Build", "Products", "Debug")
    compiled = os.path.join("Contents", "Resources", "fr.lproj", "Localizable.strings")
    targets = [("ClaudeCockpit (app)", os.path.join(ROOT, "ClaudeCockpit/Resources/Localizable.xcstrings"),
                os.path.join(base, "ClaudeCockpit.build", "Debug"), os.path.join(ROOT, "ClaudeCockpit"),
                os.path.join(products, "Cockpit for Claude.app", compiled))]
    for catalog in sorted(glob.glob(os.path.join(ROOT, "CockpitCore/Sources/*/Localizable.xcstrings"))):
        module = os.path.basename(os.path.dirname(catalog))
        targets.append((module, catalog, os.path.join(base, "CockpitCore.build", "Debug", f"{module}-t.build"),
                        os.path.dirname(catalog),
                        os.path.join(products, f"CockpitCore_{module}.bundle", compiled)))
    stale, results = False, []
    for name, catalog, directory, sources, compiled_catalog in targets:
        files = stringsdata(directory)
        if not files:
            print(f"{name}: no Debug build products under {directory}")
            return 1
        stale |= bool(staleness(name, sources, files, catalog, compiled_catalog))
        results.append(check(name, catalog, code_keys(files)))
    if stale:
        print("Rebuild (Debug) before trusting this check.")
    return 0 if all(results) and not stale else 1


if __name__ == "__main__":
    sys.exit(main())
