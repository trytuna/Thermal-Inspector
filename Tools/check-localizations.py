#!/usr/bin/env python3
"""Lists texts that are used in the code but missing (or untranslated) in the String Catalog.

The Swift compiler writes every localizable text it finds into *.stringsdata files
during a build (SWIFT_EMIT_LOC_STRINGS). This script compares them with
ThermalInspector/Resources/Localizable.xcstrings.

Usage (after a build into ./build):
    python3 Tools/check-localizations.py           # report missing translations
    python3 Tools/check-localizations.py --prune   # also remove texts no longer used

Exit code 1 if something is missing, so it can be used in CI.
"""
import glob
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "ThermalInspector/Resources/Localizable.xcstrings"
LANGUAGES = ["de"]


def keys_used_in_code() -> set[str]:
    pattern = str(ROOT / "build/**/ThermalInspector.build/**/*.stringsdata")
    keys = set()
    for path in glob.glob(pattern, recursive=True):
        for entries in json.load(open(path)).get("tables", {}).values():
            keys.update(entry["key"] for entry in entries)
    if not keys:
        sys.exit("No .stringsdata found – build the app first (./build.sh or xcodebuild … -derivedDataPath build).")
    return keys


def main() -> None:
    catalog = json.load(open(CATALOG))
    strings = catalog["strings"]
    used = keys_used_in_code()

    missing = sorted(key for key in used
                     if any(language not in strings.get(key, {}).get("localizations", {}) for language in LANGUAGES))
    unused = sorted(set(strings) - used)

    for key in missing:
        print(f"missing:  {key!r}")
    for key in unused:
        print(f"unused:   {key!r}")

    if "--prune" in sys.argv and unused:
        for key in unused:
            del strings[key]
        json.dump(catalog, open(CATALOG, "w"), ensure_ascii=False, indent=2, sort_keys=True)
        print(f"removed {len(unused)} unused entries")

    print(f"{len(used)} texts, {len(missing)} missing, {len(unused)} unused")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
