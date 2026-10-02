#!/usr/bin/env -S uv run --python 3.12 --with fsrs-rs-python==0.9.3 --with fsrs==6.3.2 python
"""產生 Flashcards 排程的參考向量（Phase 3b 驗收）。

- memory：fsrs-rs（Anki 使用的函式庫）由評分與間隔天數算出的記憶狀態
- next：fsrs-rs 由記憶狀態算出四個按鈕的下一個記憶狀態與間隔
- scheduler：py-fsrs 的完整排程（learning / relearning steps、到期時間），fuzz 關閉；
  複習卡另附套上 Anki 的 Hard ≤ Good < Easy 限制後的間隔（`ankiDays`，py-fsrs 沒有這個限制）

輸出 Packages/Flashcards/Tests/FlashcardsTests/Fixtures/fsrs-vectors.json。
執行：./scripts/fsrs-vectors.py
"""
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import fsrs
import fsrs_rs_python as rs

DEFAULT_W = [0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796,
             1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542]
# 一組像是優化過的參數（每個值都在合法範圍內）。初始 stability 避開剛好 .5：
# py-fsrs 用 Python 的 round（四捨六入五成雙），Anki（Rust）與 swift-fsrs 是四捨五入
CUSTOM_W = [0.4, 0.9, 3.1, 10.4, 6.8, 0.6, 2.5, 0.02, 1.6, 0.12, 1.0,
            1.7, 0.08, 0.3, 1.9, 0.45, 2.2, 0.6, 0.15, 0.1, 0.25]

# (評分, 距離上一次複習的天數)；第一筆的天數一律為 0
MEMORY_CASES = [
    [(3, 0)],
    [(1, 0)],
    [(4, 0)],
    [(3, 0), (3, 1), (3, 3), (3, 8), (3, 21)],
    [(3, 0), (3, 2), (1, 7), (3, 1), (3, 4)],
    [(2, 0), (2, 1), (2, 2), (4, 6), (1, 30), (3, 1)],
    # 同一天內多次複習（learning steps）
    [(1, 0), (3, 0), (3, 0), (3, 1), (1, 5), (3, 0), (3, 2)],
    [(4, 0), (4, 15), (4, 60), (2, 200), (3, 100)],
]

NEXT_CASES = [  # (memory case index, 這次複習距上次的天數, desired retention)
    (3, 30, 0.9), (4, 3, 0.9), (5, 10, 0.85), (6, 1, 0.95), (7, 365, 0.9), (0, 0, 0.9),
]

START = datetime(2026, 1, 5, 12, 0, tzinfo=timezone.utc)
# (評分, 從 START 起算的分鐘)。跨日的複習都排在一天中較晚的時間，
# 讓 py-fsrs 以 24 小時計的天數等於以日曆計的天數
SCHEDULER_CASES = [
    [(3, 0), (3, 1), (3, 11), (3, 1440 * 3 + 60)],
    [(1, 0), (1, 1), (2, 2), (2, 8), (3, 18), (3, 28), (3, 1440 + 120)],
    [(4, 0), (3, 1440 * 9 + 60), (1, 1440 * 40 + 120), (2, 1440 * 40 + 130), (3, 1440 * 40 + 145),
     (3, 1440 * 42 + 180)],
    [(3, 0), (3, 1), (3, 11), (2, 1440 * 3 + 60), (4, 1440 * 8 + 120), (1, 1440 * 30 + 180),
     (1, 1440 * 30 + 190), (4, 1440 * 30 + 200)],
]


def memory_state(fsrs_model, reviews):
    item = rs.FSRSItem([rs.FSRSReview(r, d) for r, d in reviews])
    m = fsrs_model.memory_state(item, None)
    return {"stability": m.stability, "difficulty": m.difficulty}


def memory_vectors(w):
    model = rs.FSRS(w)
    return [{"reviews": [{"rating": r, "days": d} for r, d in case],
             # 每一筆之後的記憶狀態
             "states": [memory_state(model, case[:i + 1]) for i in range(len(case))]}
            for case in MEMORY_CASES]


def next_vectors(w):
    model = rs.FSRS(w)
    out = []
    for index, days, retention in NEXT_CASES:
        case = MEMORY_CASES[index]
        item = rs.FSRSItem([rs.FSRSReview(r, d) for r, d in case])
        m = model.memory_state(item, None)
        ns = model.next_states(m, retention, days)
        out.append({
            "memory": {"stability": m.stability, "difficulty": m.difficulty},
            "days": days, "retention": retention,
            "next": [{"stability": s.memory.stability, "difficulty": s.memory.difficulty, "interval": s.interval}
                     for s in (ns.again, ns.hard, ns.good, ns.easy)],
        })
    return out


def anki_review_days(scheduler, card, at):
    """複習卡四個按鈕的間隔（天）。py-fsrs 各自計算；Anki（與 ts-fsrs、swift-fsrs）再限制 Hard ≤ Good < Easy。
    Again 有 relearning steps 時不是以天計，回傳 None"""
    days = []
    for rating in (fsrs.Rating.Hard, fsrs.Rating.Good, fsrs.Rating.Easy):
        nxt, _ = scheduler.review_card(card, rating, review_datetime=at)
        days.append(round((nxt.due - at).total_seconds() / 86400))
    hard, good, easy = days
    hard = min(hard, good)
    good = max(good, hard + 1)
    easy = max(easy, good + 1)
    return [None, hard, good, easy]


def scheduler_vectors(w):
    scheduler = fsrs.Scheduler(parameters=w, enable_fuzzing=False)
    out = []
    for case in SCHEDULER_CASES:
        card = fsrs.Card()
        steps = []
        for rating, minutes in case:
            at = START + timedelta(minutes=minutes)
            anki_days = None
            if card.state == fsrs.State.Review:
                anki_days = anki_review_days(scheduler, card, at)[rating - 1]
            card, _ = scheduler.review_card(card, fsrs.Rating(rating), review_datetime=at)
            steps.append({
                "rating": rating, "minutes": minutes,
                "state": card.state.name.lower(), "step": card.step,
                "dueSeconds": int((card.due - at).total_seconds()),
                "ankiDays": anki_days,
                "stability": card.stability, "difficulty": card.difficulty,
            })
        out.append(steps)
    return out


def main():
    data = {
        "generator": "scripts/fsrs-vectors.py（fsrs-rs-python 0.9.3、py-fsrs 6.3.2）",
        "start": START.isoformat(),
        "params": [
            {"name": name, "w": w, "memory": memory_vectors(w), "next": next_vectors(w),
             "scheduler": scheduler_vectors(w)}
            for name, w in (("default", DEFAULT_W), ("custom", CUSTOM_W))
        ],
    }
    out = Path(__file__).resolve().parent.parent / "Packages/Flashcards/Tests/FlashcardsTests/Fixtures/fsrs-vectors.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
