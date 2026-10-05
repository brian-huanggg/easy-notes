#!/usr/bin/env python3
"""找出沒有經過 L("…") / t("…") 的中文字面值（規則見 docs/architecture/translation.md）。

  ./scripts/check-l10n.py            列出違規，有違規時結束碼為 1
  ./scripts/check-l10n.py --summary  依檔案與外層呼叫統計（遷移時用）
  ./scripts/check-l10n.py --stale    另外列出 catalog / 字典裡程式已經沒用到的 key（不影響結束碼）

另外比對翻譯是否齊全：每個 `L("…")` 的 key 要在該模組的 `Localizable.xcstrings` 有英文（state 為 translated），
web 的 `t("…")` 要在 `web/src/shared/i18n.ts` 的 `en` 字典有對應。

刻意不翻譯的字串（路徑、同步協定、檔案內容）在該行行尾或上一行加 `// l10n:fixed`；
整個檔案都是這類資料時，在檔案前 5 行加 `// l10n:fixed-file`。
日誌與 `precondition` / `fatalError` 的訊息是給開發者看的，不檢查。
"""
import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CJK = re.compile(r"[㐀-䶿一-鿿　-〿＀-￯]")
FIXED = "l10n:fixed"
# 開發者看的訊息，不翻
DEV_CALLS = {"print", "debugPrint", "fatalError", "precondition", "preconditionFailure", "assert", "assertionFailure", "NSLog"}
# Spike 是驗證用的暫時程式（只在 DEBUG 或啟動參數出現），使用者看不到，不翻
DEV_LINE = re.compile(r"\b(" + "|".join(sorted(DEV_CALLS)) + r")\(")
SKIP_DIRS = {".build", "build", "node_modules", "Tests", "Fixtures", "DerivedData", "dist", "Spike"}


class Literal:
    __slots__ = ("start", "end", "line", "text", "has_cjk", "caller", "context")

    def __init__(self, start, end, line, text, has_cjk, caller, context):
        self.start, self.end, self.line, self.text = start, end, line, text
        self.has_cjk, self.caller, self.context = has_cjk, caller, context


def swift_literals(src):
    """掃出所有字串字面值（含插值裡面巢狀的），略過註解。回傳 (Literal 清單, 行首位移表)。"""
    out = []
    n = len(src)
    line_starts = [0] + [m.end() for m in re.finditer(r"\n", src)]

    def line_of(pos):
        lo, hi = 0, len(line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if line_starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def caller_before(pos):
        """字面值之前最近的 `name(`（含 `label:`）：回傳 (呼叫名, 前面的文字)"""
        head = src[max(0, pos - 80):pos]
        m = re.search(r"([A-Za-z_][A-Za-z0-9_.]*)\s*\(\s*(?:[A-Za-z_]+:\s*)?$", head)
        return (m.group(1) if m else ""), head

    def scan_string(i, depth_guard=0):
        """i 指向開頭的 `"`；回傳結束位置（結尾 `"` 之後），並登記字面值"""
        multiline = src.startswith('"""', i)
        hashes = 0
        j = i
        while j > 0 and src[j - 1] == "#":  # raw string 前綴
            hashes += 1
            j -= 1
        quote = '"""' if multiline else '"'
        k = i + len(quote)
        has_cjk = False
        text_parts = []
        while k < n:
            if src.startswith(quote + "#" * hashes, k) and (multiline or src[k] == '"'):
                k += len(quote) + hashes
                break
            c = src[k]
            if c == "\\" and src.startswith("\\" + "#" * hashes + "(", k):
                depth = 1
                k += 2 + hashes
                inner_start = k
                while k < n and depth:
                    ch = src[k]
                    if ch == '"':
                        k = scan_string(k, depth_guard + 1)
                        continue
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                    k += 1
                text_parts.append("\\(…)")
                continue
            if c == "\\":
                text_parts.append(src[k:k + 2])
                k += 2
                continue
            if CJK.search(c):
                has_cjk = True
            text_parts.append(c)
            k += 1
        caller, head = caller_before(j)
        out.append(Literal(j, k, line_of(j), "".join(text_parts), has_cjk, caller, head))
        return k

    i = 0
    while i < n:
        c = src[i]
        if c == "/" and src.startswith("//", i):
            nl = src.find("\n", i)
            i = n if nl < 0 else nl
        elif c == "/" and src.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif src.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
        elif c == '"':
            i = scan_string(i)
        else:
            i += 1
    return out, line_starts


def swift_files():
    for base in ("App", "Packages"):
        for p in sorted((ROOT / base).rglob("*.swift")):
            if SKIP_DIRS & set(p.relative_to(ROOT).parts):
                continue
            yield p


def is_fixed(lines, lineno):
    if any(line.lstrip().startswith("// " + FIXED + "-file") for line in lines[:5]):
        return True
    here = lines[lineno - 1]
    if FIXED in here:
        return True
    k = lineno - 2
    while k >= 0 and not lines[k].strip():
        k -= 1
    return k >= 0 and lines[k].strip().startswith("//") and FIXED in lines[k]


def check_swift():
    bad = []
    for p in swift_files():
        src = p.read_text(encoding="utf-8")
        lits, _ = swift_literals(src)
        lines = src.split("\n")
        for lit in lits:
            if not lit.has_cjk:
                continue
            if lit.caller == "L" or lit.caller.endswith(".L"):
                continue
            if lit.caller in DEV_CALLS or DEV_LINE.search(lines[lit.line - 1]):
                continue
            if is_fixed(lines, lit.line):
                continue
            bad.append((p.relative_to(ROOT), lit.line, lit.caller or "(無)", lit.text))
    return bad


def strip_ts_comment(line):
    """去掉行尾的 `//` 註解（字串裡的 `//` 不算）；整行是區塊註解的內容時回傳空字串"""
    if line.lstrip().startswith(("*", "/*")):
        return ""
    quote = None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\":
                i += 1
            elif ch == quote:
                quote = None
        elif ch in "\"'`":
            quote = ch
        elif line.startswith("//", i):
            return line[:i]
        i += 1
    return line


WEB_LITERAL = re.compile(r"""(["'`])((?:\\.|(?!\1).)*[㐀-鿿＀-￯](?:\\.|(?!\1).)*)\1""")


def check_web():
    bad = []
    base = ROOT / "web" / "src"
    if not base.exists():
        return bad
    for p in sorted(base.rglob("*.ts")):
        if p.name == "i18n.ts" or SKIP_DIRS & set(p.relative_to(ROOT).parts):
            continue
        lines = p.read_text(encoding="utf-8").split("\n")
        for no, line in enumerate(lines, 1):
            code = strip_ts_comment(line)
            for m in WEB_LITERAL.finditer(code):
                head = code[:m.start()]
                if re.search(r"\b(t|tr)\(\s*$", head):
                    continue
                if FIXED in line or (no > 1 and FIXED in lines[no - 2]):
                    continue
                bad.append((p.relative_to(ROOT), no, "(無)", m.group(2)))
    return bad


PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:lld|ld|d|u|@|f|s)")
ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}


def swift_key(text):
    """程式裡的字面值 → catalog 的比對形式：插值與格式符號都換成 \0"""
    text = text.replace("\\(…)", "\0")
    return re.sub(r"\\(.)", lambda m: ESCAPES.get(m.group(1), m.group(0)), text)


def catalog_key(key):
    return PLACEHOLDER.sub("\0", key)


def english_of(entry):
    """catalog 條目的英文；有 variations（複數等）時只要每個變體都有值就算有"""
    en = entry.get("localizations", {}).get("en")
    if not en:
        return None
    unit = en.get("stringUnit")
    if unit:
        return unit.get("value") if unit.get("state") == "translated" and unit.get("value") else None

    def leaves(node):
        if "stringUnit" in node:
            yield node["stringUnit"]
        for group in node.get("variations", {}).values():
            for sub in group.values():
                yield from leaves(sub)
        for sub in node.get("substitutions", {}).values():
            yield from leaves(sub)

    units = list(leaves(en))
    ok = units and all(u.get("state") == "translated" and u.get("value") for u in units)
    return "(variations)" if ok else None


def catalog_root(path):
    """該 Swift 檔所屬 target 的根目錄（往上找到 Localization.swift 的資料夾）"""
    for parent in path.parents:
        if (parent / "Localization.swift").exists():
            return parent
        if parent == ROOT:
            break
    return None


def check_catalogs(stale):
    """回傳 (缺的清單, 沒用到的清單)"""
    import json

    catalogs = {}   # root -> {normalized key: (raw key, entry)}
    used = {}       # root -> set of normalized keys
    missing = []
    for p in swift_files():
        root = catalog_root(p)
        if root is None:
            continue
        if root not in catalogs:
            f = root / "Localizable.xcstrings"
            data = json.loads(f.read_text(encoding="utf-8"))["strings"] if f.exists() else {}
            catalogs[root] = {catalog_key(k): (k, v) for k, v in data.items() if k}
            used[root] = set()
        src = p.read_text(encoding="utf-8")
        lits, _ = swift_literals(src)
        lines = src.split("\n")
        for lit in lits:
            if not lit.has_cjk or not (lit.caller == "L" or lit.caller.endswith(".L")):
                continue
            if is_fixed(lines, lit.line):
                continue
            key = swift_key(lit.text)
            used[root].add(key)
            hit = catalogs[root].get(key)
            where = (p.relative_to(ROOT), lit.line)
            if hit is None:
                missing.append((*where, "catalog 沒有這個 key", lit.text))
            elif english_of(hit[1]) is None:
                missing.append((*where, "沒有英文翻譯（或 state 不是 translated）", lit.text))
    unused = []
    if stale:
        for root, entries in catalogs.items():
            for key, (raw, _) in entries.items():
                if key not in used[root] and CJK.search(key):
                    unused.append(((root / "Localizable.xcstrings").relative_to(ROOT), 0, "程式沒用到", raw))
    return missing, unused


def web_dictionary():
    """i18n.ts 的 en 字典：回傳 {key: 英文}"""
    f = ROOT / "web" / "src" / "shared" / "i18n.ts"
    if not f.exists():
        return {}
    body = f.read_text(encoding="utf-8")
    start = body.find("en: {")
    end = body.find("\n  },", start)
    entries = {}
    pair = re.compile(r"""^\s*(?:"((?:\\.|[^"\\])*)"|([^\s"':/][^:"']*?))\s*:\s*"((?:\\.|[^"\\])*)",?\s*$""")
    for line in body[start:end].split("\n")[1:]:
        m = pair.match(strip_ts_comment(line))
        if m:
            entries[m.group(1) or m.group(2)] = m.group(3)
    return entries


def check_web_dictionary(stale):
    dictionary = web_dictionary()
    base = ROOT / "web" / "src"
    if not dictionary:
        return [], []
    call = re.compile(r"""\bt\(\s*(["'`])((?:\\.|(?!\1).)*[㐀-鿿＀-￯](?:\\.|(?!\1).)*)\1""")
    used, missing = set(), []
    for p in sorted(base.rglob("*.ts")):
        if p.name == "i18n.ts" or SKIP_DIRS & set(p.relative_to(ROOT).parts):
            continue
        for no, line in enumerate(p.read_text(encoding="utf-8").split("\n"), 1):
            for m in call.finditer(strip_ts_comment(line)):
                used.add(m.group(2))
                if not dictionary.get(m.group(2)):
                    missing.append((p.relative_to(ROOT), no, "en 字典沒有這個 key", m.group(2)))
    unused = []
    if stale:
        unused = [(pathlib.Path("web/src/shared/i18n.ts"), 0, "程式沒用到", k) for k in dictionary if k not in used]
    return missing, unused


def main():
    summary = "--summary" in sys.argv
    stale = "--stale" in sys.argv
    bad = check_swift() + check_web()
    missing_cat, unused_cat = check_catalogs(stale)
    missing_web, unused_web = check_web_dictionary(stale)
    bad_translation = missing_cat + missing_web
    if summary:
        per_file = collections.Counter(str(b[0]) for b in bad)
        per_caller = collections.Counter(b[2] for b in bad)
        print("== 依檔案 ==")
        for k, v in per_file.most_common():
            print(f"{v:4d}  {k}")
        print("\n== 依外層呼叫 ==")
        for k, v in per_caller.most_common():
            print(f"{v:4d}  {k}")
        print(f"\n合計 {len(bad)}")
        return 0
    for path, line, caller, text in bad:
        print(f"{path}:{line}: [{caller}] {text[:70]}")
    for path, line, why, text in bad_translation:
        print(f"{path}:{line}: [{why}] {text[:70]}")
    for path, _, why, text in unused_cat + unused_web:
        print(f"{path}: [{why}] {text[:70]}")
    if bad:
        print(f"\n{len(bad)} 個中文字面值沒有經過 L(…) / t(…)；刻意不翻譯的加 `// {FIXED}`。", file=sys.stderr)
    if bad_translation:
        print(f"\n{len(bad_translation)} 個字串缺英文翻譯；補進對應的 Localizable.xcstrings / i18n.ts。", file=sys.stderr)
    return 1 if bad or bad_translation else 0


if __name__ == "__main__":
    sys.exit(main())
