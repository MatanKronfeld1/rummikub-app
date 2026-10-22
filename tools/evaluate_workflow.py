#!/usr/bin/env python3
"""Evaluate the *deployed* Roboflow Workflow on held-out photos.

Unlike ``evaluate_pipeline.py`` (which runs the local weights), this calls the
live Workflow, so it measures what the app will really get: Detection Offset,
Dynamic Crop, the classifier's server-side resize, and class replacement.

The API key is read from the environment only:

    PowerShell:  $env:ROBOFLOW_API_KEY = "..."
    Colab:       %env ROBOFLOW_API_KEY=...   (or Colab Secrets)

Usage:
    python tools/evaluate_workflow.py --workspace <workspace-slug> \
        --workflow rummikub-v2-two-stage
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import requests
import yaml

from tile_crops import load_photo

API_URL = "https://serverless.roboflow.com/{workspace}/workflows/{workflow}"


def iou(a: np.ndarray, b: np.ndarray) -> float:
    x1, y1 = np.maximum(a[:2], b[:2])
    x2, y2 = np.minimum(a[2:], b[2:])
    inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def ground_truth(label_path: Path, width: int, height: int) -> list[tuple[int, np.ndarray]]:
    result = []
    for line in label_path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        cid = int(parts[0])
        xc, yc, bw, bh = (float(v) for v in parts[1:5])
        result.append((cid, np.array([
            (xc - bw / 2) * width, (yc - bh / 2) * height,
            (xc + bw / 2) * width, (yc + bh / 2) * height,
        ])))
    return result


def call_workflow(url: str, api_key: str, image) -> list[dict]:
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=95)
    payload = {
        "api_key": api_key,
        "inputs": {"image": {"type": "base64",
                             "value": base64.b64encode(buffer.getvalue()).decode()}},
    }
    response = requests.post(url, json=payload, timeout=120)
    response.raise_for_status()
    outputs = response.json()["outputs"][0]["detections"]
    return outputs["predictions"] if isinstance(outputs, dict) else outputs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--workflow", default="rummikub-v2-two-stage")
    parser.add_argument("--source", default="your_dataset/train")
    parser.add_argument("--split-file", default="datasets/tiles_det/split.txt")
    parser.add_argument("--classes", default="your_dataset/data.yaml")
    parser.add_argument("--iou", type=float, default=0.5)
    parser.add_argument("--suspect-csv", default="datasets/tiles_cls/suspect_labels.csv",
                        help="tiles listed here are skipped (known tagging mistakes)")
    args = parser.parse_args()

    api_key = os.environ.get("ROBOFLOW_API_KEY")
    if not api_key:
        sys.exit("Set ROBOFLOW_API_KEY in the environment first (never paste it into files).")

    names = yaml.safe_load(Path(args.classes).read_text(encoding="utf-8"))["names"]
    val_stems = {
        parts[2]
        for line in Path(args.split_file).read_text(encoding="utf-8").splitlines()
        if len(parts := line.split("\t")) == 3 and parts[0] == "val"
    }
    suspects: set[tuple[str, int]] = set()
    suspect_path = Path(args.suspect_csv)
    if suspect_path.exists():
        import csv
        with suspect_path.open(encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                suspects.add((row["image_stem"], int(row["box_index"])))

    url = API_URL.format(workspace=args.workspace, workflow=args.workflow)
    image_dir, label_dir = Path(args.source) / "images", Path(args.source) / "labels"
    total = matched = correct = unknown = exact = images = 0
    confusions: Counter[tuple[str, str]] = Counter()

    for label_path in sorted(label_dir.glob("*.txt")):
        if label_path.stem not in val_stems:
            continue
        image_path = next((p for s in (".jpg", ".jpeg", ".png")
                           if (p := image_dir / f"{label_path.stem}{s}").exists()), None)
        if image_path is None:
            continue
        image = load_photo(image_path)
        predictions = call_workflow(url, api_key, image)
        boxes = [np.array([p["x"] - p["width"] / 2, p["y"] - p["height"] / 2,
                           p["x"] + p["width"] / 2, p["y"] + p["height"] / 2])
                 for p in predictions]
        unused = set(range(len(boxes)))
        gt = ground_truth(label_path, *image.size)
        image_ok = len(boxes) == len(gt)
        for index, (class_id, gt_box) in enumerate(gt):
            total += 1
            best_iou, best = max(((iou(gt_box, boxes[i]), i) for i in unused),
                                 default=(0.0, -1))
            if best_iou < args.iou:
                image_ok = False
                continue
            unused.remove(best)
            matched += 1
            predicted = predictions[best]["class"]
            if (label_path.stem, index) in suspects:
                matched -= 1
                total -= 1
                continue
            if predicted == "Unknown":
                unknown += 1
            if predicted == names[class_id]:
                correct += 1
            else:
                image_ok = False
                confusions[(names[class_id], predicted)] += 1
        image_ok = image_ok and not unused
        exact += int(image_ok)
        images += 1
        print(f"{label_path.stem}: {'OK ' if image_ok else 'ERR'} "
              f"(gt={len(gt)}, predicted={len(boxes)})")

    print()
    print(f"Detector recall@IoU{args.iou:.2f}: {matched}/{total} = {matched / max(1, total):.3f}")
    print(f"Classifier top-1 on matched: {correct}/{matched} = {correct / max(1, matched):.3f}"
          f"  (Unknown: {unknown})")
    print(f"Exact images: {exact}/{images} = {exact / max(1, images):.3f}")
    if confusions:
        print("\nMost common confusions (truth -> predicted):")
        for (truth, predicted), count in confusions.most_common(15):
            print(f"  {truth} -> {predicted}: {count}")


if __name__ == "__main__":
    main()
