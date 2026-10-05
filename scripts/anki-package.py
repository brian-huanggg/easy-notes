#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["zstandard"]
# ///
"""產生 Anki 的 .apkg（從 Anki 匯入的測試用）。

  ./scripts/anki-package.py fixtures
      → Packages/Flashcards/Tests/FlashcardsTests/Fixtures/anki-modern.apkg（schema 18、zstd、protobuf 媒體清單）
      → Packages/Flashcards/Tests/FlashcardsTests/Fixtures/anki-legacy.apkg（schema 11、deflate、JSON 媒體清單）
  ./scripts/anki-package.py pack <collection.anki2> <collection.media 資料夾> <輸出.apkg> [--legacy]
      → 把現有的 collection（的副本）打包成 .apkg（真實資料的驗證；不修改來源）
"""
import hashlib, io, json, os, shutil, sqlite3, sys, tempfile, zipfile

import zstandard

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Packages/Flashcards/Tests/FlashcardsTests/Fixtures")

SCHEMA_18 = """
CREATE TABLE col (id integer PRIMARY KEY, crt integer NOT NULL, mod integer NOT NULL, scm integer NOT NULL,
  ver integer NOT NULL, dty integer NOT NULL, usn integer NOT NULL, ls integer NOT NULL, conf text NOT NULL,
  models text NOT NULL, decks text NOT NULL, dconf text NOT NULL, tags text NOT NULL);
CREATE TABLE notes (id integer PRIMARY KEY, guid text NOT NULL, mid integer NOT NULL, mod integer NOT NULL,
  usn integer NOT NULL, tags text NOT NULL, flds text NOT NULL, sfld integer NOT NULL, csum integer NOT NULL,
  flags integer NOT NULL, data text NOT NULL);
CREATE TABLE cards (id integer PRIMARY KEY, nid integer NOT NULL, did integer NOT NULL, ord integer NOT NULL,
  mod integer NOT NULL, usn integer NOT NULL, type integer NOT NULL, queue integer NOT NULL, due integer NOT NULL,
  ivl integer NOT NULL, factor integer NOT NULL, reps integer NOT NULL, lapses integer NOT NULL, left integer NOT NULL,
  odue integer NOT NULL, odid integer NOT NULL, flags integer NOT NULL, data text NOT NULL);
CREATE TABLE revlog (id integer PRIMARY KEY, cid integer NOT NULL, usn integer NOT NULL, ease integer NOT NULL,
  ivl integer NOT NULL, lastIvl integer NOT NULL, factor integer NOT NULL, time integer NOT NULL, type integer NOT NULL);
CREATE TABLE config (KEY text NOT NULL PRIMARY KEY, usn integer NOT NULL, mtime_secs integer NOT NULL,
  val blob NOT NULL) without rowid;
CREATE TABLE fields (ntid integer NOT NULL, ord integer NOT NULL, name text NOT NULL COLLATE unicase,
  config blob NOT NULL, PRIMARY KEY (ntid, ord)) without rowid;
CREATE TABLE templates (ntid integer NOT NULL, ord integer NOT NULL, name text NOT NULL COLLATE unicase,
  mtime_secs integer NOT NULL, usn integer NOT NULL, config blob NOT NULL, PRIMARY KEY (ntid, ord)) without rowid;
CREATE TABLE notetypes (id integer NOT NULL PRIMARY KEY, name text NOT NULL COLLATE unicase,
  mtime_secs integer NOT NULL, usn integer NOT NULL, config blob NOT NULL);
CREATE TABLE decks (id integer PRIMARY KEY NOT NULL, name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
  usn integer NOT NULL, common blob NOT NULL, kind blob NOT NULL);
CREATE UNIQUE INDEX idx_fields_name_ntid ON fields (name, ntid);
CREATE UNIQUE INDEX idx_notetypes_name ON notetypes (name);
CREATE UNIQUE INDEX idx_decks_name ON decks (name);
"""

SCHEMA_11 = """
CREATE TABLE col (id integer PRIMARY KEY, crt integer NOT NULL, mod integer NOT NULL, scm integer NOT NULL,
  ver integer NOT NULL, dty integer NOT NULL, usn integer NOT NULL, ls integer NOT NULL, conf text NOT NULL,
  models text NOT NULL, decks text NOT NULL, dconf text NOT NULL, tags text NOT NULL);
CREATE TABLE notes (id integer PRIMARY KEY, guid text NOT NULL, mid integer NOT NULL, mod integer NOT NULL,
  usn integer NOT NULL, tags text NOT NULL, flds text NOT NULL, sfld integer NOT NULL, csum integer NOT NULL,
  flags integer NOT NULL, data text NOT NULL);
CREATE TABLE cards (id integer PRIMARY KEY, nid integer NOT NULL, did integer NOT NULL, ord integer NOT NULL,
  mod integer NOT NULL, usn integer NOT NULL, type integer NOT NULL, queue integer NOT NULL, due integer NOT NULL,
  ivl integer NOT NULL, factor integer NOT NULL, reps integer NOT NULL, lapses integer NOT NULL, left integer NOT NULL,
  odue integer NOT NULL, odid integer NOT NULL, flags integer NOT NULL, data text NOT NULL);
CREATE TABLE revlog (id integer PRIMARY KEY, cid integer NOT NULL, usn integer NOT NULL, ease integer NOT NULL,
  ivl integer NOT NULL, lastIvl integer NOT NULL, factor integer NOT NULL, time integer NOT NULL, type integer NOT NULL);
"""

# ---------- 虛構的測試資料 ----------
# 牌組 id → 名稱的各層
DECKS = {10: ["Lang"], 11: ["Lang", "English"], 12: ["Math"]}
# 筆記類型 id → (名稱, 克漏字, 欄位, template 數)
TYPES = {
    1: ("Basic", False, ["Front", "Back"], 1),
    2: ("Basic (and reversed card)", False, ["Front", "Back"], 2),
    3: ("Cloze", True, ["Text", "Back Extra"], 1),
    4: ("Option", False, ["Question", "A", "Answer"], 1),
    5: ("Image Occlusion", True, ["Occlusion", "Image"], 1),
}
# note id → (類型, 牌組, 欄位, 標籤)
NOTES = {
    1001: (1, 11, ["English &gt; Vocab<br><br>apple", "蘋果"], ["vocab"]),
    1002: (2, 10, ["中文", "Chinese"], ["lang::zh"]),
    1003: (3, 12, ["Math &gt; Calculus<br><br>\\(\\frac{d}{dx}x^2\\) = {{c1::\\(2x\\)}} and {{c2::linear<br>}}",
                   "<ul><li>power rule</li></ul>"], ["math"]),
    1004: (1, 12, ["Math &gt; Calculus<br><br>List the <b>rules</b><br><img src=\"rule.png\">",
                   "<ul><li><b>Power</b><ul><li>costs $5</li></ul></li><li>Chain</li></ul>"], ["math"]),
    1005: (3, 12, ["Run <code>ps {{c1::aux}}</code> now", ""], []),
    1006: (3, 12, ["<pre><code>{{c1::kubectl get pods}}</code></pre>", ""], []),
    1007: (4, 12, ["Q?", "a", "b"], []),
    1008: (5, 12, ["{{c1::image-occlusion:rect:left=.1:top=.1:width=.2:height=.2}}", "<img src=\"rule.png\">"], []),
    1009: (3, 12, ["{{c1::first<br>second}}", ""], []),
    1010: (1, 11, ["Listen [sound:a.mp3]", "hello &amp; bye"], []),
}
# card id → (note, ord, type, queue)
CARDS = {
    2001: (1001, 0, 2, -1),  # 暫停
    2002: (1002, 0, 2, 2),
    2003: (1002, 1, 0, 0),  # Forget 過：新卡但有紀錄
    2004: (1003, 0, 2, 2),
    2005: (1003, 1, 2, 2),
    2006: (1004, 0, 2, 2),
    2007: (1005, 0, 0, 0),
    2008: (1006, 0, 0, 0),
    2009: (1007, 0, 0, 0),
    2010: (1008, 0, 0, 0),
    2011: (1009, 0, 0, 0),
    2012: (1010, 0, 2, 2),
}
DAY = 86_400_000
T0 = 1_788_300_000_000
# (id, cid, ease, ivl, lastIvl, time, type)
REVLOG = [
    (T0, 2001, 3, 3, -600, 5000, 0),
    (T0 + 3 * DAY, 2001, 3, 8, 3, 4000, 1),
    (T0 + 1, 2002, 4, 4, 0, 3000, 0),
    (T0 + 2, 2003, 3, 2, 0, 3000, 0),
    (T0 + 5 * DAY, 2003, 0, 0, 2, 0, 4),  # Forget（手動，略過；改由 reset 表示）
    (T0 + 3, 2004, 3, 5, 0, 6000, 0),
    (T0 + 4, 2005, 1, -600, 0, 6000, 0),
    (T0 + 5, 2005, 3, 1, -600, 6000, 0),
    (T0 + 6, 2006, 3, 2, 0, 9000, 0),
    (T0 + 2 * DAY, 2006, 0, 9, 2, 0, 4),  # 設定到期日（手動，略過）
    (T0 + 7, 2012, 3, 3, 0, 2000, 0),
]
MOD = 1_788_900_000  # 卡片修改時間（秒）
PNG = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                    "1f15c4890000000d49444154789c6360000002000100e221bc330000000049454e44ae426082")
MEDIA = {"rule.png": PNG, "a.mp3": b"ID3fake-audio"}


def build_18(path):
    db = sqlite3.connect(path)
    db.create_collation("unicase", lambda a, b: (a.lower() > b.lower()) - (a.lower() < b.lower()))
    db.executescript(SCHEMA_18)
    db.execute("INSERT INTO col VALUES (1, 1788292800, 0, 0, 18, 0, 0, 0, '', '', '', '', '')")
    db.execute("INSERT INTO config VALUES ('rollover', 0, 0, ?)", (b"6",))
    for tid, (name, cloze, fields, templates) in TYPES.items():
        # NotetypeConfig：kind（欄位 1）= 1 是克漏字；一般類型不寫這個欄位
        config = b"\x08\x01\x1a\x00" if cloze else b"\x1a\x00"
        db.execute("INSERT INTO notetypes VALUES (?, ?, 0, 0, ?)", (tid, name, config))
        for i, f in enumerate(fields):
            db.execute("INSERT INTO fields VALUES (?, ?, ?, x'')", (tid, i, f))
        for i in range(templates):
            db.execute("INSERT INTO templates VALUES (?, ?, ?, 0, 0, x'')", (tid, i, f"Card {i + 1}"))
    for did, parts in DECKS.items():
        db.execute("INSERT INTO decks VALUES (?, ?, 0, 0, x'', x'')", (did, "\x1f".join(parts)))
    fill_common(db)
    db.commit()
    db.close()


def build_11(path):
    db = sqlite3.connect(path)
    db.executescript(SCHEMA_11)
    models = {str(tid): {"name": name, "type": 1 if cloze else 0,
                         "flds": [{"name": f, "ord": i} for i, f in enumerate(fields)],
                         "tmpls": [{"name": f"Card {i + 1}", "ord": i} for i in range(templates)]}
              for tid, (name, cloze, fields, templates) in TYPES.items()}
    decks = {str(did): {"name": "::".join(parts)} for did, parts in DECKS.items()}
    db.execute("INSERT INTO col VALUES (1, 1788292800, 0, 0, 11, 0, 0, 0, ?, ?, ?, '{}', '{}')",
               (json.dumps({"rollover": 5}), json.dumps(models), json.dumps(decks)))
    fill_common(db)
    db.commit()
    db.close()


def fill_common(db):
    for nid, (tid, did, fields, tags) in NOTES.items():
        db.execute("INSERT INTO notes VALUES (?, ?, ?, 0, 0, ?, ?, '', 0, 0, '')",
                   (nid, f"g{nid}", tid, (" " + " ".join(tags) + " ") if tags else "", "\x1f".join(fields)))
    for cid, (nid, ord_, typ, queue) in CARDS.items():
        did = NOTES[nid][1]
        db.execute("INSERT INTO cards VALUES (?, ?, ?, ?, ?, 0, ?, ?, 0, 0, 0, 0, 0, 0, 0, 0, 0, '')",
                   (cid, nid, did, ord_, MOD, typ, queue))
    for row in REVLOG:
        rid, cid, ease, ivl, last, time, typ = row
        db.execute("INSERT INTO revlog VALUES (?, ?, 0, ?, ?, ?, 0, ?, ?)", (rid, cid, ease, ivl, last, time, typ))


# ---------- 打包 ----------
def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field(number, wire, payload):
    key = varint(number << 3 | wire)
    return key + (varint(len(payload)) + payload if wire == 2 else varint(payload))


def pack(collection_path, media, out, legacy):
    """media：檔名 → bytes"""
    z = zstandard.ZstdCompressor()
    names = sorted(media)
    with zipfile.ZipFile(out, "w") as zf:
        data = open(collection_path, "rb").read()
        if legacy:
            zf.writestr("collection.anki21", data, compress_type=zipfile.ZIP_DEFLATED)
            zf.writestr("media", json.dumps({str(i): n for i, n in enumerate(names)}), compress_type=zipfile.ZIP_DEFLATED)
            for i, n in enumerate(names):
                zf.writestr(str(i), media[n], compress_type=zipfile.ZIP_DEFLATED)
        else:
            zf.writestr("collection.anki2", b"dummy collection: please update Anki", compress_type=zipfile.ZIP_STORED)
            zf.writestr("collection.anki21b", z.compress(data), compress_type=zipfile.ZIP_STORED)
            zf.writestr("meta", field(1, 0, 3), compress_type=zipfile.ZIP_STORED)
            entries = b"".join(field(1, 2, field(1, 2, n.encode()) + field(2, 0, len(media[n]))
                                     + field(3, 2, hashlib.sha1(media[n]).digest())) for n in names)
            zf.writestr("media", z.compress(entries), compress_type=zipfile.ZIP_STORED)
            for i, n in enumerate(names):
                zf.writestr(str(i), z.compress(media[n]), compress_type=zipfile.ZIP_STORED)


def main():
    if sys.argv[1:2] == ["fixtures"]:
        with tempfile.TemporaryDirectory() as tmp:
            for legacy, name in ((False, "anki-modern.apkg"), (True, "anki-legacy.apkg")):
                db = os.path.join(tmp, name + ".db")
                (build_11 if legacy else build_18)(db)
                pack(db, MEDIA, os.path.join(FIXTURES, name), legacy)
                print("wrote", os.path.join(FIXTURES, name))
    elif sys.argv[1:2] == ["pack"] and len(sys.argv) >= 5:
        collection, media_dir, out = sys.argv[2:5]
        with tempfile.TemporaryDirectory() as tmp:
            copy = os.path.join(tmp, "collection.db")
            shutil.copyfile(collection, copy)
            media = {n: open(os.path.join(media_dir, n), "rb").read() for n in os.listdir(media_dir)
                     if os.path.isfile(os.path.join(media_dir, n)) and not n.startswith(".")}
            pack(copy, media, out, "--legacy" in sys.argv)
        print("wrote", out, f"({len(media)} media files)")
    else:
        print(__doc__)
        sys.exit(1)


main()
