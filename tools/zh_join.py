#!/usr/bin/env python3
"""Join adjacent string literals that were split across lines for width.

    text = "One long sentence that was wrapped "
        .. "for the source file's line length."

A wrapped sentence is one key in the dictionary, so the fragment join has to
happen before translation -- otherwise Chinese arrives in pieces and the word
order is the source file's, not the sentence's. Only literal-adjacent-literal is
touched: any identifier, call or comment between them is left alone.

    python tools/zh_join.py            # report only
    python tools/zh_join.py --write    # apply
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATTERNS = [
    # "text " ..\n\t\t"more text"
    re.compile(r'"((?:[^"\\\n]|\\.)*)"[ \t]*\.\.[ \t]*\n[ \t]*"((?:[^"\\\n]|\\.)*)"'),
    # "text "\n\t\t.. "more text"
    re.compile(r'"((?:[^"\\\n]|\\.)*)"[ \t]*\n[ \t]*\.\.[ \t]*"((?:[^"\\\n]|\\.)*)"'),
]


def join_file(path: Path, write: bool):
    source = path.read_text(encoding="utf-8")
    total, current = 0, source
    while True:
        merged = False
        for pattern in PATTERNS:
            updated, count = pattern.subn(lambda m: '"%s%s"' % (m.group(1), m.group(2)), current)
            if count:
                current, total, merged = updated, total + count, True
        if not merged:
            break
    if total and write:
        path.write_text(current, encoding="utf-8")
    return total


def main():
    write = "--write" in sys.argv
    changed = []
    for path in sorted((ROOT / "src").rglob("*.lua")):
        count = join_file(path, write)
        if count:
            changed.append((path.relative_to(ROOT).as_posix(), count))
    for name, count in changed:
        print("%3d  %s" % (count, name))
    print("%s: %d joins in %d files"
          % ("written" if write else "would write", sum(c for _, c in changed), len(changed)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
