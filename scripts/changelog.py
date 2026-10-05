#!/usr/bin/env python3
"""docs/Changelog.md 的讀寫工具（Keep a Changelog 格式）。內容由 git-cliff 產生，見 cliff.toml。

  changelog.py has-unreleased            有手寫的 `## [Unreleased]` 區塊就結束碼 0，否則 1
  changelog.py promote X.Y.Z             把 `## [Unreleased]` 改名為 `## [X.Y.Z] - 今天`
  changelog.py insert                    從 stdin 讀一個版本區塊，插到最新版本之前
  changelog.py show X.Y.Z [--format md|json]
                                         印出該版本的內容（不含標題行）。
                                         md：GitHub Release 與 Sparkle 的更新說明；
                                         json：App 的「新功能」視窗（App/Resources/WhatsNew.json）

  --file PATH   指定 Changelog（預設 docs/Changelog.md）
"""
import argparse
import datetime
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_FILE = ROOT / "docs" / "Changelog.md"
HEADING = re.compile(r"^## \[(?P<name>[^\]]+)\](?: - (?P<date>.+))?$")


def sections(text):
    """[(名稱, 日期, 內容行)]，依檔案順序。名稱是 `Unreleased` 或版本號。"""
    out = []
    for line in text.split("\n"):
        m = HEADING.match(line)
        if m:
            out.append((m["name"], m["date"], []))
        elif out:
            out[-1][2].append(line)
    return out


def find(text, name):
    for section_name, date, lines in sections(text):
        if section_name == name:
            return date, "\n".join(lines).strip("\n")
    return None


def has_unreleased(text):
    found = find(text, "Unreleased")
    return found is not None and any(line.startswith("- ") for line in found[1].split("\n"))


def promote(text, version, today):
    if find(text, "Unreleased") is None:
        raise SystemExit("Changelog 沒有 `## [Unreleased]` 區塊")
    return text.replace("## [Unreleased]", f"## [{version}] - {today}", 1)


def insert(text, block):
    """把產生的版本區塊放到第一個 `## [` 之前（前面是標題與說明）。"""
    block = block.strip("\n") + "\n\n"
    m = re.search(r"^## \[", text, re.M)
    if not m:
        return text.rstrip("\n") + "\n\n" + block.rstrip("\n") + "\n"
    return text[:m.start()] + block + text[m.start():]


def parse_body(body):
    """內容轉成 [{name, items}]；一個項目可以接續到縮排的下一行。"""
    result = []
    for line in body.split("\n"):
        if line.startswith("### "):
            result.append({"name": line[4:].strip(), "items": []})
        elif line.startswith("- ") and result:
            result[-1]["items"].append(line[2:].strip())
        elif line.startswith("  ") and line.strip() and result and result[-1]["items"]:
            result[-1]["items"][-1] += " " + line.strip()
    return [s for s in result if s["items"]]


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["has-unreleased", "promote", "insert", "show"])
    parser.add_argument("version", nargs="?")
    parser.add_argument("--file", type=pathlib.Path, default=DEFAULT_FILE)
    parser.add_argument("--format", choices=["md", "json"], default="md")
    args = parser.parse_args(argv)

    text = args.file.read_text(encoding="utf-8")

    if args.command == "has-unreleased":
        return 0 if has_unreleased(text) else 1

    if args.command == "promote":
        if not args.version:
            parser.error("promote 需要版本號")
        today = datetime.date.today().isoformat()
        args.file.write_text(promote(text, args.version, today), encoding="utf-8")
        return 0

    if args.command == "insert":
        args.file.write_text(insert(text, sys.stdin.read()), encoding="utf-8")
        return 0

    if not args.version:
        parser.error("show 需要版本號")
    found = find(text, args.version)
    if found is None:
        print(f"Changelog 沒有 {args.version} 這個版本", file=sys.stderr)
        return 1
    date, body = found
    if args.format == "md":
        print(body)
    else:
        print(json.dumps({"version": args.version, "date": date, "sections": parse_body(body)},
                         ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
