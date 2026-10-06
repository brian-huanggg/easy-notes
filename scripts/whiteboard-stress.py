#!/usr/bin/env python3
"""Generates a whiteboard stress-test file (zooming and panning with 1,000 elements).

Usage:   ./scripts/whiteboard-stress.py <element count> <output.excalidraw>
Example: ./scripts/whiteboard-stress.py 1000 ~/Vault/stress-1000.excalidraw

Rectangles, ellipses, arrows and text are scattered over 8,000 × 8,000; the seed is fixed, so the output is identical
every time.
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
    print(f"{out}: {count} elements")


if __name__ == "__main__":
    main()
