#!/usr/bin/env python3
"""Makes vs-jetpack's MVTools wrapper work with mvutensils 10 (docs 42, 08).

mvutensils 10 removed the fields and tff arguments from Analyse, AnalyseMany, Recalculate, Compensate and Flow
(upstream 5e95fa1); vs-jetpack (vsdenoise/mvtools/mvtools.py, main as of 2026-10-08) still passes them to core.mvu,
so QTempGaussMC and everything else on vsdenoise.MVTools fails with "Function does not take argument(s) named fields, tff".
Each 'fields=self.fields, tff=self.tff,' pair becomes a version check: the arguments are only passed while the loaded
mvutensils still takes them. Remove this script once vs-jetpack handles mvutensils 10 itself.

Usage: patch-vsjetpack-mvutensils.py <site-packages>
"""
import os
import re
import sys

PAIR = re.compile(r"^(?P<indent>[ \t]+)fields=self\.fields,\n(?P=indent)tff=self\.tff,\n", re.M)
REPLACEMENT = (r'\g<indent>**({"fields": self.fields, "tff": self.tff} if "fields:" in core.mvu.Analyse.signature else {}),'
               "\n")
EXPECTED = 4


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = os.path.join(sys.argv[1], "vsdenoise", "mvtools", "mvtools.py")
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    if '"fields:" in core.mvu.Analyse.signature' in source:
        print("  vs-jetpack mvtools.py is already patched")
        return
    if "fields=self.fields" not in source:
        print("  vs-jetpack passes no fields/tff to mvutensils any more, nothing to patch - remove patch-vsjetpack-mvutensils.py")
        return
    patched, count = PAIR.subn(REPLACEMENT, source)
    if count != EXPECTED or "fields=self.fields" in patched:
        sys.exit("  vs-jetpack mvtools.py changed: patched %d of %d fields/tff pairs, check the script" % (count, EXPECTED))
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(patched)
    print("  patched %d fields/tff pairs in %s" % (count, path))


if __name__ == "__main__":
    main()
