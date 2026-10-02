#!/usr/bin/env python3
"""產生白板壓力測試檔（Phase 4c 驗收：1,000 個元素的縮放與平移）。

用法：./scripts/whiteboard-stress.py <元素數> <輸出.excalidraw>
例如：./scripts/whiteboard-stress.py 1000 ~/Vault/stress-1000.excalidraw

矩形、橢圓、箭頭、文字隨機分布在 8,000 × 8,000 的範圍；固定種子，每次產生的檔案相同。
"""
import json
import random
import sys

WORDS = ["光合作用", "粒線體", "Excalidraw", "注音輸入", "白板", "箭頭綁定", "frame", "細胞"]
COLORS = ["#1971c2", "#e03131", "#2f9e44", "#f08c00", "#9c36b5", "#1e1e1e"]


def base(rng, kind, i, x, y, w, h):
    return {
        "id": f"stress-{i}", "type": kind, "x": x, "y": y, "width": w, "height": h, "angle": 0,
        "strokeColor": rng.choice(COLORS), "backgroundColor": "transparent", "fillStyle": "solid",
        "strokeWidth": 2, "strokeStyle": "solid", "roughness": 0, "opacity": 100, "groupIds": [],
        "frameId": None, "roundness": None, "seed": i + 1, "version": 1, "versionNonce": i + 1,
        "isDeleted": False, "boundElements": None, "updated": 0, "link": None, "locked": False,
    }


def element(rng, i):
    kind = rng.choice(["rectangle", "ellipse", "arrow", "text"])
    x, y = rng.uniform(0, 7_700), rng.uniform(0, 7_700)
    w, h = rng.uniform(40, 200), rng.uniform(30, 150)
    if kind == "arrow":
        dx, dy = w * rng.choice([1, -1]), h * rng.choice([1, -1])
        el = base(rng, kind, i, x, y, w, h)
        el.update(points=[[0, 0], [dx, dy]], startBinding=None, endBinding=None, startArrowhead=None,
                  endArrowhead="arrow", elbowed=False, lastCommittedPoint=None, roundness={"type": 2})
        return el
    if kind == "text":
        text = rng.choice(WORDS)
        el = base(rng, kind, i, x, y, len(text) * 20, 25)
        el.update(text=text, originalText=text, fontSize=20, fontFamily=2, textAlign="left",
                  verticalAlign="top", containerId=None, autoResize=True, lineHeight=1.25)
        return el
    el = base(rng, kind, i, x, y, w, h)
    if kind == "rectangle":
        el["roundness"] = {"type": 3}
    return el


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    count, out = int(sys.argv[1]), sys.argv[2]
    rng = random.Random(42)
    scene = {
        "type": "excalidraw", "version": 2, "source": "easynotes-stress",
        "elements": [element(rng, i) for i in range(count)],
        "appState": {"viewBackgroundColor": "#ffffff", "gridSize": None}, "files": {},
    }
    with open(out, "w") as f:
        json.dump(scene, f, ensure_ascii=False)
    print(f"{out}：{count} 個元素")


if __name__ == "__main__":
    main()
