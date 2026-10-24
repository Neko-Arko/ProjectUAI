#!/usr/bin/env python3
"""Lua-aware string literal audit for the interface.

Answers one question per literal: is this something a user reads, and does the
dictionary already cover it? Literals are located by a small scanner rather than
a regex so that comments, long strings and escaped quotes do not corrupt the
result -- a false positive here means a mangled label, and a false negative means
a leftover English sentence.

    python tools/zh_audit.py              # summary + l10n/report.txt
    python tools/zh_audit.py --file X     # one file, with context
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI_DIRS = ["src/ui", "src/runtime", "src/tools", "src/agent"]

# Props that carry copy rather than data. `name` is deliberately absent: it names an
# Instance and is used by tests and layout code, so it must never be translated.
COPY_KEYS = {
    "text", "label", "title", "subtitle", "description", "desc", "hint", "placeholder",
    "caption", "body", "message", "empty", "help", "badge", "tooltip", "detail",
    "summary", "note", "prompt", "intro", "footer", "header", "unit", "suffix", "prefix",
}

LONG = re.compile(r"\[(=*)\[")
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_./:-]*$")
BASE64 = re.compile(r"^[A-Za-z0-9+/=]{80,}$")
FORMAT_ONLY = re.compile(r"^[%sdfxX0-9.+\- ]*$")


def scan(path: Path):
    """Yield (line, key_hint, text) for every string literal in the file."""
    src = path.read_text(encoding="utf-8")
    i, n, line = 0, len(src), 1
    while i < n:
        ch = src[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if src.startswith("--", i):
            m = LONG.match(src, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                end = src.find(close, m.end())
                end = n if end < 0 else end + len(close)
                line += src.count("\n", i, end)
                i = end
                continue
            end = src.find("\n", i)
            i = n if end < 0 else end
            continue
        if src.startswith("[[", i) or (ch == "[" and LONG.match(src, i)):
            m = LONG.match(src, i)
            close = "]" + m.group(1) + "]"
            end = src.find(close, m.end())
            end = n if end < 0 else end + len(close)
            yield line, "long", src[m.end():end]
            line += src.count("\n", i, end)
            i = end
            continue
        if ch in "\"'`":
            quote, j, buf = ch, i + 1, []
            while j < n:
                c = src[j]
                if c == "\\":
                    nxt = src[j + 1:j + 2]
                    buf.append({"n": "\n", "t": "\t", "r": "\r"}.get(nxt, nxt))
                    j += 2
                    continue
                if c == quote:
                    break
                if c == "\n":
                    break
                buf.append(c)
                j += 1
            text = "".join(buf)
            back = src[max(0, i - 40):i]
            key = ""
            match = re.search(r"([A-Za-z_]+)\s*=\s*$", back)
            if match:
                key = match.group(1)
            elif re.search(r"\(\s*$", back):
                key = "call"
            yield line, key, text
            i = j + 1
            continue
        i += 1


def looks_like_copy(text: str) -> bool:
    if len(text) < 2 or not re.search(r"[A-Za-z]", text):
        return False
    if BASE64.match(text) or IDENT.match(text) or FORMAT_ONLY.match(text):
        return False
    if text.startswith(("http://", "https://", "rbxasset", "data:")):
        return False
    if re.match(r"^[\w./-]+$", text):
        return False
    return bool(re.search(r"\s", text)) or (text[:1].isupper() and len(text) >= 4)


def load_dict():
    base = json.loads((ROOT / "l10n" / "zh.json").read_text(encoding="utf-8"))
    entries = dict(base.get("entries", base))
    for part in sorted((ROOT / "l10n" / "parts").glob("*.json")):
        data = json.loads(part.read_text(encoding="utf-8"))
        entries.update(data.get("entries", data))
    return entries


def collect():
    rows = []
    for folder in UI_DIRS:
        for path in sorted((ROOT / folder).rglob("*.lua")):
            for line, key, text in scan(path):
                if not looks_like_copy(text):
                    continue
                is_copy = key in COPY_KEYS
                rows.append({
                    "file": path.relative_to(ROOT).as_posix(),
                    "line": line,
                    "key": key,
                    "text": text,
                    "copy": is_copy,
                })
    return rows


def main():
    only = None
    if "--file" in sys.argv:
        only = sys.argv[sys.argv.index("--file") + 1]
    entries = load_dict()
    rows = collect()
    if only:
        rows = [row for row in rows if only in row["file"]]

    copy_rows = [row for row in rows if row["copy"]]
    other_rows = [row for row in rows if not row["copy"]]
    missing_copy = [row for row in copy_rows if row["text"] not in entries]
    missing_other = [row for row in other_rows if row["text"] not in entries]

    if only:
        current = None
        for row in rows:
            if row["file"] != current:
                current = row["file"]
                print("\n== %s" % current)
            mark = "OK  " if row["text"] in entries else ("COPY" if row["copy"] else "  . ")
            print("%s L%-5d %s" % (mark, row["line"], row["text"]))
        return 0

    print("字面量候选 %d 条（唯一 %d）" % (len(rows), len({row["text"] for row in rows})))
    print("  显式文案位（text/label/title/...）: %d 条，未覆盖 %d"
          % (len(copy_rows), len(missing_copy)))
    print("  其他位置（拼接/表格/动态）:      %d 条，未覆盖 %d"
          % (len(other_rows), len(missing_other)))
    print("词典条目: %d" % len(entries))

    per_file = {}
    for row in missing_copy:
        per_file[row["file"]] = per_file.get(row["file"], 0) + 1
    print("\n未覆盖文案最多的文件：")
    for name, count in sorted(per_file.items(), key=lambda kv: -kv[1])[:20]:
        print("  %5d  %s" % (count, name))

    lines = ["# 未翻译清单（显式文案位）", ""]
    current = None
    for row in sorted(missing_copy, key=lambda r: (r["file"], r["line"])):
        if row["file"] != current:
            current = row["file"]
            lines.append("\n## %s" % current)
        lines.append("- L%-5d %s" % (row["line"], row["text"].replace("\n", "\\n")))
    report = ROOT / "l10n" / "report.txt"
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n明细写入 %s" % report.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
