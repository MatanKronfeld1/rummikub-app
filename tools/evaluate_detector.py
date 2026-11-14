#!/usr/bin/env python3
"""Recall and precision of a one-class tile detector on labeled photo sets.

A set is a folder with ``images/`` and ``labels/`` (YOLO txt, class ignored).
Matching is greedy by IoU, one prediction per label box. Photos are fed at their
own size, as the app sends them (only photos above 1920 px are shrunk, none here).

    python tools/evaluate_detector.py --weights detect/best.pt \
        --set datasets/new_photos/corrected_extracted/test --set datasets/tiles_det/val
"""

from __future__ import annotations

import argparse
from pathlib import Path

from ultralytics import YOLO

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}


def iou(a, b) -> float:
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def read_boxes(label: Path, width: int, height: int) -> list[tuple[float, float, float, float]]:
    boxes = []
    for line in label.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        xc, yc, w, h = (float(v) for v in parts[1:5])
        boxes.append(((xc - w / 2) * width, (yc - h / 2) * height,
                      (xc + w / 2) * width, (yc + h / 2) * height))
    return boxes


def evaluate(model: YOLO, folder: Path, conf: float, threshold: float, verbose: bool,
             imgsz: int = 1024, augment: bool = False) -> tuple[int, int, int]:
    tp = fn = fp = 0
    for image in sorted(p for p in (folder / "images").iterdir() if p.suffix.lower() in IMAGE_SUFFIXES):
        label = folder / "labels" / f"{image.stem}.txt"
        result = model.predict(str(image), imgsz=imgsz, conf=conf, augment=augment, verbose=False)[0]
        height, width = result.orig_shape
        truth = read_boxes(label, width, height) if label.exists() else []
        preds = [tuple(b) for b in result.boxes.xyxy.cpu().numpy().tolist()]
        pairs = sorted(((iou(t, p), ti, pi) for ti, t in enumerate(truth) for pi, p in enumerate(preds)),
                       reverse=True)
        used_t, used_p = set(), set()
        for score, ti, pi in pairs:
            if score < threshold:
                break
            if ti in used_t or pi in used_p:
                continue
            used_t.add(ti)
            used_p.add(pi)
        hit, miss, extra = len(used_t), len(truth) - len(used_t), len(preds) - len(used_p)
        tp, fn, fp = tp + hit, fn + miss, fp + extra
        if verbose:
            print(f"    {image.name[:34]:34s} tiles={len(truth):3d} found={hit:3d} missed={miss:3d} extra={extra:3d}")
    return tp, fn, fp


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", required=True)
    parser.add_argument("--set", dest="sets", action="append", type=Path, required=True)
    parser.add_argument("--conf", type=float, nargs="+", default=[0.25])
    parser.add_argument("--iou", type=float, default=0.5)
    parser.add_argument("--per-photo", action="store_true")
    parser.add_argument("--imgsz", type=int, default=1024)
    parser.add_argument("--augment", action="store_true", help="test-time augmentation")
    args = parser.parse_args()

    model = YOLO(args.weights)
    for folder in args.sets:
        for conf in args.conf:
            print(f"{args.weights} on {folder} (conf {conf}, IoU {args.iou}, imgsz {args.imgsz}, TTA {args.augment})")
            tp, fn, fp = evaluate(model, folder, conf, args.iou, args.per_photo, args.imgsz, args.augment)
            recall = tp / (tp + fn) if tp + fn else 0.0
            precision = tp / (tp + fp) if tp + fp else 0.0
            print(f"  tiles={tp + fn}  found={tp}  missed={fn}  extra={fp}  "
                  f"recall={recall:.3f}  precision={precision:.3f}")


if __name__ == "__main__":
    main()
